import Foundation
import ShapeKit

/// Runs Stage 2 on the device instead of a server.
///
/// `DESIGN.md` §7.5 wrote off Apple's *Image Playground* — correctly, since
/// `ImageCreator` stops compiling in iOS 27. It did not consider the other
/// Apple path: Core ML. Apple ships `ml-stable-diffusion`, a Swift package that
/// runs Stable Diffusion **with ControlNet** on device, which is exactly the
/// conditioning §7.1 asks for.
///
/// What that changes:
///
/// - **Cost.** Nothing per generation, so the free tier stops scaling with users.
/// - **Privacy.** The control image never leaves the device, which makes §11's
///   provider retention question moot on this path — and that question is a
///   stated blocker on starting M6.
/// - **Availability.** Works offline, and needs neither Apple Intelligence nor
///   iOS 26/27 — the package targets iOS 16.2, below this app's own floor.
///
/// What it costs: ControlNet is not supported for SDXL, so this path tops out
/// at SD 1.5-class quality. That is the wrong direction for §4's open question
/// about whether the output reads as a recognisable animal, which is why SP-1
/// has to compare it against the server path rather than assume either wins.
public protocol OnDeviceImageGenerator: Sendable {
    /// Why a picture cannot be made right now, or `nil` when one can. A reason
    /// rather than a flag: "no model pack yet" and "this device cannot run one"
    /// lead to different actions, and a bool collapses them into a dead end.
    func unavailability() async -> OnDeviceUnavailability?

    /// The strength this generator actually applies, when it cannot be varied.
    ///
    /// Apple's pipeline adds the ControlNet residuals unscaled and exposes no
    /// conditioning scale, so the Core ML path always runs at the equivalent of
    /// 1.0 whatever it is asked for. Recording the requested value would put a
    /// number in `Artwork.controlStrength` that no image was made at.
    /// `nil` means the requested strength is honoured.
    var fixedControlStrength: Double? { get }

    func generate(
        controlImage: Data,
        prompt: String,
        negativePrompt: String,
        controlStrength: Double,
        seed: UInt32,
        stepCount: Int
    ) async throws -> Data
}

extension OnDeviceImageGenerator {
    public var fixedControlStrength: Double? { nil }

    public var isAvailable: Bool {
        get async { await unavailability() == nil }
    }
}

/// Why on-device generation is not usable right now.
///
/// Nothing here is a download: there is no server to download from, which is
/// the same choice that keeps routes on the phone. The copy names the only
/// recovery that exists rather than an action the app cannot offer.
public enum OnDeviceUnavailability: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case modelNotInstalled(bytesRequired: Int)
    case deviceUnsupported(reason: String)
    case installInProgress(fractionComplete: Double)

    public var description: String {
        switch self {
        case .modelNotInstalled(let bytes):
            let gigabytes = Double(bytes) / 1_000_000_000
            return String(
                format: "Drawing needs a %.1f GB model. Add it in Settings under Picture model.",
                gigabytes
            )
        case .deviceUnsupported(let reason):
            return "This device cannot generate pictures on its own. \(reason)"
        case .installInProgress(let fraction):
            return "Adding the picture model — \(Int(fraction * 100))%."
        }
    }

    public var errorDescription: String? { description }
}

/// Adapts an on-device generator to the same transport the server path uses.
///
/// The seam already existed: `GenerationClient` talks to `GenerationTransport`,
/// so the on-device path drops in without the client, the polling policy, or
/// the UI knowing which one ran.
///
/// The one difference that must **not** be papered over is the quota. Reserving,
/// committing, and refunding are all about money that leaves an account, and
/// nothing leaves an account here — so this transport reports zero cost and the
/// client is expected to skip the ledger entirely (see `isMetered`).
public actor OnDeviceTransport: GenerationTransport {

    public struct Configuration: Sendable {
        public var stylePreset: String
        public var stepCount: Int
        public var candidateCount: Int
        /// Where finished images are written. They are handed back as `file:`
        /// URLs so `GeneratedCandidate` needs no separate on-device shape.
        public var outputDirectory: URL

        public init(
            stylePreset: String = "flat-vector",
            stepCount: Int = 20,
            candidateCount: Int = 2,
            outputDirectory: URL = FileManager.default.temporaryDirectory
        ) {
            self.stylePreset = stylePreset
            self.stepCount = stepCount
            self.candidateCount = candidateCount
            self.outputDirectory = outputDirectory
        }
    }

    /// Always false: this transport spends no money, so quota must not be
    /// reserved, committed, or refunded against it.
    public nonisolated var isMetered: Bool { false }

    private let generator: any OnDeviceImageGenerator
    private let interpreter: any ShapeInterpreter
    private let configuration: Configuration
    private var jobs: [String: GenerationJob] = [:]

    public init(
        generator: any OnDeviceImageGenerator,
        interpreter: any ShapeInterpreter,
        configuration: Configuration = Configuration()
    ) {
        self.generator = generator
        self.interpreter = interpreter
        self.configuration = configuration
    }

    public func readiness() async -> String? {
        await generator.unavailability()?.description
    }

    public func submit(_ request: GenerationRequest) async throws -> GenerationJob {
        // Idempotency still matters, but for a different reason than on the
        // server: a duplicate submit here wastes battery and heat rather than
        // money, and would hand back a second job the caller then polls forever.
        if let existing = jobs.values.first(where: { $0.idempotencyKey == request.idempotencyKey }) {
            return existing
        }

        let now = Date()
        let job = GenerationJob(
            id: UUID().uuidString,
            idempotencyKey: request.idempotencyKey,
            status: .running,
            createdAt: now,
            updatedAt: now
        )
        jobs[job.id] = job

        Task { await run(job.id, request: request) }
        return job
    }

    public func poll(jobID: String) async throws -> GenerationJob {
        guard let job = jobs[jobID] else {
            throw OnDeviceError.unknownJob(jobID)
        }
        return job
    }

    public func cancel(jobID: String) async throws {
        guard var job = jobs[jobID], !job.status.isTerminal else { return }
        job.status = .cancelled
        job.updatedAt = Date()
        jobs[jobID] = job
    }

    public func download(_ url: URL) async throws -> Data {
        guard url.isFileURL else { throw OnDeviceError.notALocalFile(url) }
        return try Data(contentsOf: url)
    }

    // MARK: - Pipeline

    private func run(_ jobID: String, request: GenerationRequest) async {
        do {
            let interpretation = try await interpreter.interpret(
                sheet: request.contactSheet,
                layout: request.sheetLayout,
                fingerprint: request.fingerprint
            )
            let subject = interpretation.candidates.first.map {
                ($0.subject, $0.why, $0.prompt, $0.renderIndex)
            } ?? (
                interpretation.fallbackAbstract,
                "Nothing recognisable, so the shape is drawn as an object instead.",
                interpretation.fallbackAbstract,
                0
            )

            var candidates: [GeneratedCandidate] = []
            for index in 0..<configuration.candidateCount {
                try Task.checkCancellation()
                // Seeds are derived from the idempotency key so a retried job
                // reproduces its images rather than charging the user's battery
                // for a different result.
                let seed = UInt32(truncatingIfNeeded: request.idempotencyKey.hashValue &+ index)

                let strength = generator.fixedControlStrength ?? request.controlStrength
                let png = try await generator.generate(
                    controlImage: request.orientationImages[
                        min(subject.3, request.orientationImages.count - 1)
                    ],
                    prompt: "\(subject.2), \(configuration.stylePreset)",
                    negativePrompt: "text, watermark, blurry, low quality",
                    controlStrength: strength,
                    seed: seed,
                    stepCount: configuration.stepCount
                )

                let url = configuration.outputDirectory
                    .appendingPathComponent("\(jobID)-\(index).png")
                try png.write(to: url, options: [.atomic])

                candidates.append(
                    GeneratedCandidate(
                        imageURL: url,
                        subject: subject.0,
                        why: subject.1,
                        seed: Int64(seed),
                        controlStrength: strength,
                        renderIndex: subject.3,
                        costCents: 0
                    )
                )
            }

            finish(jobID, status: .succeeded, candidates: candidates)
        } catch is CancellationError {
            finish(jobID, status: .cancelled, candidates: [])
        } catch {
            finish(jobID, status: .failed, candidates: [], reason: describe(error))
        }
    }

    private func finish(
        _ jobID: String,
        status: GenerationJob.Status,
        candidates: [GeneratedCandidate],
        reason: String? = nil
    ) {
        guard var job = jobs[jobID], !job.status.isTerminal else { return }
        job.status = status
        job.candidates = candidates
        job.failureReason = reason
        job.updatedAt = Date()
        jobs[jobID] = job
    }

    private func describe(_ error: any Error) -> String {
        (error as? OnDeviceUnavailability)?.description
            ?? (error as? OnDeviceError)?.description
            ?? error.localizedDescription
    }
}

/// Stage 1, abstracted so the same pipeline runs against a server VLM or
/// Apple's on-device model.
///
/// Apple's `FoundationModels` gains image input in iOS 27; its `@Generable`
/// macro produces exactly this shape without any JSON parsing. Until that SDK
/// exists locally, the server implementation is the only one that can be built
/// — but the seam belongs here now, not later.
public protocol ShapeInterpreter: Sendable {
    func interpret(
        sheet: Data,
        layout: String,
        fingerprint: ShapeFingerprint
    ) async throws -> ShapeInterpretation
}

public enum OnDeviceError: Error, Equatable, CustomStringConvertible {
    case unknownJob(String)
    case notALocalFile(URL)
    case generationFailed(String)

    public var description: String {
        switch self {
        case .unknownJob(let id): "No on-device job with id \(id)."
        case .notALocalFile(let url): "\(url) is not a local file."
        case .generationFailed(let detail): "On-device generation failed: \(detail)."
        }
    }
}
