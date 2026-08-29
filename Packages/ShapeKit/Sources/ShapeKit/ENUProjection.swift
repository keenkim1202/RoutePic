import Foundation

/// Projects WGS84 coordinates onto a local tangent plane centred on the route.
///
/// `DESIGN.md` §6.1 — v0.1 of the design specified Web Mercator and justified it
/// as "removing latitude distortion", which is backwards: Web Mercator *scales*
/// with latitude. A local ENU (East-North-Up) plane centred on the route's own
/// centroid keeps shape essentially undistorted over the few-kilometre spans a
/// recorded activity covers, at any latitude.
public struct ENUProjection: Sendable {

    /// Mean Earth radius, metres.
    public static let earthRadius = 6_371_000.0

    /// Beyond this the cosine term collapses and east–west distances stop being
    /// meaningful. No real activity happens here; refusing beats rendering garbage.
    public static let maxAbsoluteLatitude = 85.0

    public enum Failure: DescribedError, Equatable {
        case noPoints
        case polarLatitude(Double)

        public var description: String {
            switch self {
            case .noPoints:
                return "Cannot build a projection from an empty route."
            case .polarLatitude(let lat):
                return "Route centroid latitude \(lat)° exceeds ±\(ENUProjection.maxAbsoluteLatitude)°; "
                    + "the local tangent plane is not usable at the poles."
            }
        }
    }

    public let originLatitude: Double
    public let originLongitude: Double

    private let cosOriginLatitude: Double

    public init(originLatitude: Double, originLongitude: Double) throws {
        guard abs(originLatitude) <= Self.maxAbsoluteLatitude else {
            throw Failure.polarLatitude(originLatitude)
        }
        self.originLatitude = originLatitude
        self.originLongitude = originLongitude
        self.cosOriginLatitude = cos(originLatitude * .pi / 180)
    }

    /// Builds a projection centred on the route's centroid.
    ///
    /// Longitude uses a circular mean. A plain arithmetic mean puts a route
    /// straddling the antimeridian (say 179° and −179°) at longitude 0 — the
    /// opposite side of the planet.
    public init(centeredOn points: [RoutePoint]) throws {
        guard !points.isEmpty else { throw Failure.noPoints }

        let meanLatitude = points.reduce(0.0) { $0 + $1.latitude } / Double(points.count)

        var sumSin = 0.0
        var sumCos = 0.0
        for point in points {
            let radians = point.longitude * .pi / 180
            sumSin += sin(radians)
            sumCos += cos(radians)
        }
        let meanLongitude = atan2(sumSin / Double(points.count), sumCos / Double(points.count))
            * 180 / .pi

        try self.init(originLatitude: meanLatitude, originLongitude: meanLongitude)
    }

    public func project(_ point: RoutePoint) -> Point2D {
        let deltaLongitude = Self.normalizedLongitudeDelta(point.longitude - originLongitude)
        let x = Self.earthRadius * (deltaLongitude * .pi / 180) * cosOriginLatitude
        let y = Self.earthRadius * ((point.latitude - originLatitude) * .pi / 180)
        return Point2D(x: x, y: y)
    }

    public func project(_ points: [RoutePoint]) -> [Point2D] {
        points.map(project)
    }

    /// Wraps a longitude difference into (−180, 180].
    ///
    /// Without this, a route crossing the antimeridian produces a ~40,000 km
    /// jump instead of a few metres.
    public static func normalizedLongitudeDelta(_ delta: Double) -> Double {
        var d = delta.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Great-circle distance in metres between two fixes.
    ///
    /// Used for statistics (`DESIGN.md` §9) where the projection's small planar
    /// error would otherwise accumulate over thousands of points.
    public static func haversineDistance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLat = (b.latitude - a.latitude) * .pi / 180
        let deltaLon = normalizedLongitudeDelta(b.longitude - a.longitude) * .pi / 180

        let h = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }
}
