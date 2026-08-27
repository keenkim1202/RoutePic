import Foundation

/// Puts a converted model pack where the generator can find it.
///
/// There is no server behind this app, so there is nothing to download from:
/// the pack is converted on a Mac (`OnDevice/README.md`) and picked as a folder
/// in Files. Swapping that for an `https` download later touches only `install`.
public actor ModelPackInstaller {

    public struct Progress: Sendable, Equatable {
        public let bytesCopied: Int64
        public let bytesTotal: Int64

        public var fraction: Double {
            bytesTotal > 0 ? min(1, Double(bytesCopied) / Double(bytesTotal)) : 0
        }
    }

    public enum Failure: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
        case notEnoughSpace(needsBytes: Int64, freeBytes: Int64)

        public var description: String {
            switch self {
            case .notEnoughSpace(let needs, let free):
                let gigabytes = { (bytes: Int64) in Double(bytes) / 1_000_000_000 }
                return String(
                    format: "The picture model needs %.1f GB and this device has %.1f GB free.",
                    gigabytes(needs), gigabytes(free)
                )
            }
        }

        public var errorDescription: String? { description }
    }

    /// An install has awaits in it, so other calls on this actor interleave
    /// with it. The launch sweep is one of them, and it would delete the
    /// staging directory out from under a copy that had just begun.
    private var isInstalling = false

    private let destination: URL
    private var staging: URL { ModelPack.stagingURL(for: destination) }
    /// The expected size, kept beside the staging directory rather than inside
    /// it: anything inside would be copied into the finished pack.
    private var stagingSize: URL {
        staging.deletingLastPathComponent()
            .appendingPathComponent(staging.lastPathComponent + ".bytes")
    }

    public init(destination: URL) {
        self.destination = destination
    }

    public func installed() -> ModelPack? {
        try? ModelPack.inspect(at: destination)
    }

    public func installedBytes() -> Int64 {
        ModelPack.directoryBytes(at: destination)
    }

    /// Copies a pack into the app's own storage.
    ///
    /// The caller owns the security scope — a folder picked in Files is
    /// unreadable without `startAccessingSecurityScopedResource`, and the
    /// failure reads as a missing model rather than a denied one.
    public func install(
        from source: URL,
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws {
        isInstalling = true
        defer { isInstalling = false }

        // Validate before copying: a wrong folder should fail in a second, not
        // after two gigabytes have moved.
        _ = try ModelPack.inspect(at: source)

        let files = try regularFiles(under: source)
        let total = files.reduce(0) { $0 + $1.bytes }
        try checkSpace(for: total)

        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try? Self.excludeFromBackup(staging)
        try? Data("\(total)".utf8).write(to: stagingSize, options: [.atomic])

        do {
            var copied: Int64 = 0
            for file in files {
                try Task.checkCancellation()
                let target = staging.appendingPathComponent(file.relativePath)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: file.url, to: target)
                copied += file.bytes
                // ponytail: one report per file, so a single 800 MB UNet chunk
                // moves the bar in one step. Stream the copy if that reads as
                // a hang.
                await progress(Progress(bytesCopied: copied, bytesTotal: total))
            }
            // The loop's own check cannot see a Stop that lands while the last
            // file — often the largest — is inside a synchronous copy. Without
            // this the install completes after being cancelled.
            try Task.checkCancellation()
            // What was copied, not what was picked: a truncated copy has the
            // right names and would swap into place as a working pack.
            _ = try ModelPack.inspect(at: staging)
            try swapIntoPlace()
            try? FileManager.default.removeItem(at: stagingSize)
        } catch {
            // A partial pack that stayed at the staging path is recoverable;
            // one that reached the destination would report itself as usable
            // and fail at load instead.
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: stagingSize)
            throw error
        }
    }

    /// How far an interrupted install got, or `nil` when none is under way.
    ///
    /// Survives the app being killed mid-copy — otherwise the next launch says
    /// "not downloaded" over a folder holding a gigabyte and a half.
    public func stagedFraction() -> Double? {
        guard FileManager.default.fileExists(atPath: staging.path) else { return nil }
        guard let text = try? String(contentsOf: stagingSize, encoding: .utf8),
              let total = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              total > 0
        else { return 0 }
        return min(0.99, Double(ModelPack.directoryBytes(at: staging)) / Double(total))
    }

    /// Throws away a copy nothing is driving any more. Nothing resumes an
    /// install across a launch, so leaving the staged bytes there would show a
    /// progress bar that never moves.
    public func discardStaged() {
        guard !isInstalling else { return }
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.removeItem(at: stagingSize)
    }

    public func remove() throws {
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.removeItem(at: stagingSize)
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.removeItem(at: destination)
    }

    // MARK: - Copying

    private struct SourceFile {
        let url: URL
        let relativePath: String
        let bytes: Int64
    }

    private func regularFiles(under root: URL) throws -> [SourceFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        // Without a handler the enumerator skips a subtree it cannot read and
        // says nothing, so a model missing half its weights would copy and
        // install as a whole one. Returning false stops it.
        let failure = EnumerationFailure()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                failure.record(error)
                return false
            }
        ) else { throw ModelPackProblem.notADirectory }

        // Resolving both sides drops the `/private` prefix macOS puts on
        // temporary directories, which otherwise makes every relative path
        // start with the whole absolute path.
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var files: [SourceFile] = []
        for case let url as URL in enumerator {
            // Thrown, not shrugged off: a provider that cannot describe a file
            // would otherwise drop it from the copy, and the pack would install
            // and report itself fine with a model missing pieces.
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            files.append(
                SourceFile(
                    url: url,
                    relativePath: String(path.dropFirst(base.count)).trimmingCharacters(
                        in: CharacterSet(charactersIn: "/")
                    ),
                    bytes: Int64(values.fileSize ?? 0)
                )
            )
        }
        if let error = failure.error { throw error }
        return files
    }

    /// Carries an enumeration error out of the handler, which Foundation calls
    /// synchronously but which cannot capture a local `var` under strict
    /// concurrency.
    private final class EnumerationFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (any Error)?
        var error: (any Error)? { lock.withLock { stored } }
        func record(_ error: any Error) { lock.withLock { if stored == nil { stored = error } } }
    }

    private func checkSpace(for bytes: Int64) throws {
        let parent = destination.deletingLastPathComponent()
        let values = try? parent.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        // Only the staged copy is new. A pack already installed is holding bytes
        // the volume has already reported as taken, so counting it again would
        // refuse a replacement that fits.
        guard free >= bytes else {
            throw Failure.notEnoughSpace(needsBytes: bytes, freeBytes: free)
        }
    }

    private func swapIntoPlace() throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        try Self.excludeFromBackup(destination)
    }

    /// Keeps the pack out of iCloud and device backups.
    ///
    /// It stays in Application Support so the system does not evict it, but it
    /// is reproducible from a conversion the person already ran — putting two
    /// gigabytes of it in every backup is a cost with nothing bought.
    static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
