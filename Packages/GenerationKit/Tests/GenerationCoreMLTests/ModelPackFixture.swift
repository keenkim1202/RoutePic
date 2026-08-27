import Foundation
@testable import GenerationCoreML

/// Builds pack directories on disk. The real pack is gigabytes and is not in
/// the repository, so the layout is what gets tested — and the layout is what
/// was wrong: no converter ever writes `ControlNet.mlmodelc` at the root.
enum ModelPackFixture {

    static let complete = [
        "TextEncoder.mlmodelc/coremldata.bin",
        "TextEncoder.mlmodelc/weights/weight.bin",
        "VAEDecoder.mlmodelc/coremldata.bin",
        "VAEDecoder.mlmodelc/weights/weight.bin",
        "ControlledUnet.mlmodelc/coremldata.bin",
        "ControlledUnet.mlmodelc/weights/weight.bin",
        "vocab.json",
        "merges.txt",
        "controlnet/lllyasviel_sd-controlnet-scribble.mlmodelc/coremldata.bin",
        "controlnet/lllyasviel_sd-controlnet-scribble.mlmodelc/weights/weight.bin",
    ]

    static let chunkedUnet = [
        "TextEncoder.mlmodelc/coremldata.bin",
        "TextEncoder.mlmodelc/weights/weight.bin",
        "VAEDecoder.mlmodelc/coremldata.bin",
        "VAEDecoder.mlmodelc/weights/weight.bin",
        "ControlledUnetChunk1.mlmodelc/coremldata.bin",
        "ControlledUnetChunk1.mlmodelc/weights/weight.bin",
        "ControlledUnetChunk2.mlmodelc/coremldata.bin",
        "ControlledUnetChunk2.mlmodelc/weights/weight.bin",
        "vocab.json",
        "merges.txt",
        "controlnet/lllyasviel_sd-controlnet-scribble.mlmodelc/coremldata.bin",
        "controlnet/lllyasviel_sd-controlnet-scribble.mlmodelc/weights/weight.bin",
    ]

    static func make(_ relativePaths: [String] = complete, bytesEach: Int = 16) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for path in relativePaths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x2A, count: bytesEach).write(to: file)
        }
        return root
    }

    /// A destination path that does not exist yet, so an install has to create it.
    static func emptySlot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("StableDiffusionPack", isDirectory: true)
    }
}
