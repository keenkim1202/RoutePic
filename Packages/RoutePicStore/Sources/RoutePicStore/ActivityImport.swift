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
        placeName: String? = nil,
        privacyTrimMeters: Int = Int(RouteTrimmer.defaultTrimMeters),
        now: Date = Date()
    ) throws -> Activity {
        let mode = mode ?? .inferred(from: points)
        return try store(
            Route(points: points, splittingGapsLongerThan: mode.gapThreshold),
            mode: mode,
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
        placeName: String? = nil,
        privacyTrimMeters: Int = Int(RouteTrimmer.defaultTrimMeters),
        now: Date
    ) throws -> Activity {
        guard let startedAt = route.points.first?.timestamp,
              let endedAt = route.points.last?.timestamp
        else { throw ImportFailure.noTimestamps }
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
        guard try !isAlreadyStored(route, startedAt: startedAt) else {
            throw ImportFailure.alreadyImported
        }

        return try save(
            route: route,
            mode: mode,
            startedAt: startedAt,
            endedAt: endedAt,
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
    func isAlreadyStored(_ route: Route, startedAt: Date) throws -> Bool {
        let lower = startedAt.addingTimeInterval(-1)
        let upper = startedAt.addingTimeInterval(1)
        let sameMoment = try context.fetch(
            FetchDescriptor<Activity>(
                predicate: #Predicate { $0.startedAt > lower && $0.startedAt < upper }
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
    @discardableResult
    public func importRoute(
        _ route: Route,
        mode: RecordingMode? = nil,
        now: Date = Date()
    ) throws -> Activity {
        let mode = mode ?? .inferred(from: route.points)
        return try store(route.splittingGaps(longerThan: mode.gapThreshold), mode: mode, now: now)
    }
}
