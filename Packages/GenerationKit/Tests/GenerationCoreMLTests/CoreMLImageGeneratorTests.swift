import Foundation
import GenerationKit
import Testing
@testable import GenerationCoreML

/// The model pack is gigabytes and is not in the repository, so what is checked
/// here is everything that runs *before* the pipeline: which of the three
/// unavailability answers a given pack directory produces. Getting that wrong
/// is what makes the app tell someone their device is unsupported when they
/// simply have not downloaded anything yet.
@Suite("Core ML generator availability")
struct CoreMLImageGeneratorTests {

    private func generator(_ directory: URL?) -> CoreMLImageGenerator {
        CoreMLImageGenerator(
            configuration: .init(
                resourcesURL: directory
                    ?? FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString),
                packBytes: 1_800_000_000
            )
        )
    }

    @Test("No pack means a download, not a broken device")
    func missingPackAsksForDownload() async {
        #expect(await generator(nil).unavailability() == .modelNotInstalled(bytesRequired: 1_800_000_000))
    }

    @Test("An empty folder reads as nothing downloaded, not a broken device")
    func emptyDirectoryAsksForDownload() async throws {
        let url = try ModelPackFixture.make([])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await generator(url).unavailability() == .modelNotInstalled(bytesRequired: 1_800_000_000))
    }

    @Test("A pack without ControlNet cannot be steered by a route")
    func packWithoutControlNetIsUnsupported() async throws {
        let url = try ModelPackFixture.make(
            ModelPackFixture.complete.filter { !$0.hasPrefix("controlnet/") }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        guard case .deviceUnsupported = await generator(url).unavailability() else {
            Issue.record("a pack missing ControlNet should read as unsupported")
            return
        }
    }

    @Test("A converted pack reports available")
    func completePackIsAvailable() async throws {
        let url = try ModelPackFixture.make()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await generator(url).unavailability() == nil)
        #expect(await generator(url).isAvailable)
    }

    /// A copy killed part-way must not read as "never started" over a folder
    /// already holding most of a pack.
    @Test("An interrupted install reads as one in progress")
    func stagedInstallReadsAsInProgress() async throws {
        let source = try ModelPackFixture.make(bytesEach: 64)
        let destination = ModelPackFixture.emptySlot()
        let staging = ModelPack.stagingURL(for: destination)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }

        final class Handle: @unchecked Sendable { var task: Task<Void, any Error>? }
        let handle = Handle()
        handle.task = Task {
            try await ModelPackInstaller(destination: destination)
                .install(from: source) { _ in handle.task?.cancel() }
        }
        _ = try? await handle.task?.value
        // The installer cleans up after itself, so the interrupted state is
        // recreated here rather than caught mid-flight.
        try FileManager.default.copyItem(at: source, to: staging)

        guard case .installInProgress = await generator(destination).unavailability() else {
            Issue.record("a staged copy should read as a download in progress")
            return
        }
    }

    /// A generic `catch` reaches for `localizedDescription`, and a type that
    /// only conforms to `CustomStringConvertible` gives Foundation's wording.
    @Test("The reason survives being read as a localised description")
    func reasonsReadTheSameEitherWay() {
        let problems: [any Error] = [
            ModelPackProblem.noControlNet,
            ModelPackInstaller.Failure.notEnoughSpace(needsBytes: 2_000_000_000, freeBytes: 1),
            OnDeviceUnavailability.modelNotInstalled(bytesRequired: 1_800_000_000),
        ]
        for problem in problems {
            #expect(problem.localizedDescription == String(describing: problem))
        }
        #expect(
            OnDeviceUnavailability.modelNotInstalled(bytesRequired: 1_800_000_000)
                .description.contains("Settings")
        )
    }

    @Test("The strength it reports is the one it can actually apply")
    func reportsTheStrengthItCanApply() {
        // Apple's pipeline adds the residuals unscaled, so recording the
        // requested value would put a number in the artwork no image was made
        // at. 1.0 is the bottom of the window the strength grid left standing.
        #expect(generator(nil).fixedControlStrength == 1.0)
        #expect(GenerationRequest.usableControlStrength.contains(1.0))
    }
}
