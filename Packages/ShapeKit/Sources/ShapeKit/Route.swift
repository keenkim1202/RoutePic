import Foundation

/// A single recorded location fix in WGS84.
///
/// This is the raw, unmodified form — see `DESIGN.md` §5.3: the stored route is
/// never smoothed. Smoothing happens only in the render pipeline.
public struct RoutePoint: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var timestamp: Date?
    public var horizontalAccuracy: Double?
    public var verticalAccuracy: Double?

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        timestamp: Date? = nil,
        horizontalAccuracy: Double? = nil,
        verticalAccuracy: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
    }
}

/// What happened during a stretch of the route.
///
/// `.gap` matters for rendering: gaps are never joined with a straight line
/// (`DESIGN.md` §5.4 — "말없이 이어붙여 없는 경로를 그리지 않는다").
public enum SegmentKind: String, Sendable, Codable, CaseIterable {
    case moving
    case paused
    case gap
}

/// A half-open index range `[startIndex, endIndex)` into a route's points.
public struct RouteSegment: Sendable, Equatable, Codable {
    public var startIndex: Int
    public var endIndex: Int
    public var kind: SegmentKind

    public init(startIndex: Int, endIndex: Int, kind: SegmentKind) {
        self.startIndex = startIndex
        self.endIndex = endIndex
        self.kind = kind
    }

    public var count: Int { max(0, endIndex - startIndex) }
}

/// A recorded route: points plus the segmentation that says which stretches are
/// real movement and which are pauses or dropouts.
public struct Route: Sendable, Equatable {
    public var points: [RoutePoint]
    public var segments: [RouteSegment]

    public init(points: [RoutePoint], segments: [RouteSegment]? = nil) {
        self.points = points
        self.segments = segments ?? [
            RouteSegment(startIndex: 0, endIndex: points.count, kind: .moving)
        ]
    }

    /// Only the stretches that represent actual movement, as point arrays.
    ///
    /// Everything downstream (projection, rendering, fingerprinting) works on
    /// these — never on the flat point list — so pauses and gaps stay separate.
    public var movingRuns: [[RoutePoint]] {
        segments
            .filter { $0.kind == .moving && $0.count >= 2 }
            .map { Array(points[$0.startIndex..<$0.endIndex]) }
    }

    /// Keeps only `range`, remapping the segmentation to match.
    ///
    /// Slicing by rebuilding `Route(points:)` would silently collapse every
    /// segment into one `.moving` run — which is exactly how a gap ends up
    /// joined by a straight line the person never walked (`DESIGN.md` §5.4).
    /// The privacy trim (`RouteTrimmer`) is the caller that made that mistake.
    public func slice(_ range: Range<Int>) -> Route {
        let clamped = range.clamped(to: 0..<points.count)
        guard !clamped.isEmpty else { return Route(points: [], segments: []) }

        let remapped: [RouteSegment] = segments.compactMap { segment in
            let start = max(segment.startIndex, clamped.lowerBound)
            let end = min(segment.endIndex, clamped.upperBound)
            guard start < end || segment.count == 0 else { return nil }
            guard start >= clamped.lowerBound, end <= clamped.upperBound, start <= end else {
                return nil
            }
            // Zero-length markers (a gap boundary) survive only if they sit
            // inside the retained window.
            if segment.count == 0 {
                guard clamped.contains(segment.startIndex) else { return nil }
            }
            return RouteSegment(
                startIndex: start - clamped.lowerBound,
                endIndex: end - clamped.lowerBound,
                kind: segment.kind
            )
        }

        return Route(points: Array(points[clamped]), segments: remapped)
    }
}
