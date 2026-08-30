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
        inMonth month: MonthKey? = nil,
        fallbackTimeZone: TimeZone = .current,
        offset: Int = 0,
        limit: Int = 50
    ) throws -> [Activity] {
        var descriptor = Self.descriptor(mode: mode, month: month)

        guard favouritesOnly || month != nil else {
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = limit
            return try context.fetch(descriptor)
        }

        // Two things the store cannot decide: a favourite lives on a related
        // row, and a month depends on the zone each activity was recorded in,
        // which SQL cannot apply per row. Both slice the ordered set instead,
        // which also keeps `offset` honest — paging a predicate whose rows this
        // then drops would skip whatever the previous page dropped.
        let all = try context.fetch(descriptor).filter { activity in
            if favouritesOnly, !activity.artworks.contains(where: \.isFavorite) { return false }
            if let month, activity.monthKey(fallback: fallbackTimeZone) != month { return false }
            return true
        }
        guard offset < all.count else { return [] }
        return Array(all[offset..<min(offset + limit, all.count)])
    }

    /// Every month the collection has something in, newest first.
    ///
    /// Covers the whole collection, not the page on screen — a month list built
    /// from the first 200 rows cannot reach last spring, which is its point.
    /// Only the two columns a month needs are read, so that costs no route blobs.
    public func activityMonths(
        mode: RecordingMode? = nil,
        favouritesOnly: Bool = false,
        fallbackTimeZone: TimeZone = .current
    ) throws -> [MonthSummary] {
        var descriptor = Self.descriptor(mode: mode, month: nil)
        // A favourite is a property of a related row, so that path needs the
        // artworks and cannot be narrowed to two columns.
        if !favouritesOnly {
            descriptor.propertiesToFetch = [\.startedAt, \.timeZoneID]
        }

        var counts: [MonthKey: Int] = [:]
        for activity in try context.fetch(descriptor) {
            if favouritesOnly, !activity.artworks.contains(where: \.isFavorite) { continue }
            counts[activity.monthKey(fallback: fallbackTimeZone), default: 0] += 1
        }
        // By key, not by the order the rows arrived: near a boundary an instant
        // order can meet August before an older September.
        return counts.keys.sorted(by: >).map { MonthSummary(id: $0, count: counts[$0] ?? 0) }
    }

    private static func descriptor(
        mode: RecordingMode?, month: MonthKey?
    ) -> FetchDescriptor<Activity> {
        // The mode goes in the predicate so a page of 50 comes back as 50.
        // Two predicates rather than one holding an optional: a `#Predicate`
        // becomes a store query, and an unwrap inside one has no translation.
        // A day either side of the UTC month: the widest zone offsets are
        // −12 and +14 hours, so no zone's version of this month falls outside.
        // The exact boundary is settled per row by the caller.
        let window = month.map(Self.utcWindow)
        let from = window?.start ?? .distantPast
        let until = window?.end ?? .distantFuture
        let order = [SortDescriptor(\Activity.startedAt, order: .reverse)]

        guard let raw = mode?.rawValue else {
            return FetchDescriptor<Activity>(
                predicate: #Predicate {
                    $0.deletedAt == nil && $0.startedAt >= from && $0.startedAt < until
                },
                sortBy: order
            )
        }
        return FetchDescriptor<Activity>(
            predicate: #Predicate {
                $0.deletedAt == nil && $0.modeRaw == raw
                    && $0.startedAt >= from && $0.startedAt < until
            },
            sortBy: order
        )
    }

    static func utcWindow(for month: MonthKey) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let slack: TimeInterval = 86_400
        guard let start = calendar.date(
            from: DateComponents(year: month.year, month: month.month, day: 1)
        ), let interval = calendar.dateInterval(of: .month, for: start) else {
            return (.distantPast, .distantFuture)
        }
        return (interval.start.addingTimeInterval(-slack), interval.end.addingTimeInterval(slack))
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
        /// The zone the activity happened in. `nil` means this device's, which
        /// is right for a recording made here and wrong for one imported from
        /// somewhere else — the collection groups months by this.
        timeZoneID: String? = nil,
        placeName: String? = nil,
        note: String? = nil,
        privacyTrimMeters: Int = Int(RouteTrimmer.defaultTrimMeters),
        now: Date = Date()
    ) throws -> Activity {
        let activity = Activity(
            mode: mode,
            startedAt: startedAt,
            endedAt: endedAt,
            timeZoneID: timeZoneID ?? TimeZone.current.identifier,
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

    /// Attaches a generated image, deriving its thumbnail.
    ///
    /// The file lands before the row so a crash between the two leaves an orphan
    /// file — recoverable by `OrphanCleaner` — rather than a row pointing at
    /// nothing, which the UI would render as a broken tile forever.
    ///
    /// The thumbnail is not a parameter on purpose: the one caller there was
    /// passed the full 1024² image, so every picture was stored twice at full
    /// size and the 3-column grid decoded all of it.
    @discardableResult
    public func attachArtwork(
        to activity: Activity,
        imageData: Data,
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

        // A picture nobody can see beats a picture nobody kept: if the scale
        // fails, the full image stands in rather than losing the artwork.
        let thumbnailData = (try? ThumbnailRenderer.thumbnail(fromEncoded: imageData)) ?? imageData

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

    /// The flags go back if the write does not land. Left changed, the hero and
    /// the accessibility description show a selection the disk never took, and
    /// the next unrelated save commits it.
    public func select(_ artwork: Artwork) throws {
        guard let activity = artwork.activity else { return }
        let before = activity.artworks.map { ($0, $0.isSelected) }
        for other in activity.artworks { other.isSelected = (other.id == artwork.id) }
        do {
            try context.save()
        } catch {
            for (each, was) in before { each.isSelected = was }
            throw error
        }
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
