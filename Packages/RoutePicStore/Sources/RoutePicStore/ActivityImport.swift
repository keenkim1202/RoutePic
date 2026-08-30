import Foundation
import RouteKit
import ShapeKit
import SwiftData

extension ActivityRepository {

    public enum ImportFailure: DescribedError, Equatable {
        case noTimestamps
        case partiallyTimed
        case malformedCoordinates
        case tooShort(metres: Double)
        case alreadyImported

        /// Whether this was a decision rather than a fault. A 47 m walk to the
        /// shop was read perfectly well and refused on purpose; reporting it as
        /// unreadable sends somebody looking for a problem that is not there.
        public var isDeliberate: Bool {
            switch self {
            case .tooShort, .alreadyImported: true
            case .noTimestamps, .partiallyTimed, .malformedCoordinates: false
            }
        }

        public var description: String {
            switch self {
            case .noTimestamps:
                "This track has no timestamps, so there is no way to tell a pause from a dropout."
            case .partiallyTimed:
                "Some points in this track have no time on them, so a dropout cannot be told from a pause."
            case .malformedCoordinates:
                "This file has coordinates that are not real positions."
            case .tooShort(let metres):
                "This track is only \(Int(metres)) m long."
            case .alreadyImported:
                "This activity is already in your collection."
            }
        }
    }

    /// Shortest track worth a row. Below this the shape pipeline has nothing to
    /// work with and the collection fills up with dots.
    public static let minimumImportDistance: Double = 100

    /// Stores a track that was recorded somewhere else. The same `save` the
    /// recorder uses — only the source of the points differs.
    @discardableResult
    public func importRoute(
        _ points: [RoutePoint],
        mode: RecordingMode? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        timeZoneID: String? = nil,
        placeName: String? = nil,
        privacyTrimMeters: Int = Int(RouteTrimmer.defaultTrimMeters),
        now: Date = Date()
    ) throws -> Activity {
        let mode = mode ?? .inferred(from: points)
        // The source's own cadence, not the recorder's. See
        // `Route.dropoutThreshold` — the constant turns a sparsely sampled
        // track into nothing but gaps.
        return try store(
            Route(
                points: points,
                splittingGapsLongerThan: Route.dropoutThreshold(for: points, mode: mode)
            ),
            mode: mode,
            startedAt: startedAt,
            endedAt: endedAt,
            timeZoneID: timeZoneID,
            placeName: placeName,
            privacyTrimMeters: privacyTrimMeters,
            now: now
        )
    }

    /// The one place an imported track is checked and written, so every source
    /// gets the same refusals.
    private func store(
        _ route: Route,
        mode: RecordingMode,
        startedAt givenStart: Date? = nil,
        endedAt givenEnd: Date? = nil,
        timeZoneID: String? = nil,
        placeName: String? = nil,
        privacyTrimMeters: Int = Int(RouteTrimmer.defaultTrimMeters),
        now: Date
    ) throws -> Activity {
        guard let firstFix = route.points.first?.timestamp,
              let lastFix = route.points.last?.timestamp
        else { throw ImportFailure.noTimestamps }
        // A source that knows when the activity began is believed over its own
        // coordinates: Health starts a route after the workout and can stop it
        // early, and the difference puts a run under the wrong day.
        let startedAt = givenStart ?? firstFix
        let endedAt = givenEnd ?? lastFix
        // Checking the two ends is not enough: one untimed point in the middle
        // blinds the intervals on both sides of it, and the dropout there is
        // drawn as a straight line — the artifact this whole path exists to
        // prevent (`DESIGN.md` §5.4).
        guard route.points.allSatisfy({ $0.timestamp != nil }) else {
            throw ImportFailure.partiallyTimed
        }

        // A GPX may carry `lat="NaN"`, and `Double` parses it happily. Every
        // distance downstream then becomes non-finite, and the first `Int(_:)`
        // on one traps — a malformed file would take the app down instead of
        // being reported.
        guard route.points.allSatisfy({
            $0.latitude.isFinite && $0.longitude.isFinite
                && abs($0.latitude) <= 90 && abs($0.longitude) <= 180
        }) else { throw ImportFailure.malformedCoordinates }

        let statistics = ActivityStatistics.compute(for: route)
        guard statistics.distanceMeters >= Self.minimumImportDistance else {
            throw ImportFailure.tooShort(metres: statistics.distanceMeters)
        }
        guard try !isAlreadyStored(route, firstFix: firstFix) else {
            throw ImportFailure.alreadyImported
        }

        return try save(
            route: route,
            mode: mode,
            startedAt: startedAt,
            endedAt: endedAt,
            timeZoneID: timeZoneID,
            placeName: placeName,
            privacyTrimMeters: privacyTrimMeters,
            now: now
        )
    }

    /// Re-importing the same export is the normal case, not the exception.
    ///
    /// Start time alone is not identity. A recovered journal saved twice leaves
    /// two activities beginning in the same second — which is why the export
    /// puts the id in the file name — and matching on time alone would drop all
    /// but one of them when that backup is restored. The route decides.
    /// Anchored on the first fix, which every source agrees on, rather than on
    /// the stored start, which they do not: a GPX row starts at its first fix
    /// and a Health row at the workout, minutes earlier. Matching on the stored
    /// value re-imports a route the collection already holds.
    func isAlreadyStored(_ route: Route, firstFix: Date) throws -> Bool {
        // Two ways to be the same activity, and both are needed. Containment
        // catches a source that dated it earlier than its first fix, which
        // Health does. The second matches a stored start within a second,
        // because `GPXDocument.write` drops fractional seconds — re-importing
        // an export gives a first fix slightly *before* the stored start, and
        // containment alone would let it in as a duplicate.
        let lower = firstFix.addingTimeInterval(-1)
        let upper = firstFix.addingTimeInterval(1)
        let sameMoment = try context.fetch(
            FetchDescriptor<Activity>(
                predicate: #Predicate {
                    ($0.startedAt <= firstFix && $0.endedAt >= firstFix)
                        || ($0.startedAt > lower && $0.startedAt < upper)
                }
            )
        )
        let identity = Self.gpxIdentity(route)
        return sameMoment.contains { (try? $0.route()).map(Self.gpxIdentity) == identity }
    }

    /// What survives both a GPX round trip and the storage codec: coordinates
    /// at the codec's precision, and whole-second times.
    ///
    /// The stored blob keeps milliseconds and an accuracy stream, neither of
    /// which `GPXDocument.write` emits, and the codec quantises coordinates —
    /// so neither the storage representation nor the raw incoming points can be
    /// compared directly. Restoring a backup would duplicate every activity in
    /// it, or nothing would ever match.
    static func gpxIdentity(_ route: Route) -> Int {
        var hasher = Hasher()
        for point in route.points {
            hasher.combine((point.latitude * PolylineCodec.coordinateScale).rounded())
            hasher.combine((point.longitude * PolylineCodec.coordinateScale).rounded())
            hasher.combine(point.timestamp.map { Int($0.timeIntervalSince1970) } ?? 0)
        }
        return hasher.finalize()
    }

    /// Imports a GPX file.
    @discardableResult
    public func importGPX(at url: URL, now: Date = Date()) throws -> Activity {
        try importRoute(GPXDocument.parse(contentsOf: url), now: now)
    }

    /// Stores a track that already carries segmentation of its own.
    ///
    /// Each declared run is re-split on its own cadence, not the recorder's
    /// (`Route.splittingGapsByCadence`): a GPX sampled every two minutes is one
    /// `<trkseg>`, and the constant would make all of it gaps.
    @discardableResult
    public func importRoute(
        _ route: Route,
        mode: RecordingMode? = nil,
        now: Date = Date()
    ) throws -> Activity {
        let mode = mode ?? .inferred(from: route.points)
        return try store(route.splittingGapsByCadence(mode: mode), mode: mode, now: now)
    }
}
