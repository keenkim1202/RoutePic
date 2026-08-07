import Foundation

/// A cubic Bézier segment.
public struct BezierSegment: Sendable, Equatable {
    public var start: Point2D
    public var control1: Point2D
    public var control2: Point2D
    public var end: Point2D

    public init(start: Point2D, control1: Point2D, control2: Point2D, end: Point2D) {
        self.start = start
        self.control1 = control1
        self.control2 = control2
        self.end = end
    }
}

/// Catmull-Rom → cubic Bézier conversion.
///
/// `DESIGN.md` §5.3 and §6 step 6 — this is **render-only**. v0.1 of the design
/// put smoothing in the recording filter chain; cross-review pointed out that
/// smoothing a stored route rounds off corners and therefore changes the shape
/// the whole product is built on. The stored route stays raw so this can be
/// re-run with different parameters, or undone.
public enum Smoothing {

    /// Converts a polyline into Bézier segments passing through every input point.
    ///
    /// Endpoints are duplicated so the curve starts and ends exactly where the
    /// route does — a route's start and end are meaningful (privacy trim,
    /// closure ratio), not incidental.
    public static func catmullRom(_ points: [Point2D], tension: Double = 1.0) -> [BezierSegment] {
        guard points.count >= 2 else { return [] }
        guard points.count > 2 else {
            let a = points[0], b = points[1]
            let third = Point2D(x: (b.x - a.x) / 3, y: (b.y - a.y) / 3)
            return [BezierSegment(start: a, control1: a + third, control2: b - third, end: b)]
        }

        var segments: [BezierSegment] = []
        segments.reserveCapacity(points.count - 1)

        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]

            let scale = tension / 6.0
            let c1 = Point2D(x: p1.x + (p2.x - p0.x) * scale, y: p1.y + (p2.y - p0.y) * scale)
            let c2 = Point2D(x: p2.x - (p3.x - p1.x) * scale, y: p2.y - (p3.y - p1.y) * scale)

            segments.append(BezierSegment(start: p1, control1: c1, control2: c2, end: p2))
        }

        return segments
    }

    /// Flattens Bézier segments back to a polyline.
    ///
    /// The occupancy grid and self-intersection count in `ShapeFingerprint` need
    /// line segments, and they should measure the *smoothed* curve — that is what
    /// the model actually sees.
    public static func flatten(_ segments: [BezierSegment], samplesPerSegment: Int = 8) -> [Point2D] {
        guard !segments.isEmpty else { return [] }
        let steps = max(1, samplesPerSegment)

        var output: [Point2D] = [segments[0].start]
        for segment in segments {
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                output.append(point(on: segment, at: t))
            }
        }
        return output
    }

    public static func point(on segment: BezierSegment, at t: Double) -> Point2D {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return Point2D(
            x: a * segment.start.x + b * segment.control1.x + c * segment.control2.x + d * segment.end.x,
            y: a * segment.start.y + b * segment.control1.y + c * segment.control2.y + d * segment.end.y
        )
    }
}
