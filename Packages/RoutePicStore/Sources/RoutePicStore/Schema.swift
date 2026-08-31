import Foundation
import RouteKit
import ShapeKit
import SwiftData

/// `DESIGN.md` §8.1. Versioned from the start: a migration plan added later
/// cannot recover data already written by an unversioned schema.
public enum SchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] { [Activity.self, Artwork.self] }
}

public enum RoutePicMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

/// One recorded activity.
///
/// Coordinates live in `routeBlob`, not in child rows: an hour of running is
/// ~3,600 fixes, and one SwiftData row each makes feed scrolling collapse
/// (`DESIGN.md` §8.2).
@Model
public final class Activity {

    // DESIGN.md §8.1 specified `#Index` on startedAt and (mode, startedAt).
    // That macro requires iOS 18 / macOS 15, which conflicts with the iOS 17
    // minimum in §10. Dropped rather than raising the floor: the feed pages 50
    // rows at a time on an ordered scan, so the index buys little at the sizes
    // a personal collection reaches. Revisit if the minimum ever moves to 18.
    @Attribute(.unique) public var id: UUID

    public var modeRaw: String
    public var startedAt: Date
    public var endedAt: Date
    /// The zone the activity happened in, so a later timezone change does not
    /// silently move a run to another day.
    public var timeZoneID: String

    public var movingDuration: TimeInterval
    public var pausedDuration: TimeInterval
    public var gapDuration: TimeInterval
    public var distanceMeters: Double
    public var elevationGainMeters: Double

    /// Compact encoded coordinates — the original, never trimmed or smoothed.
    public var routeBlob: Data
    /// `Codable [RouteSegment]`. Losing this joins gaps with a straight line
    /// the user never walked (`DESIGN.md` §5.4).
    public var segmentsBlob: Data

    public var placeName: String?
    public var note: String?
    public var privacyTrimMeters: Int

    // v2 sync anchors (OQ-A). Nothing is transmitted in v1; the fields exist so
    // adding a social feed later does not require a schema migration.
    public var remoteID: String?
    public var updatedAt: Date
    public var deletedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Artwork.activity)
    public var artworks: [Artwork] = []

    public init(
        id: UUID = UUID(),
        mode: RecordingMode,
        startedAt: Date,
        endedAt: Date,
        timeZoneID: String = TimeZone.current.identifier,
        statistics: ActivityStatistics,
        route: Route,
        placeName: String? = nil,
        note: String? = nil,
        privacyTrimMeters: Int = Int(RouteTrimmer.defaultTrimMeters),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.modeRaw = mode.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZoneID = timeZoneID
        self.movingDuration = statistics.movingDuration
        self.pausedDuration = statistics.pausedDuration
        self.gapDuration = statistics.gapDuration
        self.distanceMeters = statistics.distanceMeters
        self.elevationGainMeters = statistics.elevationGainMeters
        self.routeBlob = PolylineCodec.encode(route.points)
        self.segmentsBlob = (try? JSONEncoder().encode(route.segments)) ?? Data()
        self.placeName = placeName
        self.note = note
        self.privacyTrimMeters = privacyTrimMeters
        self.updatedAt = updatedAt
    }

    public var mode: RecordingMode {
        get { RecordingMode(rawValue: modeRaw) ?? .walk }
        set { modeRaw = newValue.rawValue }
    }

    public var statistics: ActivityStatistics {
        ActivityStatistics(
            distanceMeters: distanceMeters,
            elapsedDuration: endedAt.timeIntervalSince(startedAt),
            movingDuration: movingDuration,
            pausedDuration: pausedDuration,
            gapDuration: gapDuration,
            elevationGainMeters: elevationGainMeters
        )
    }

    /// The stored route, decoded. Throws rather than returning an empty route:
    /// a decode failure means data loss, and silently showing nothing would
    /// hide it.
    public func route() throws -> Route {
        try storedRoute.decode()
    }

    /// The stored bytes on their own, so a caller can decode them off the
    /// actor this model belongs to — the grid decodes one per tile.
    public var storedRoute: StoredRoute {
        StoredRoute(routeBlob: routeBlob, segmentsBlob: segmentsBlob)
    }

    /// Everything a screen asks about a stored route, from one decode.
    ///
    /// Both answers need the polyline: a gap count taken from the segments
    /// alone would describe a route the app is refusing to draw. Asked
    /// separately they cost a full decode each, and the detail screen asks
    /// four times in one pass.
    public struct RouteSummary: Equatable, Sendable {
        /// Refusing to draw a route only tells somebody something if they are
        /// told — otherwise a corrupt recording is an unexplained blank tile,
        /// which is the hiding `route()` exists to refuse.
        public let isReadable: Bool
        /// Zero when the route cannot be read: the drawing is already refused,
        /// and a count would be a second claim on top of a broken one.
        public let gapCount: Int
    }

    public func routeSummary() -> RouteSummary {
        guard let route = try? route() else {
            return RouteSummary(isReadable: false, gapCount: 0)
        }
        return RouteSummary(
            isReadable: true,
            gapCount: route.segments.count { $0.kind == .gap }
        )
    }

    public var isRouteReadable: Bool { routeSummary().isReadable }

    public var gapCount: Int { routeSummary().gapCount }
}

/// The two blobs a route is stored as, and the decode of them. `Sendable` and
/// free of the model, so the decode can happen off the actor holding the row.
public struct StoredRoute: Sendable {
    public let routeBlob: Data
    public let segmentsBlob: Data

    public init(routeBlob: Data, segmentsBlob: Data) {
        self.routeBlob = routeBlob
        self.segmentsBlob = segmentsBlob
    }

    /// Throws rather than returning an empty route: a decode failure means
    /// data loss, and silently showing nothing would hide it.
    public func decode() throws -> Route {
        let points = try PolylineCodec.decode(routeBlob)
        // Neither guess is available. One long moving run draws the straight
        // line across a dropout this field exists to prevent; rebuilding from
        // the stored timestamps invents a gap wherever somebody sat still long
        // enough for their fixes to be filtered out — `RecordingSession.ingest`
        // measures against the last fix it could position from, and
        // `routeBlob` does not keep those.
        //
        // A route is a claim about where a person went, so a lost segmentation
        // is refused the same way lost coordinates are.
        guard let segments = try? JSONDecoder().decode([RouteSegment].self, from: segmentsBlob)
        else { throw StoredRouteFailure.segmentationLost }
        return Route(points: points, segments: segments)
    }
}

/// Why a stored route could not be handed back.
public enum StoredRouteFailure: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// `segmentsBlob` did not decode. The coordinates survived, but which
    /// stretches were walked and which were dropouts did not.
    case segmentationLost

    public var description: String {
        switch self {
        case .segmentationLost:
            """
            This recording's structure could not be read. Its route is not \
            drawn rather than guessing which stretches were missing.
            """
        }
    }

    // Without this the alerts that show `localizedDescription` print
    // Foundation's opaque wording instead of the sentence above.
    public var errorDescription: String? { description }
}

/// One generated image (or locally rendered card) for an activity.
@Model
public final class Artwork {

    @Attribute(.unique) public var id: UUID

    /// The only link to the activity. `DESIGN.md` §8.1 v0.1 also carried an
    /// `activityId` field; two sources of truth for one relationship drift.
    public var activity: Activity?

    public var createdAt: Date
    public var imageFileName: String
    public var thumbnailFileName: String

    public var subject: String
    /// Why the model saw this subject — shown to the user verbatim
    /// (`DESIGN.md` §7.2) and used as the VoiceOver description (§9).
    public var why: String
    public var stylePreset: String
    public var providerRaw: String
    public var modelID: String
    public var conditionModeRaw: String
    public var controlStrength: Double
    /// Index into `Orientation.all`. Reordering that array invalidates this.
    public var renderIndex: Int
    public var seed: Int64
    public var costCents: Int

    public var isSelected: Bool
    public var isFavorite: Bool

    /// The trim in force when this image was generated. A later, stricter trim
    /// cannot be applied retroactively to a generated image, so the UI shows a
    /// badge instead of pretending otherwise (`DESIGN.md` §8.4).
    public var generatedWithTrimMeters: Int

    public var remoteID: String?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        imageFileName: String,
        thumbnailFileName: String,
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
        isSelected: Bool = false,
        isFavorite: Bool = false,
        generatedWithTrimMeters: Int,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.imageFileName = imageFileName
        self.thumbnailFileName = thumbnailFileName
        self.subject = subject
        self.why = why
        self.stylePreset = stylePreset
        self.providerRaw = provider
        self.modelID = modelID
        self.conditionModeRaw = conditionMode
        self.controlStrength = controlStrength
        self.renderIndex = renderIndex
        self.seed = seed
        self.costCents = costCents
        self.isSelected = isSelected
        self.isFavorite = isFavorite
        self.generatedWithTrimMeters = generatedWithTrimMeters
        self.updatedAt = updatedAt
    }

    /// The activity's trim has been tightened since this image was made.
    public var trimIsStale: Bool {
        guard let activity else { return false }
        return activity.privacyTrimMeters > generatedWithTrimMeters
    }
}
