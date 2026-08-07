import CoreGraphics
import Foundation
import ImageIO
import ShapeKit

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Where generated images live.
///
/// A protocol because `DESIGN.md` §13.1 requires v1 to be local-only while
/// leaving room for a server-backed store in v2 without reshaping the callers.
public protocol ArtworkStore: Sendable {
    func write(_ data: Data, named name: String) throws -> URL
    func url(for name: String) -> URL
    func data(named name: String) throws -> Data
    func delete(named name: String) throws
    func existingNames() throws -> Set<String>
}

/// Files on disk, written atomically.
///
/// `DESIGN.md` §8.1 — the database and the filesystem drift apart the moment
/// either can succeed while the other fails. Writing to a temporary path and
/// renaming means a reader never sees a half-written image, and orphan cleanup
/// (`OrphanCleaner`) handles the case where the file lands but the row does not.
public struct FileArtworkStore: ArtworkStore {

    public let directory: URL

    /// `FileManager.default` is fetched per call rather than stored: it is not
    /// `Sendable`, and this store crosses actors.
    private var fileManager: FileManager { .default }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The app's default location: Application Support, which is backed up and
    /// not user-visible.
    public static func applicationDefault() throws -> FileArtworkStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return try FileArtworkStore(directory: base.appendingPathComponent("artworks", isDirectory: true))
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    @discardableResult
    public func write(_ data: Data, named name: String) throws -> URL {
        let destination = url(for: name)
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")

        try data.write(to: temporary, options: [.atomic])
        // Replace rather than write-in-place: a reader mid-write would otherwise
        // see a truncated image.
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        return destination
    }

    public func data(named name: String) throws -> Data {
        try Data(contentsOf: url(for: name))
    }

    public func delete(named name: String) throws {
        let target = url(for: name)
        guard fileManager.fileExists(atPath: target.path) else { return }
        try fileManager.removeItem(at: target)
    }

    public func existingNames() throws -> Set<String> {
        let contents = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        return Set(
            contents
                .filter { !$0.lastPathComponent.hasPrefix(".tmp-") }
                .map(\.lastPathComponent)
        )
    }

    /// Files whose modification date is older than `age`. Used by
    /// `OrphanCleaner` so an image being written right now is never swept.
    public func namesOlderThan(_ age: TimeInterval, now: Date = Date()) throws -> Set<String> {
        let contents = try fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )
        var names: Set<String> = []
        for url in contents where !url.lastPathComponent.hasPrefix(".tmp-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if now.timeIntervalSince(modified) >= age {
                names.insert(url.lastPathComponent)
            }
        }
        return names
    }
}

/// In-memory store for tests.
public final class InMemoryArtworkStore: ArtworkStore, @unchecked Sendable {
    private var files: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func write(_ data: Data, named name: String) throws -> URL {
        lock.withLock { files[name] = data }
        return url(for: name)
    }

    public func url(for name: String) -> URL {
        URL(fileURLWithPath: "/memory/\(name)")
    }

    public func data(named name: String) throws -> Data {
        guard let data = lock.withLock({ files[name] }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }

    public func delete(named name: String) throws {
        lock.withLock { _ = files.removeValue(forKey: name) }
    }

    public func existingNames() throws -> Set<String> {
        lock.withLock { Set(files.keys) }
    }
}

public enum ThumbnailRenderer {

    /// Feed thumbnails are square and small; `DESIGN.md` §9 shows a 3-column
    /// grid, so full 1024² images would be decoded at ~10× the needed size.
    public static let size = 320

    public static func thumbnail(from image: CGImage, side: Int = size) throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CocoaError(.fileWriteUnknown) }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return try encodePNG(scaled)
    }

    public static func encodePNG(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        #if canImport(UniformTypeIdentifiers)
        let type = UTType.png.identifier as CFString
        #else
        let type = "public.png" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}
