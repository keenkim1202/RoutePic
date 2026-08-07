import Foundation

/// A point on a flat plane, in metres (after ENU projection) or in canvas units
/// (after normalisation). Which one it is depends on the stage — see `ENUProjection`.
public struct Point2D: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(x: 0, y: 0)

    public static func + (a: Point2D, b: Point2D) -> Point2D {
        Point2D(x: a.x + b.x, y: a.y + b.y)
    }

    public static func - (a: Point2D, b: Point2D) -> Point2D {
        Point2D(x: a.x - b.x, y: a.y - b.y)
    }

    public static func * (p: Point2D, s: Double) -> Point2D {
        Point2D(x: p.x * s, y: p.y * s)
    }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Point2D) -> Double { (self - other).length }
}

public struct BoundingBox: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Point2D {
        Point2D(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
    }

    /// `nil` for an empty input — callers must decide what an empty shape means
    /// rather than getting a silently degenerate box.
    public init?(_ points: some Sequence<Point2D>) {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var any = false
        for p in points {
            any = true
            minX = Swift.min(minX, p.x)
            minY = Swift.min(minY, p.y)
            maxX = Swift.max(maxX, p.x)
            maxY = Swift.max(maxY, p.y)
        }
        guard any else { return nil }
        self.init(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
}

public enum Geometry {

    /// Total length of an open polyline.
    public static func polylineLength(_ points: [Point2D]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += points[i].distance(to: points[i - 1])
        }
        return total
    }

    /// Perpendicular distance from `p` to the segment `a`–`b`.
    ///
    /// Degenerate segments (`a == b`) fall back to point distance, which is what
    /// RDP needs when a route stalls and emits duplicate coordinates.
    public static func perpendicularDistance(_ p: Point2D, a: Point2D, b: Point2D) -> Double {
        let ab = b - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return p.distance(to: a) }
        let t = ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared
        let clamped = Swift.min(Swift.max(t, 0), 1)
        let projection = Point2D(x: a.x + ab.x * clamped, y: a.y + ab.y * clamped)
        return p.distance(to: projection)
    }

    /// Signed area × 2 of the polygon formed by closing the polyline.
    /// Only meaningful for near-closed shapes — see `ShapeFingerprint.convexRatio`.
    public static func shoelaceArea(_ points: [Point2D]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Andrew's monotone chain. Returns the hull in counter-clockwise order.
    public static func convexHull(_ points: [Point2D]) -> [Point2D] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }

        func cross(_ o: Point2D, _ a: Point2D, _ b: Point2D) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [Point2D] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }

        var upper: [Point2D] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }

        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Two positions closer than this are the same vertex. Canvas units, so
    /// 0.001 of a pixel on a 1024² canvas — far below any real near-miss.
    public static let touchTolerance = 1e-3

    /// Whether the open segments `p1`–`p2` and `p3`–`p4` cross.
    ///
    /// Shared endpoints do not count. Consecutive segments of a polyline always
    /// touch, and a closed loop's first and last segments share a vertex too —
    /// counting either would make every route look self-intersecting.
    public static func segmentsIntersect(
        _ p1: Point2D, _ p2: Point2D, _ p3: Point2D, _ p4: Point2D
    ) -> Bool {
        for a in [p1, p2] {
            for b in [p3, p4] where a.distance(to: b) <= touchTolerance {
                return false
            }
        }

        func orientation(_ a: Point2D, _ b: Point2D, _ c: Point2D) -> Int {
            let v = (b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y)
            if abs(v) < 1e-12 { return 0 }
            return v > 0 ? 1 : 2
        }

        let o1 = orientation(p1, p2, p3)
        let o2 = orientation(p1, p2, p4)
        let o3 = orientation(p3, p4, p1)
        let o4 = orientation(p3, p4, p2)
        return o1 != o2 && o3 != o4
    }

    /// Turning angle at each interior vertex, in radians, signed.
    /// Positive is a left turn. Length is `points.count - 2`.
    public static func turningAngles(_ points: [Point2D]) -> [Double] {
        guard points.count >= 3 else { return [] }
        var angles: [Double] = []
        angles.reserveCapacity(points.count - 2)
        for i in 1..<(points.count - 1) {
            let a = points[i] - points[i - 1]
            let b = points[i + 1] - points[i]
            guard a.length > 0, b.length > 0 else {
                angles.append(0)
                continue
            }
            let cross = a.x * b.y - a.y * b.x
            let dot = a.x * b.x + a.y * b.y
            angles.append(atan2(cross, dot))
        }
        return angles
    }
}
