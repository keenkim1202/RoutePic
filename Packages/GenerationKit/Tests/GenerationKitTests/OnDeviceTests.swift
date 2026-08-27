import Foundation
import ShapeKit
import Testing
@testable import GenerationKit

private let epoch = Date(timeIntervalSince1970: 1_780_000_000)

private func fingerprint() -> ShapeFingerprint {
    ShapeFingerprint(
        closureRatio: 0.4, aspectRatio: 1.2, tortuosity: 3.5,
        meanAbsoluteTurn: 0.3, turnVariance: 0.1, turnSkewness: 0,
        occupancyFillRatio: 0.1, protrusionCount: 3,
        selfIntersectionCount: 1, convexRatio: nil
    )
}

private func request(key: String = "device-1") -> GenerationRequest {
    GenerationRequest(
        contactSheet: Data([0x89, 0x50, 0x4E, 0x47]),
        sheetLayout: "A 3×3 grid…",
        orientationImages: Array(repeating: Data([0x89, 0x50]), count: 8),
        fingerprint: fingerprint(),
        stylePreset: "flat-vector",
        conditionMode: "centreline",
        controlStrength: 0.65,
        idempotencyKey: key
    )
}

/// Returns a fixed PNG-ish blob, or throws.
private actor StubGenerator: OnDeviceImageGenerator {
    var unavailable: OnDeviceUnavailability?
    var failure: (any Error)?
    private(set) var callCount = 0
    private(set) var lastPrompt = ""
    private(set) var seeds: [UInt32] = []

    init(unavailable: OnDeviceUnavailability? = nil, failure: (any Error)? = nil) {
        self.unavailable = unavailable
        self.failure = failure
    }

    func unavailability() async -> OnDeviceUnavailability? { unavailable }

    func generate(
        controlImage: Data, prompt: String, negativePrompt: String,
        controlStrength: Double, seed: UInt32, stepCount: Int
    ) async throws -> Data {
        callCount += 1
        lastPrompt = prompt
        seeds.append(seed)
        if let failure { throw failure }
        return Data([0x89, 0x50, 0x4E, 0x47, UInt8(truncatingIfNeeded: seed)])
    }
}

private struct StubInterpreter: ShapeInterpreter {
    var recognizable = true

    func interpret(
        sheet: Data, layout: String, fingerprint: ShapeFingerprint
    ) async throws -> ShapeInterpretation {
        ShapeInterpretation(
            recognizable: recognizable,
            bestRenderIndex: 3,
            candidates: recognizable
                ? [SubjectCandidate(
                    subject: "웅크린 여우", confidence: 0.7, renderIndex: 3,
                    prompt: "a curled sleeping fox", why: "닫힌 곡선"
                )]
                : [],
            fallbackAbstract: "바람에 휜 나뭇가지"
        )
    }
}

private func makeTransport(
    generator: StubGenerator = StubGenerator(),
    interpreter: StubInterpreter = StubInterpreter(),
    candidates: Int = 2
) -> OnDeviceTransport {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("routepic-ondevice-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return OnDeviceTransport(
        generator: generator,
        interpreter: interpreter,
        configuration: .init(candidateCount: candidates, outputDirectory: directory)
    )
}

/// Waits for a job to reach a terminal state without sleeping on wall-clock.
private func settle(_ transport: OnDeviceTransport, _ id: String) async throws -> GenerationJob {
    for _ in 0..<2_000 {
        let job = try await transport.poll(jobID: id)
        if job.status.isTerminal { return job }
        await Task.yield()
    }
    Issue.record("job \(id) never reached a terminal state")
    return try await transport.poll(jobID: id)
}

@Suite("OnDeviceTransport")
struct OnDeviceTransportTests {

    @Test("A successful run produces candidates that cost nothing")
    func success() async throws {
        let transport = makeTransport()
        let job = try await transport.submit(request())
        let settled = try await settle(transport, job.id)

        #expect(settled.status == .succeeded)
        #expect(settled.candidates.count == 2)
        #expect(settled.candidates.allSatisfy { $0.costCents == 0 })
        #expect(settled.candidates.allSatisfy { $0.imageURL.isFileURL })
    }

    @Test("The transport declares itself unmetered")
    func unmetered() {
        // DESIGN.md §8.3's ledger is about money leaving an account. Nothing
        // leaves one here, so reserving against it would refuse generations for
        // no reason.
        #expect(!makeTransport().isMetered)
    }

    @Test("Images are written where the caller asked")
    func writesFiles() async throws {
        let transport = makeTransport()
        let job = try await settle(transport, try await transport.submit(request()).id)

        for candidate in job.candidates {
            #expect(FileManager.default.fileExists(atPath: candidate.imageURL.path))
        }
    }

    @Test("Resubmitting the same key reuses the job instead of regenerating")
    func idempotentSubmit() async throws {
        // On the server this prevents double billing; here it prevents burning
        // battery twice and handing back a second job to poll forever.
        let generator = StubGenerator()
        let transport = makeTransport(generator: generator)

        let first = try await transport.submit(request(key: "same"))
        _ = try await settle(transport, first.id)
        let second = try await transport.submit(request(key: "same"))

        #expect(first.id == second.id)
        #expect(await generator.callCount == 2)   // two candidates, one run
    }

    @Test("Seeds are derived from the idempotency key, so a retry reproduces")
    func deterministicSeeds() async throws {
        let generator = StubGenerator()
        let transport = makeTransport(generator: generator)
        _ = try await settle(transport, try await transport.submit(request(key: "abc")).id)

        let other = StubGenerator()
        let second = makeTransport(generator: other)
        _ = try await settle(second, try await second.submit(request(key: "abc")).id)

        #expect(await generator.seeds == (await other.seeds))
    }

    @Test("A generator failure lands as a failed job, not a crash")
    func generatorFailure() async throws {
        let transport = makeTransport(
            generator: StubGenerator(failure: OnDeviceError.generationFailed("out of memory"))
        )
        let job = try await settle(transport, try await transport.submit(request()).id)

        #expect(job.status == .failed)
        #expect(job.candidates.isEmpty)
        #expect(job.failureReason?.contains("out of memory") == true)
    }

    @Test("An unrecognisable shape falls back to the abstract subject")
    func abstractFallback() async throws {
        // DESIGN.md §4.4 — the pipeline must not stall when the model says
        // "this looks like nothing".
        let transport = makeTransport(interpreter: StubInterpreter(recognizable: false))
        let job = try await settle(transport, try await transport.submit(request()).id)

        #expect(job.status == .succeeded)
        #expect(job.candidates.first?.subject == "바람에 휜 나뭇가지")
    }

    @Test("The chosen orientation reaches the generator's prompt")
    func usesChosenSubject() async throws {
        let generator = StubGenerator()
        let transport = makeTransport(generator: generator)
        let job = try await settle(transport, try await transport.submit(request()).id)

        #expect(job.candidates.first?.renderIndex == 3)
        #expect(await generator.lastPrompt.contains("curled sleeping fox"))
        #expect(await generator.lastPrompt.contains("flat-vector"))
    }

    @Test("Cancelling stops a job reaching success")
    func cancel() async throws {
        let transport = makeTransport()
        let job = try await transport.submit(request())
        try await transport.cancel(jobID: job.id)
        #expect(try await transport.poll(jobID: job.id).status == .cancelled)
    }

    @Test("Polling an unknown job throws rather than inventing one")
    func unknownJob() async {
        let transport = makeTransport()
        await #expect(throws: OnDeviceError.self) {
            try await transport.poll(jobID: "nope")
        }
    }

    @Test("Download only reads local files")
    func downloadRejectsRemote() async {
        let transport = makeTransport()
        await #expect(throws: OnDeviceError.self) {
            try await transport.download(URL(string: "https://example.invalid/a.png")!)
        }
    }

    @Test("Unavailability messages are written for a person, not a log")
    func unavailabilityCopy() {
        #expect(
            OnDeviceUnavailability.modelNotInstalled(bytesRequired: 1_800_000_000)
                .description.contains("1.8 GB")
        )
        #expect(
            OnDeviceUnavailability.installInProgress(fractionComplete: 0.42)
                .description.contains("42%")
        )
    }
}

@Suite("GenerationClient with an unmetered transport")
struct UnmeteredClientTests {

    private func client(_ transport: OnDeviceTransport, allowance: Int) -> (GenerationClient, QuotaLedger) {
        let quota = QuotaLedger(allowance: allowance, periodStart: epoch)
        return (
            GenerationClient(
                transport: transport, quota: quota,
                policy: .init(intervals: [0], timeout: 600), sleep: { _ in }
            ),
            quota
        )
    }

    @Test("An exhausted quota does not block on-device generation")
    func exhaustedQuotaIsIrrelevant() async throws {
        // The whole point of the on-device path is that the free tier stops
        // scaling with users. A ledger check here would undo that.
        let transport = makeTransport()
        let (generation, quota) = client(transport, allowance: 0)

        let candidates = try await generation.generate(request())
        #expect(candidates.count == 2)
        #expect(await quota.snapshot().used == 0)
    }

    @Test("A successful on-device run spends no allowance")
    func spendsNothing() async throws {
        let transport = makeTransport()
        let (generation, quota) = client(transport, allowance: 5)
        _ = try await generation.generate(request())

        let state = await quota.snapshot()
        #expect(state.used == 0)
        #expect(state.reserved == 0)
        #expect(state.remaining == 5)
    }

    @Test("A failed on-device run leaves the ledger untouched")
    func failureLeavesLedgerAlone() async throws {
        let transport = makeTransport(
            generator: StubGenerator(failure: OnDeviceError.generationFailed("thermal"))
        )
        let (generation, quota) = client(transport, allowance: 5)

        await #expect(throws: GenerationClient.Failure.self) {
            try await generation.generate(request())
        }
        #expect(await quota.snapshot().remaining == 5)
    }

    @Test("Availability ignores quota and connectivity on the on-device path")
    func availabilityIgnoresQuotaAndNetwork() async {
        let (generation, _) = client(makeTransport(), allowance: 0)
        let availability = await generation.availability(
            for: fingerprint(), lengthMeters: 5_000, isOnline: false
        )
        #expect(availability.canGenerate)
    }

    /// Without this the first anyone hears of a missing model pack is a
    /// generation they waited on and watched fail.
    @Test("A missing model pack is reported before a generation is started")
    func availabilityReportsAMissingPack() async {
        let (generation, _) = client(
            makeTransport(generator: StubGenerator(
                unavailable: .modelNotInstalled(bytesRequired: 1_800_000_000)
            )),
            allowance: 0
        )
        let availability = await generation.availability(for: fingerprint(), lengthMeters: 5_000)

        #expect(!availability.canGenerate)
        guard case .notReady(let reason) = availability else {
            Issue.record("expected .notReady, got \(availability)")
            return
        }
        #expect(reason.contains("1.8 GB"))
    }

    /// A download does not fix a straight line, so the route check has to run
    /// first or someone installs two gigabytes for nothing.
    @Test("An unsuitable route is refused before a missing pack is mentioned")
    func routeChecksComeFirst() async {
        let (generation, _) = client(
            makeTransport(generator: StubGenerator(
                unavailable: .modelNotInstalled(bytesRequired: 1_800_000_000)
            )),
            allowance: 0
        )
        let straight = ShapeFingerprint(
            closureRatio: 0.9, aspectRatio: 900, tortuosity: 1.02,
            meanAbsoluteTurn: 0.001, turnVariance: 0, turnSkewness: 0,
            occupancyFillRatio: 0.01, protrusionCount: 0,
            selfIntersectionCount: 0, convexRatio: nil
        )
        guard case .routeUnsuitable = await generation.availability(
            for: straight, lengthMeters: 5_000
        ) else {
            Issue.record("a straight line should be refused for its shape, not for the pack")
            return
        }
    }

    @Test("An unsuitable route is still refused on-device")
    func routeChecksStillApply() async {
        // Free generation is not a reason to make a picture of a straight line.
        let (generation, _) = client(makeTransport(), allowance: 0)
        let straight = ShapeFingerprint(
            closureRatio: 0.9, aspectRatio: 900, tortuosity: 1.02,
            meanAbsoluteTurn: 0.001, turnVariance: 0, turnSkewness: 0,
            occupancyFillRatio: 0.01, protrusionCount: 0,
            selfIntersectionCount: 0, convexRatio: nil
        )
        #expect(!(await generation.availability(for: straight, lengthMeters: 5_000).canGenerate))
    }
}
