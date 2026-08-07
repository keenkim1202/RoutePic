import Foundation

/// Evenly redistributes vertices along a polyline.
///
/// `DESIGN.md` §6 step 2. GPS emits fixes on a timer, not by distance, so a
/// route that stalls at a traffic light piles up hundreds of coincident points
/// there and only a handful along a fast straight. Left alone, RDP and the
/// fingerprint both over-weight wherever the person stood still.
public enum Resample {

    /// Walks the polyline and emits a vertex every `spacing` units.
    ///
    /// The first and last vertices are always preserved: they anchor the shape
    /// and the privacy trim (`RouteTrimmer`) measures from them.
    public static func evenly(_ points: [Point2D], spacing: Double) -> [Point2D] {
        guard spacing > 0 else { return points }
        guard points.count >= 2 else { return points }

        var output: [Point2D] = [points[0]]
        var carriedOver = 0.0

        for i in 1..<points.count {
            let start = points[i - 1]
            let end = points[i]
            var segmentLength = start.distance(to: end)
            guard segmentLength > 0 else { continue }

            let direction = Point2D(
                x: (end.x - start.x) / segmentLength,
                y: (end.y - start.y) / segmentLength
            )

            // Distance from the segment start to the first vertex we owe.
            var travelled = spacing - carriedOver
            while travelled <= segmentLength {
                output.append(
                    Point2D(x: start.x + direction.x * travelled, y: start.y + direction.y * travelled)
                )
                travelled += spacing
            }

            segmentLength -= (travelled - spacing)
            carriedOver = segmentLength
        }

        // The walk lands wherever the last spacing interval ended, which is
        // rarely the true endpoint. Append it unless we are already there.
        if let last = output.last, let actualLast = points.last,
           last.distance(to: actualLast) > spacing * 0.01 {
            output.append(actualLast)
        }

        return output
    }
}
