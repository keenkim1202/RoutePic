import Foundation
import ShapeKit

/// Distance, moving time, pace and climb.
///
/// `DESIGN.md` §9 spells out the definitions; v0.2 added them after
/// cross-review pointed out the design had the fields but not the arithmetic.
public struct ActivityStatistics: Sendable, Equatable {

    /// Only fixes at least this accurate vertically contribute to climb. GPS
    /// altitude is far noisier than position, and unfiltered it invents
    /// hundreds of metres of ascent on a flat run.
    public static let verticalAccuracyCeiling = 10.0

    /// Climb is only counted once it exceeds this.
    ///
    /// `DESIGN.md` §9 specified 3 m. Measured against a ±2 m oscillation — mild
    /// by GPS-altitude standards — that produced 76 m of phantom ascent over 40
    /// fixes on flat ground, because consecutive readings differ by 4 m and every
    /// upswing cleared the bar. A hysteresis only works when it exceeds the
    /// peak-to-peak noise, so it is tied to `verticalAccuracyCeiling`: never
    /// count a climb smaller than the measurement error that produced it.
    ///
    /// A barometric altimeter would justify a smaller value; GPS alone does not.
    public static let elevationHysteresis = verticalAccuracyCeiling

    public var distanceMeters: Double
    public var elapsedDuration: TimeInterval
    /// Elapsed minus pauses minus gaps.
    public var movingDuration: TimeInterval
    public var pausedDuration: TimeInterval
    /// Time inside dropouts — reported separately so the UI can say how much of
    /// the route is missing rather than hiding it in the moving time.
    public var gapDuration: TimeInterval
    public var elevationGainMeters: Double

    public init(
        distanceMeters: Double,
        elapsedDuration: TimeInterval,
        movingDuration: TimeInterval,
        pausedDuration: TimeInterval,
        gapDuration: TimeInterval,
        elevationGainMeters: Double
    ) {
        self.distanceMeters = distanceMeters
        self.elapsedDuration = elapsedDuration
        self.movingDuration = movingDuration
        self.pausedDuration = pausedDuration
        self.gapDuration = gapDuration
        self.elevationGainMeters = elevationGainMeters
    }

    /// Metres per second over moving time. Zero when nothing moved.
    public var averageSpeed: Double {
        movingDuration > 0 ? distanceMeters / movingDuration : 0
    }

    /// Seconds per kilometre, or `nil` when too slow to be meaningful.
    public var paceSecondsPerKilometre: Double? {
        guard distanceMeters > 0, movingDuration > 0 else { return nil }
        return movingDuration / (distanceMeters / 1000)
    }

    public static let zero = ActivityStatistics(
        distanceMeters: 0, elapsedDuration: 0, movingDuration: 0,
        pausedDuration: 0, gapDuration: 0, elevationGainMeters: 0
    )
}

extension ActivityStatistics {

    /// Computes statistics from a segmented route.
    ///
    /// Distance and climb accumulate **within** moving runs only: measuring
    /// across a gap would credit the user with ground they may not have covered.
    public static func compute(for route: Route) -> ActivityStatistics {
        var distance = 0.0
        var movingDuration = 0.0
        var elevationGain = 0.0

        for run in route.movingRuns {
            for i in 1..<run.count {
                distance += ENUProjection.haversineDistance(run[i - 1], run[i])
            }
            if let first = run.first?.timestamp, let last = run.last?.timestamp {
                movingDuration += max(0, last.timeIntervalSince(first))
            }
            elevationGain += climb(in: run)
        }

        let timestamps = route.points.compactMap(\.timestamp)
        let elapsed: TimeInterval
        if let first = timestamps.min(), let last = timestamps.max() {
            elapsed = max(0, last.timeIntervalSince(first))
        } else {
            elapsed = 0
        }

        let (paused, gap) = nonMovingDurations(in: route)

        return ActivityStatistics(
            distanceMeters: distance,
            elapsedDuration: elapsed,
            movingDuration: movingDuration,
            pausedDuration: paused,
            gapDuration: gap,
            elevationGainMeters: elevationGain
        )
    }

    private static func climb(in run: [RoutePoint]) -> Double {
        var total = 0.0
        var reference: Double?

        for point in run {
            guard
                let altitude = point.altitude,
                let accuracy = point.verticalAccuracy,
                accuracy >= 0, accuracy <= verticalAccuracyCeiling
            else { continue }

            guard let previous = reference else {
                reference = altitude
                continue
            }
            let delta = altitude - previous
            if delta >= elevationHysteresis {
                total += delta
                reference = altitude
            } else if delta <= -elevationHysteresis {
                // Descending resets the reference so the next climb is measured
                // from the bottom, not from the last peak.
                reference = altitude
            }
        }
        return total
    }

    /// Time attributable to pauses and to dropouts.
    ///
    /// A boundary segment is zero-length, so its duration is the silence between
    /// the run that ended and the run that resumed.
    private static func nonMovingDurations(in route: Route) -> (paused: TimeInterval, gap: TimeInterval) {
        var paused = 0.0
        var gap = 0.0

        for (index, segment) in route.segments.enumerated() where segment.kind != .moving {
            let before = route.segments[..<index].last { $0.kind == .moving }
            let after = route.segments[(index + 1)...].first { $0.kind == .moving }

            guard
                let endIndex = before.map({ $0.endIndex - 1 }),
                let startIndex = after?.startIndex,
                route.points.indices.contains(endIndex),
                route.points.indices.contains(startIndex),
                let endTime = route.points[endIndex].timestamp,
                let startTime = route.points[startIndex].timestamp
            else { continue }

            let interval = max(0, startTime.timeIntervalSince(endTime))
            if segment.kind == .paused { paused += interval } else { gap += interval }
        }
        return (paused, gap)
    }
}
