import Foundation
import Testing
@testable import GenerationCoreML

@Suite("Model pack layout")
struct ModelPackTests {

    @Test("A converted pack is recognised and its ControlNet name read off disk")
    func acceptsAConvertedPack() throws {
        let url = try ModelPackFixture.make()
        defer { try? FileManager.default.removeItem(at: url) }

        let pack = try ModelPack.inspect(at: url)
        #expect(pack.controlNetNames == ["lllyasviel_sd-controlnet-scribble"])
    }

    /// The pipeline is handed one. Naming the others in an artwork's
    /// provenance would credit models that never ran.
    @Test("The active ControlNet is the one the pipeline gets")
    func activeControlNetIsTheOneThatRuns() throws {
        let url = try ModelPackFixture.make(
            ModelPackFixture.complete + [
                "controlnet/other_sd-controlnet-scribble.mlmodelc/coremldata.bin",
                "controlnet/other_sd-controlnet-scribble.mlmodelc/weights/w.bin",
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let pack = try ModelPack.inspect(at: url)
        #expect(pack.controlNetNames.count == 2)
        #expect(pack.activeControlNet == pack.controlNetNames.first)
    }

    @Test("A chunked UNet is as good as a whole one")
    func acceptsAChunkedUnet() throws {
        let url = try ModelPackFixture.make(ModelPackFixture.chunkedUnet)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: Never.self) { try ModelPack.inspect(at: url) }
    }

    /// A UNet converted without `--unet-support-controlnet` has no ControlNet
    /// inputs, and the pipeline fails at load rather than at conversion.
    @Test("A plain UNet does not count as a controlled one")
    func rejectsAnUncontrolledUnet() throws {
        let url = try ModelPackFixture.make([
            "TextEncoder.mlmodelc/coremldata.bin", "TextEncoder.mlmodelc/weights/w.bin",
            "VAEDecoder.mlmodelc/coremldata.bin", "VAEDecoder.mlmodelc/weights/w.bin",
            "Unet.mlmodelc/coremldata.bin", "Unet.mlmodelc/weights/w.bin",
            "vocab.json", "merges.txt",
            "controlnet/scribble.mlmodelc/coremldata.bin",
            "controlnet/scribble.mlmodelc/weights/w.bin",
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ModelPackProblem.missing(["ControlledUnet.mlmodelc"])) {
            try ModelPack.inspect(at: url)
        }
    }

    @Test("The tokenizer files are not optional")
    func rejectsAPackWithoutTokenizerFiles() throws {
        let url = try ModelPackFixture.make(
            ModelPackFixture.complete.filter { $0 != "merges.txt" }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ModelPackProblem.missing(["merges.txt"])) {
            try ModelPack.inspect(at: url)
        }
    }

    @Test("A pack with no ControlNet cannot be steered by a route")
    func rejectsAPackWithoutControlNet() throws {
        let url = try ModelPackFixture.make(
            ModelPackFixture.complete.filter { !$0.hasPrefix("controlnet/") }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ModelPackProblem.noControlNet) { try ModelPack.inspect(at: url) }
    }

    /// An interrupted conversion leaves entries with the right names and
    /// nothing inside. Believing them costs gigabytes before the load fails.
    @Test("An entry with the right name but nothing in it is not a model")
    func rejectsPlaceholders() throws {
        let hollow = try ModelPackFixture.make(
            ModelPackFixture.complete.filter { !$0.hasPrefix("TextEncoder") }
        )
        try FileManager.default.createDirectory(
            at: hollow.appendingPathComponent("TextEncoder.mlmodelc"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: hollow) }

        #expect(throws: ModelPackProblem.missing(["TextEncoder.mlmodelc"])) {
            try ModelPack.inspect(at: hollow)
        }
    }

    @Test("An empty tokenizer file does not count")
    func rejectsEmptyTokenizerFiles() throws {
        let url = try ModelPackFixture.make(
            ModelPackFixture.complete.filter { $0 != "merges.txt" }
        )
        try Data().write(to: url.appendingPathComponent("merges.txt"))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ModelPackProblem.missing(["merges.txt"])) {
            try ModelPack.inspect(at: url)
        }
    }

    @Test("A hollow ControlNet entry does not make a pack steerable")
    func rejectsHollowControlNet() throws {
        let url = try ModelPackFixture.make(
            ModelPackFixture.complete.filter { !$0.hasPrefix("controlnet/") }
        )
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("controlnet/scribble.mlmodelc"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ModelPackProblem.noControlNet) { try ModelPack.inspect(at: url) }
    }

    /// A conversion killed after the marker is written leaves a bundle with no
    /// parameters in it — which loads only far enough to fail.
    @Test("A compiled model with no weights is not a model")
    func rejectsAModelWithNoWeights() throws {
        let url = try ModelPackFixture.make(
            ModelPackFixture.complete.filter { !$0.hasPrefix("TextEncoder.mlmodelc/weights") }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ModelPackProblem.missing(["TextEncoder.mlmodelc"])) {
            try ModelPack.inspect(at: url)
        }
    }

    /// A copy that created the files but never wrote them leaves a tree that
    /// looks complete from the names alone.
    @Test("Weights that are all zero bytes are not weights")
    func rejectsEmptyWeights() throws {
        let url = try ModelPackFixture.make()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(
            to: url.appendingPathComponent("TextEncoder.mlmodelc/weights/weight.bin")
        )

        #expect(throws: ModelPackProblem.missing(["TextEncoder.mlmodelc"])) {
            try ModelPack.inspect(at: url)
        }
    }

    /// The app draws a centreline and stamps `conditionMode: "scribble"` on the
    /// result. A Canny pack loads fine and makes that stamp a lie.
    @Test("A ControlNet that conditions on something else is refused")
    func rejectsANonScribbleControlNet() throws {
        let url = try ModelPackFixture.make(
            ModelPackFixture.complete.map {
                $0.replacingOccurrences(
                    of: "lllyasviel_sd-controlnet-scribble",
                    with: "lllyasviel_sd-controlnet-canny"
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(
            throws: ModelPackProblem.controlNetNotScribble(
                found: ["lllyasviel_sd-controlnet-canny"]
            )
        ) { try ModelPack.inspect(at: url) }
    }

    @Test("Nothing there and nothing in it are different answers")
    func distinguishesAbsentFromEmpty() throws {
        let empty = try ModelPackFixture.make([])
        defer { try? FileManager.default.removeItem(at: empty) }

        #expect(throws: ModelPackProblem.empty) { try ModelPack.inspect(at: empty) }
        #expect(throws: ModelPackProblem.notADirectory) {
            try ModelPack.inspect(at: ModelPackFixture.emptySlot())
        }
    }

    @Test("Staging sits beside the pack, never inside it")
    func stagingIsASibling() {
        let destination = ModelPackFixture.emptySlot()
        let staging = ModelPack.stagingURL(for: destination)

        #expect(staging.deletingLastPathComponent() == destination.deletingLastPathComponent())
        #expect(!staging.path.hasPrefix(destination.path + "/"))
    }

    @Test("Directory size counts files, not folders")
    func measuresBytes() throws {
        let url = try ModelPackFixture.make(bytesEach: 100)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ModelPack.directoryBytes(at: url) == 100 * ModelPackFixture.complete.count)
    }
}
