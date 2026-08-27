import Foundation

/// What a converted Stable Diffusion pack has to contain.
///
/// `torch2coreml --bundle-resources-for-swift-cli` decides the layout
/// (`OnDevice/README.md`). A wrong name surfaces as a file-not-found inside
/// `loadResources()`, two gigabytes after the mistake — so the install check,
/// the availability answer and the pipeline arguments all read this one type.
public struct ModelPack: Sendable, Equatable {

    public let resourcesURL: URL

    /// File names under `controlnet/`, extension dropped — what
    /// `StableDiffusionPipeline(controlNet:)` takes. The converter derives them
    /// from the model id, so `lllyasviel/sd-controlnet-scribble` arrives as
    /// `lllyasviel_sd-controlnet-scribble` and they cannot be hard-coded.
    public let controlNetNames: [String]

    public static let controlNetDirectory = "controlnet"

    /// The app renders a centreline and records `conditionMode: "scribble"`.
    /// A Canny or pose ControlNet loads perfectly well and produces a picture
    /// conditioned on something else, stamped with metadata that says scribble.
    public static let requiredControlNetKeyword = "scribble"

    /// Needed whatever was converted.
    static let requiredNames = [
        "TextEncoder.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt",
    ]

    /// The UNet, whole or chunked depending on the conversion. Either satisfies
    /// the pipeline; neither does not. It has to be the *controlled* one — a
    /// plain `Unet.mlmodelc` has no ControlNet inputs and cannot be steered.
    static let unetAlternatives = [
        ["ControlledUnet.mlmodelc"],
        ["ControlledUnetChunk1.mlmodelc", "ControlledUnetChunk2.mlmodelc"],
    ]

    /// Where a half-finished install lives, beside the real pack rather than
    /// inside it, so an interrupted copy is never mistaken for a usable one.
    public static func stagingURL(for resourcesURL: URL) -> URL {
        resourcesURL.deletingLastPathComponent()
            .appendingPathComponent(resourcesURL.lastPathComponent + ".incoming", isDirectory: true)
    }

    /// Reads a directory and says whether the pipeline could load it.
    public static func inspect(at url: URL) throws -> ModelPack {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw ModelPackProblem.notADirectory }

        let contents = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        )
        guard !contents.isEmpty else { throw ModelPackProblem.empty }

        // Presence is not enough. An interrupted conversion leaves entries with
        // the right names and nothing inside, and the cost of believing them is
        // gigabytes copied before `loadResources()` fails.
        var missing = requiredNames.filter { !isUsable($0, in: url, present: contents) }
        if !unetAlternatives.contains(where: { alternative in
            alternative.allSatisfy { isUsable($0, in: url, present: contents) }
        }) {
            missing.append(unetAlternatives[0][0])
        }
        guard missing.isEmpty else { throw ModelPackProblem.missing(missing.sorted()) }

        let controlNetDirectoryURL = url.appendingPathComponent(controlNetDirectory)
        let controlNetContents = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: controlNetDirectoryURL.path)) ?? []
        )
        let usableControlNets = controlNetContents
            .filter { $0.hasSuffix(".mlmodelc") }
            .filter { isUsable($0, in: controlNetDirectoryURL, present: controlNetContents) }
            .map { String($0.dropLast(".mlmodelc".count)) }
            .sorted()
        guard !usableControlNets.isEmpty else { throw ModelPackProblem.noControlNet }

        let controlNetNames = usableControlNets.filter {
            $0.localizedCaseInsensitiveContains(requiredControlNetKeyword)
        }
        guard !controlNetNames.isEmpty else {
            throw ModelPackProblem.controlNetNotScribble(found: usableControlNets)
        }

        return ModelPack(resourcesURL: url, controlNetNames: controlNetNames)
    }

    /// Whether one entry is the thing its name claims to be.
    ///
    /// A compiled model is a directory holding a non-empty `coremldata.bin` and
    /// the weights beside it; the tokenizer files are plain files with
    /// something in them.
    ///
    /// ponytail: structural, not semantic. A bundle can still be corrupt in
    /// ways only `loadResources()` sees — loading gigabytes to find out is the
    /// upgrade, and it belongs at generation time, not at install.
    static func isUsable(_ name: String, in directory: URL, present: Set<String>) -> Bool {
        guard present.contains(name), hasContent(directory.appendingPathComponent(name)) else {
            return false
        }
        guard name.hasSuffix(".mlmodelc") else { return true }

        let url = directory.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }

        let inside = Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
        guard inside.contains(compiledModelMarker),
              hasContent(url.appendingPathComponent(compiledModelMarker))
        else { return false }
        // An interrupted conversion or a half-materialised iCloud download can
        // leave the marker with no parameters behind it — including a weights
        // directory whose files were created but never written.
        return weightBearingNames.contains {
            inside.contains($0) && hasContent(url.appendingPathComponent($0))
        }
    }

    /// Whether there are actual bytes here — a file with a size, or a
    /// directory holding one somewhere. A tree of empty files is as useless as
    /// an empty directory, and an interrupted copy produces exactly that.
    private static func hasContent(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else {
            return ((try? url.resourceValues(forKeys: keys))?.fileSize ?? 0) > 0
        }
        guard let entries = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys)
        ) else { return false }
        for case let entry as URL in entries {
            let values = try? entry.resourceValues(forKeys: keys)
            if values?.isRegularFile == true, (values?.fileSize ?? 0) > 0 { return true }
        }
        return false
    }

    static let compiledModelMarker = "coremldata.bin"
    /// Where the actual parameters live, in either compiled format.
    static let weightBearingNames = ["weights", "model.mil", "model0.espresso.weights"]

    /// Bytes a directory holds, counting only regular files. Used for the
    /// installed size and for how far an interrupted copy got.
    public static func directoryBytes(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys)
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in files {
            let values = try? file.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}

/// Why a directory is not a usable pack.
public enum ModelPackProblem: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case notADirectory
    case empty
    case missing([String])
    case noControlNet
    case controlNetNotScribble(found: [String])

    public var description: String {
        switch self {
        case .notADirectory:
            "That is not a folder of converted models."
        case .empty:
            "That folder is empty."
        case .missing(let names):
            "That folder is missing \(names.joined(separator: ", "))."
        case .noControlNet:
            """
            That folder has no ControlNet model, so a route cannot steer it. \
            Convert with --convert-controlnet and --unet-support-controlnet.
            """
        case .controlNetNotScribble(let found):
            """
            That pack's ControlNet is \(found.joined(separator: ", ")), which \
            conditions on something other than a drawn line. Convert \
            lllyasviel/sd-controlnet-scribble instead.
            """
        }
    }

    // Without this a caller reading `localizedDescription` — which is what a
    // generic `catch` reaches for — gets Foundation's opaque wording instead.
    public var errorDescription: String? { description }
}
