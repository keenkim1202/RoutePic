import Foundation
import ShapeKit

extension Route {

    /// Rebuilds the segmentation from timestamps, for sources that carry none.
    /// Without it a twenty-minute tunnel becomes a straight line the person
    /// never walked (`DESIGN.md` §5.4).
    ///
    /// Every point must be timestamped. An untimed one blinds both intervals
    /// touching it, which hides exactly the hole this is looking for — the
    /// import path refuses such a track rather than segmenting it wrong.
    public init(points: [RoutePoint], splittingGapsLongerThan threshold: TimeInterval) {
        var segments: [RouteSegment] = []
        var runStart = 0

        for index in 1..<max(points.count, 1) {
            guard let previous = points[index - 1].timestamp,
                  let current = points[index].timestamp,
                  current.timeIntervalSince(previous) > threshold
            else { continue }

            segments.append(RouteSegment(startIndex: runStart, endIndex: index, kind: .moving))
            segments.append(RouteSegment(startIndex: index, endIndex: index, kind: .gap))
            runStart = index
        }

        if runStart < points.count {
            segments.append(
                RouteSegment(startIndex: runStart, endIndex: points.count, kind: .moving)
            )
        }

        self.init(points: points, segments: segments)
    }
}

extension Route {

    /// What counts as a dropout in a track this app did not record.
    ///
    /// The recorder samples every 5–25 m, so `RecordingMode.gapThreshold` is a
    /// silence long enough to be a hole. An imported track chose its own
    /// cadence: a source writing a fix every two minutes is not dropping out
    /// every two minutes. Measured against the recorder's constant, a five
    /// kilometre walk sampled that way came back as **zero moving runs and 0 m**
    /// — every interval was a gap, and distance only accumulates inside a run.
    ///
    /// So the bar is this track's own rhythm: an interval far outside its median
    /// is a hole, and the recorder's threshold is the floor for dense tracks.
    ///
    /// A short track cannot describe its own rhythm, so it does not get to:
    /// with two points the single interval *is* the middle of the list, and a
    /// track whose only interval is a two-hour hole would rule that hole
    /// ordinary. Below `minimumIntervals` the mode decides.
    ///
    /// The middle of the list, not a lower point in it. A lower point follows
    /// whichever cadence is *fastest*: a source that logs a dense burst and then
    /// settles into two-minute steps would have its burst set the bar, and every
    /// ordinary step after it read as a hole — the original bug, for a
    /// variable-cadence track. The middle follows the majority instead, and the
    /// minimum above is what stops a few holes from being that majority.
    ///
    /// ponytail: eight medians, and eight intervals to earn them, are judgements
    /// rather than measurements. Lower and ordinary jitter fragments a route;
    /// higher and a real dropout is drawn through.
    public static func dropoutThreshold(
        for points: [RoutePoint], mode: RecordingMode
    ) -> TimeInterval {
        let intervals = zip(points, points.dropFirst()).compactMap { previous, current -> TimeInterval? in
            guard let start = previous.timestamp, let end = current.timestamp else { return nil }
            let elapsed = end.timeIntervalSince(start)
            return elapsed > 0 ? elapsed : nil
        }.sorted()
        guard intervals.count >= minimumIntervals else { return mode.gapThreshold }

        let typical = intervals[intervals.count / 2]
        return max(mode.gapThreshold, typical * 8)
    }

    /// Enough intervals that a handful of holes cannot become the typical one.
    static let minimumIntervals = 8
}

extension RecordingMode {

    /// Guesses the mode from the median speed of the moving steps — an average
    /// is dragged between modes by stops and dropouts.
    ///
    /// A guess, so a slow cycle reads as a run. Only for sources that say
    /// nothing about what they are; Health says, and
    /// `init(workoutActivityType:)` is used there instead.
    public static func inferred(from points: [RoutePoint]) -> RecordingMode {
        guard points.count > 1 else { return .walk }

        var speeds: [Double] = []
        for (previous, current) in zip(points, points.dropFirst()) {
            guard let start = previous.timestamp, let end = current.timestamp else { continue }
            let elapsed = end.timeIntervalSince(start)
            // A gap says nothing about speed and drags the sample toward zero.
            guard elapsed > 0, elapsed <= 60 else { continue }

            let speed = ENUProjection.haversineDistance(previous, current) / elapsed
            // A track that waits at lights for half its samples would
            // otherwise have a median of zero.
            guard speed > 0.5 else { continue }
            speeds.append(speed)
        }

        guard !speeds.isEmpty else { return .walk }
        speeds.sort()
        let median = speeds[speeds.count / 2]

        return switch median {
        case ..<2.2: .walk       // under ~8 km/h
        case ..<5.5: .run        // under ~20 km/h
        default: .drive
        }
    }
}

extension Route {

    /// Splits each moving run on clock holes, keeping the breaks the source
    /// already declared.
    ///
    /// Not every GPX writer marks a pause both ways, and honouring only one of
    /// the two bridges the breaks marked the other way. Paused stretches are
    /// dropped — no importable format has them.
    public func splittingGaps(longerThan threshold: TimeInterval) -> Route {
        splittingRuns { _ in threshold }
    }

    /// Each declared run judged by its own cadence.
    ///
    /// One median over the whole track lets a sparse run raise the bar for a
    /// dense one: nine two-minute intervals set it to 960 s, and a five-minute
    /// hole in a later dense run is then drawn as movement.
    public func splittingGapsByCadence(mode: RecordingMode) -> Route {
        splittingRuns { Route.dropoutThreshold(for: $0, mode: mode) }
    }

    private func splittingRuns(_ threshold: ([RoutePoint]) -> TimeInterval) -> Route {
        var merged: [RoutePoint] = []
        var segments: [RouteSegment] = []

        for run in movingRuns {
            if !merged.isEmpty {
                segments.append(
                    RouteSegment(startIndex: merged.count, endIndex: merged.count, kind: .gap)
                )
            }
            let offset = merged.count
            let split = Route(points: run, splittingGapsLongerThan: threshold(run))
            merged += split.points
            segments += split.segments.map {
                RouteSegment(
                    startIndex: $0.startIndex + offset,
                    endIndex: $0.endIndex + offset,
                    kind: $0.kind
                )
            }
        }

        return Route(points: merged, segments: segments)
    }
}

#if canImport(HealthKit)
import HealthKit

extension RecordingMode {

    /// The mode Health already recorded, rather than one guessed from speed.
    /// `nil` for anything with no shape to draw — a swim or a treadmill run is
    /// a real workout that would become a row rendering nothing.
    public init?(workoutActivityType type: HKWorkoutActivityType) {
        switch type {
        case .walking, .hiking:
            self = .walk
        case .running:
            self = .run
        // Cycling sits closer to driving than to running on every axis this
        // app uses — sampling distance, speed ceiling, and no auto-pause at
        // junctions. `PLAN.md` has no cycling mode of its own.
        case .cycling:
            self = .drive
        default:
            return nil
        }
    }
}
#endif
