import CoreGraphics
import CoreML
import Foundation
import GenerationKit
import ImageIO
import StableDiffusion
import UniformTypeIdentifiers

/// Runs Stage 2 through Apple's Core ML Stable Diffusion pipeline.
///
/// The pack is gigabytes and stays out of the app bundle, so everything here
/// reports unavailability rather than failing and the caller falls back to the
/// local card (`DESIGN.md` §4.4).
public actor CoreMLImageGenerator: OnDeviceImageGenerator {

    public struct Configuration: Sendable {
        /// Directory holding the converted `.mlmodelc` resources.
        public var resourcesURL: URL
        /// What the download costs, for the message shown before it starts.
        public var packBytes: Int
        public var computeUnits: MLComputeUnits
        /// Keeps one model in memory at a time. Required on a phone; wasteful
        /// on a Mac with room to spare.
        public var reduceMemory: Bool

        public init(
            resourcesURL: URL,
            packBytes: Int = 1_800_000_000,
            computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
            reduceMemory: Bool = true
        ) {
            self.resourcesURL = resourcesURL
            self.packBytes = packBytes
            self.computeUnits = computeUnits
            self.reduceMemory = reduceMemory
        }

        /// Where a downloaded pack lives. Application Support rather than
        /// Caches: the system may evict Caches, and re-downloading two gigabytes
        /// because the disk got tight is not a recovery anyone wants.
        public static func defaultResourcesURL() throws -> URL {
            try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("StableDiffusionPack", isDirectory: true)
        }
    }

    private let configuration: Configuration
    private let installer: ModelPackInstaller
    private var pipeline: StableDiffusionPipeline?

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.installer = ModelPackInstaller(destination: configuration.resourcesURL)
    }

    /// Apple's pipeline adds the residuals unscaled and offers no conditioning
    /// scale, so this runs at the equivalent of 1.0 — the bottom of the window
    /// the strength grid left standing. Varying it needs a patched pipeline,
    /// which is why `SPIKE-RESULTS.md` ran its grid outside this package.
    public nonisolated var fixedControlStrength: Double? { 1.0 }

    /// Why generation cannot run, or `nil` when it can.
    public func unavailability() async -> OnDeviceUnavailability? {
        if case .failure(let reason) = await resolvedPack() { return reason }
        return nil
    }

    /// The pack on disk, or the reason there is none to use.
    func resolvedPack() async -> Result<ModelPack, OnDeviceUnavailability> {
        // An interrupted install answers first: the destination is still empty
        // at that point, and "not downloaded" over a folder already holding a
        // gigabyte points at the wrong action.
        if let fraction = await installer.stagedFraction() {
            return .failure(.installInProgress(fractionComplete: fraction))
        }
        do {
            return .success(try ModelPack.inspect(at: configuration.resourcesURL))
        } catch ModelPackProblem.notADirectory, ModelPackProblem.empty {
            return .failure(.modelNotInstalled(bytesRequired: configuration.packBytes))
        } catch let problem as ModelPackProblem {
            return .failure(.deviceUnsupported(reason: problem.description))
        } catch {
            return .failure(.deviceUnsupported(reason: error.localizedDescription))
        }
    }

    public func generate(
        controlImage: Data,
        prompt: String,
        negativePrompt: String,
        controlStrength: Double,
        seed: UInt32,
        stepCount: Int
    ) async throws -> Data {
        let pack = try await resolvedPack().get()
        guard let control = Self.decode(controlImage) else {
            throw OnDeviceError.generationFailed("the control image could not be read")
        }

        let pipeline = try loadPipeline(pack)
        var request = StableDiffusionPipeline.Configuration(prompt: prompt)
        request.negativePrompt = negativePrompt
        request.stepCount = stepCount
        request.seed = seed
        request.controlNetInputs = [control]
        request.disableSafety = false

        let images = try pipeline.generateImages(configuration: request) { _ in
            // The handler runs between steps and is the only place a run can be
            // stopped; returning false unwinds the pipeline cleanly instead of
            // leaving a loaded model behind.
            !Task.isCancelled
        }
        try Task.checkCancellation()

        guard let image = images.compactMap({ $0 }).first else {
            throw OnDeviceError.generationFailed("the pipeline returned no image")
        }
        guard let png = Self.encode(image) else {
            throw OnDeviceError.generationFailed("the image could not be encoded")
        }
        return png
    }

    /// Frees the models. Worth calling when generation is done: the pack is the
    /// largest thing this app ever holds, and on a phone it is what gets the
    /// process killed while a recording is still running.
    public func unload() {
        pipeline?.unloadResources()
        pipeline = nil
    }

    private func loadPipeline(_ pack: ModelPack) throws -> StableDiffusionPipeline {
        if let pipeline { return pipeline }

        let modelConfiguration = MLModelConfiguration()
        modelConfiguration.computeUnits = configuration.computeUnits
        // The name comes off disk. `--bundle-resources-for-swift-cli` derives it
        // from the model id, so no converted pack ever contains "ControlNet".
        let created = try StableDiffusionPipeline(
            resourcesAt: configuration.resourcesURL,
            controlNet: Array(pack.controlNetNames.prefix(1)),
            configuration: modelConfiguration,
            reduceMemory: configuration.reduceMemory
        )
        try created.loadResources()
        pipeline = created
        return created
    }

    // MARK: - Image bytes

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func encode(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
