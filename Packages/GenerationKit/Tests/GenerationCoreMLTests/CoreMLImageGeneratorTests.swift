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

    private func makePackDirectory(_ names: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        return url
    }

    @Test("No pack means a download, not a broken device")
    func missingPackAsksForDownload() async throws {
        let result = try await generator(nil).unavailability()
        #expect(result == .modelNotDownloaded(bytesRequired: 1_800_000_000))
    }

    @Test("A directory with nothing compiled in it reads as an unfinished download")
    func emptyDirectoryReadsAsInProgress() async throws {
        let url = try makePackDirectory([])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await generator(url).unavailability()
        #expect(result == .downloadInProgress(fractionComplete: 0))
    }

    @Test("A pack without ControlNet cannot be steered by a route")
    func packWithoutControlNetIsUnsupported() async throws {
        let url = try makePackDirectory(["Unet.mlmodelc", "TextEncoder.mlmodelc"])
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await generator(url).unavailability()
        guard case .deviceUnsupported = result else {
            Issue.record("expected .deviceUnsupported, got \(String(describing: result))")
            return
        }
    }

    @Test("A complete pack reports available")
    func completePackIsAvailable() async throws {
        let url = try makePackDirectory([
            "Unet.mlmodelc", "TextEncoder.mlmodelc", "VAEDecoder.mlmodelc", "ControlNet.mlmodelc",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try await generator(url).unavailability() == nil)
        #expect(await generator(url).isAvailable)
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
