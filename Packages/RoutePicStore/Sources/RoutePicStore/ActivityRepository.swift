import Foundation
import RouteKit
import ShapeKit
import SwiftData

/// Reads and writes activities, keeping the database and the image files in step.
///
/// `DESIGN.md` §8.1. Every mutation that touches both goes through here so the
/// ordering rules (write file → rename → insert row; delete row → unlink file)
/// live in one place instead of at each call site.
@MainActor
public final class ActivityRepository {

    public let context: ModelContext
    public let artworkStore: any ArtworkStore

    public init(context: ModelContext, artworkStore: any ArtworkStore) {
        self.context = context
        self.artworkStore = artworkStore
    }

    /// An in-memory container for tests and previews.
    public static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(SchemaV1.models),
            migrationPlan: RoutePicMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    public static func onDiskContainer(url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(SchemaV1.models),
            migrationPlan: RoutePicMigrationPlan.self,
            configurations: ModelConfiguration(url: url)
        )
    }

    // MARK: - Reading

    /// Newest first, paged. The feed never loads every activity: a route blob is
    /// small but decoding thousands of them to draw thumbnails is not.
    public func activities(
        mode: RecordingMode? = nil,
        favouritesOnly: Bool = false,
        offset: Int = 0,
        limit: Int = 50
    ) throws -> [Activity] {
        // The mode goes in the predicate, not into a filter after the fetch:
        // filtering a page of 50 down to the matching rows returns fewer than
        // asked for, and `offset` then skips whatever the previous page dropped.
        var descriptor: FetchDescriptor<Activity>
        if let mode {
            let raw = mode.rawValue
            descriptor = FetchDescriptor<Activity>(
                predicate: #Predicate { $0.deletedAt == nil && $0.modeRaw == raw },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<Activity>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
            )
        }

        guard favouritesOnly else {
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor)
        }

        // Favourites cannot go in the predicate — it is a property of a related
        // row — so this path fetches the ordered set and filters. Acceptable
        // because a favourites list is short by definition; revisit if it is not.
        let all = try context.fetch(descriptor)
            .filter { activity in activity.artworks.contains(where: \.isFavorite) }
        guard offset < all.count else { return [] }
        return Array(all[offset..<min(offset + limit, all.count)])
    }

    public func activity(id: UUID) throws -> Activity? {
        try context.fetch(
            FetchDescriptor<Activity>(predicate: #Predicate { $0.id == id })
        ).first
    }

    public func count() throws -> Int {
        try context.fetchCount(
            FetchDescriptor<Activity>(predicate: #Predicate { $0.deletedAt == nil })
        )
    }

    // MARK: - Writing

    @discardableResult
    public func save(
        route: Route,
        mode: RecordingMode,
        startedAt: Date,
        endedAt: Date,
        placeName: String? = nil,
        note: String? = nil,
        privacyTrimMeters: Int = Int(RouteTrimmer.defaultTrimMeters),
        now: Date = Date()
    ) throws -> Activity {
        let activity = Activity(
            mode: mode,
            startedAt: startedAt,
            endedAt: endedAt,
            statistics: ActivityStatistics.compute(for: route),
            route: route,
            placeName: placeName,
            note: note,
            privacyTrimMeters: privacyTrimMeters,
            updatedAt: now
        )
        context.insert(activity)
        try context.save()
        return activity
    }

    public func updateNote(_ note: String?, on activity: Activity, now: Date = Date()) throws {
        activity.note = note
        activity.updatedAt = now
        try context.save()
    }

    public func updateTrim(_ meters: Int, on activity: Activity, now: Date = Date()) throws {
        activity.privacyTrimMeters = meters
        activity.updatedAt = now
        try context.save()
    }

    /// Attaches a generated image.
    ///
    /// The file lands before the row so a crash between the two leaves an orphan
    /// file — recoverable by `OrphanCleaner` — rather than a row pointing at
    /// nothing, which the UI would render as a broken tile forever.
    @discardableResult
    public func attachArtwork(
        to activity: Activity,
        imageData: Data,
        thumbnailData: Data,
        subject: String,
        why: String,
        stylePreset: String,
        provider: String,
        modelID: String,
        conditionMode: String,
        controlStrength: Double,
        renderIndex: Int,
        seed: Int64,
        costCents: Int,
        now: Date = Date()
    ) throws -> Artwork {
        let id = UUID()
        let imageName = "\(id.uuidString).png"
        let thumbnailName = "\(id.uuidString)-thumb.png"

        try artworkStore.write(imageData, named: imageName)
        do {
            try artworkStore.write(thumbnailData, named: thumbnailName)
        } catch {
            try? artworkStore.delete(named: imageName)
            throw error
        }

        let artwork = Artwork(
            id: id,
            createdAt: now,
            imageFileName: imageName,
            thumbnailFileName: thumbnailName,
            subject: subject,
            why: why,
            stylePreset: stylePreset,
            provider: provider,
            modelID: modelID,
            conditionMode: conditionMode,
            controlStrength: controlStrength,
            renderIndex: renderIndex,
            seed: seed,
            costCents: costCents,
            isSelected: activity.artworks.isEmpty,
            generatedWithTrimMeters: activity.privacyTrimMeters,
            updatedAt: now
        )
        artwork.activity = activity
        context.insert(artwork)

        do {
            try context.save()
        } catch {
            try? artworkStore.delete(named: imageName)
            try? artworkStore.delete(named: thumbnailName)
            throw error
        }
        return artwork
    }

    public func select(_ artwork: Artwork) throws {
        guard let activity = artwork.activity else { return }
        for other in activity.artworks { other.isSelected = (other.id == artwork.id) }
        try context.save()
    }

    /// Deletes an activity and every file it owns.
    ///
    /// The row goes first: an image file with no row is invisible junk that
    /// cleanup handles, while a row with no image is a permanently broken tile.
    public func delete(_ activity: Activity) throws {
        let names = activity.artworks.flatMap { [$0.imageFileName, $0.thumbnailFileName] }
        context.delete(activity)
        try context.save()
        for name in names { try? artworkStore.delete(named: name) }
    }

    public func delete(_ artwork: Artwork) throws {
        let names = [artwork.imageFileName, artwork.thumbnailFileName]
        let activity = artwork.activity
        context.delete(artwork)
        try context.save()
        for name in names { try? artworkStore.delete(named: name) }

        // Selection must survive: deleting the selected image should promote
        // another, not leave the activity with none.
        if let activity, !activity.artworks.isEmpty,
           !activity.artworks.contains(where: \.isSelected),
           let first = activity.artworks.first {
            first.isSelected = true
            try context.save()
        }
    }

    /// Deletes everything — database rows and every file.
    /// `DESIGN.md` §11 requires this to be reachable from settings.
    public func deleteAllData() throws {
        try context.delete(model: Activity.self)
        try context.delete(model: Artwork.self)
        try context.save()
        for name in (try? artworkStore.existingNames()) ?? [] {
            try? artworkStore.delete(named: name)
        }
        discardExportArchives()
    }
}
