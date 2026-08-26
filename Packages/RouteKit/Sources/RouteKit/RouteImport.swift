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

extension RecordingMode {

    /// Guesses the mode from the median speed of the moving steps — an average
    /// is dragged between modes by stops and dropouts.
    ///
    /// ponytail: a speed heuristic, so a slow cycle reads as a run. Replace it
    /// with the source's own activity type where one exists (HealthKit has one).
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
        var merged: [RoutePoint] = []
        var segments: [RouteSegment] = []

        for run in movingRuns {
            if !merged.isEmpty {
                segments.append(
                    RouteSegment(startIndex: merged.count, endIndex: merged.count, kind: .gap)
                )
            }
            let offset = merged.count
            let split = Route(points: run, splittingGapsLongerThan: threshold)
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
