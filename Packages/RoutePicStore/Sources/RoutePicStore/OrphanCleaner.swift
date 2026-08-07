import Foundation
import SwiftData

/// Removes image files no row points at.
///
/// `DESIGN.md` §8.1. Writing the file before the row is deliberate — a row
/// pointing at nothing is a permanently broken tile, a file with no row is
/// invisible. This is the sweeper for the second case.
@MainActor
public enum OrphanCleaner {

    /// Files younger than this are never swept: one may be mid-write for an
    /// image whose row has not been inserted yet.
    ///
    /// `nonisolated` so it can be a default argument — a main-actor constant
    /// cannot be evaluated in the nonisolated context where defaults are formed.
    public nonisolated static let minimumAge: TimeInterval = 24 * 60 * 60

    public struct Report: Sendable, Equatable {
        public var deletedNames: [String]
        public var referencedCount: Int
        public var skippedTooRecent: Int
    }

    @discardableResult
    public static func sweep(
        context: ModelContext,
        store: FileArtworkStore,
        minimumAge: TimeInterval = minimumAge,
        now: Date = Date()
    ) throws -> Report {
        let artworks = try context.fetch(FetchDescriptor<Artwork>())
        let referenced = Set(artworks.flatMap { [$0.imageFileName, $0.thumbnailFileName] })

        let all = try store.existingNames()
        let sweepable = try store.namesOlderThan(minimumAge, now: now)

        let orphans = sweepable.subtracting(referenced)
        for name in orphans { try? store.delete(named: name) }

        return Report(
            deletedNames: orphans.sorted(),
            referencedCount: referenced.count,
            skippedTooRecent: all.subtracting(sweepable).subtracting(referenced).count
        )
    }

    /// Rows whose files have vanished — the reverse failure, worth surfacing
    /// because those tiles cannot render and the user should be able to
    /// regenerate or delete them.
    public static func brokenArtworks(
        context: ModelContext,
        store: any ArtworkStore
    ) throws -> [Artwork] {
        let names = (try? store.existingNames()) ?? []
        return try context.fetch(FetchDescriptor<Artwork>())
            .filter { !names.contains($0.imageFileName) }
    }
}
