import Foundation
@testable import ShapeKit

/// Synthetic routes for the boundary cases `PLAN.md` M1 requires.
///
/// These are generated rather than recorded on purpose: finding a real GPX that
/// crosses the antimeridian, or one that is a perfect straight line, is harder
/// and less exact than constructing one. Real GPX corpora are for validating the
/// *distribution* (spike SP-1), not the edges.
enum Fixtures {

    /// Seoul City Hall — an arbitrary but realistic mid-latitude anchor.
    static let baseLatitude = 37.5665
    static let baseLongitude = 126.9780

    /// Builds a point `east`/`north` metres from a geographic origin.
    static func point(
        east: Double,
        north: Double,
        latitude: Double = baseLatitude,
        longitude: Double = baseLongitude,
        index: Int = 0
    ) -> RoutePoint {
        let metresPerDegreeLatitude = ENUProjection.earthRadius * .pi / 180
        let metresPerDegreeLongitude = metresPerDegreeLatitude * cos(latitude * .pi / 180)
        return RoutePoint(
            latitude: latitude + north / metresPerDegreeLatitude,
            longitude: longitude + east / metresPerDegreeLongitude,
            altitude: 30,
            timestamp: Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 5),
            horizontalAccuracy: 8
        )
    }

    static func route(_ points: [RoutePoint]) -> Route { Route(points: points) }

    // MARK: - Boundary cases

    static var singlePoint: Route {
        route([point(east: 0, north: 0)])
    }

    static var twoPoints: Route {
        route([point(east: 0, north: 0, index: 0), point(east: 500, north: 0, index: 1)])
    }

    /// Perfectly straight — must be flagged degenerate and blocked from generation.
    static var straightLine: Route {
        route((0..<200).map { point(east: Double($0) * 10, north: 0, index: $0) })
    }

    /// A closed circle: closure ratio ≈ 0, so polygon metrics become valid.
    static func closedLoop(radius: Double = 400, samples: Int = 240) -> Route {
        var points = (0..<samples).map { i -> RoutePoint in
            let angle = Double(i) / Double(samples) * 2 * .pi
            return point(east: cos(angle) * radius, north: sin(angle) * radius, index: i)
        }
        points.append(points[0])
        return route(points)
    }

    /// Lemniscate — guarantees exactly one true self-intersection.
    static func figureEight(scale: Double = 400, samples: Int = 240) -> Route {
        var points = (0..<samples).map { i -> RoutePoint in
            let t = Double(i) / Double(samples) * 2 * .pi
            let denominator = 1 + sin(t) * sin(t)
            return point(
                east: scale * cos(t) / denominator,
                north: scale * sin(t) * cos(t) / denominator,
                index: i
            )
        }
        points.append(points[0])
        return route(points)
    }

    /// Straddles the antimeridian. An arithmetic mean longitude would place the
    /// centroid on the opposite side of the planet.
    static var datelineCrossing: Route {
        route((0..<60).map { i in
            point(east: Double(i) * 20 - 600, north: 0, latitude: -16.5, longitude: 179.995, index: i)
        })
    }

    /// Inside the ±85° limit — must still project.
    static var highLatitude: Route {
        route((0..<60).map { i in
            point(east: Double(i) * 20, north: Double(i) * 5, latitude: 84.0, longitude: 20.0, index: i)
        })
    }

    /// Beyond the limit — must be refused rather than rendered as garbage.
    static var polar: Route {
        route((0..<20).map { i in
            point(east: Double(i) * 20, north: 0, latitude: 88.5, longitude: 20.0, index: i)
        })
    }

    /// A stall: dozens of identical fixes, as produced by standing at a crossing.
    static var duplicateCoordinates: Route {
        var points = (0..<40).map { point(east: Double($0) * 10, north: 0, index: $0) }
        points.append(contentsOf: (0..<60).map { point(east: 390, north: 0, index: 40 + $0) })
        points.append(contentsOf: (0..<40).map { point(east: 390, north: Double($0) * 10, index: 100 + $0) })
        return route(points)
    }

    /// Two moving runs separated by a gap — must never be joined by a straight line.
    static var multipleGaps: Route {
        var points: [RoutePoint] = []
        var segments: [RouteSegment] = []

        for run in 0..<3 {
            let start = points.count
            for i in 0..<40 {
                points.append(
                    point(
                        east: Double(run) * 800 + Double(i) * 10,
                        north: sin(Double(i) / 6) * 120,
                        index: points.count
                    )
                )
            }
            segments.append(RouteSegment(startIndex: start, endIndex: points.count, kind: .moving))
            if run < 2 {
                segments.append(
                    RouteSegment(startIndex: points.count, endIndex: points.count, kind: .gap)
                )
            }
        }
        return Route(points: points, segments: segments)
    }

    /// A star with `arms` points — the reference case for protrusion counting.
    static func star(arms: Int, outer: Double = 500, inner: Double = 180) -> Route {
        let samplesPerArm = 24
        var points: [RoutePoint] = []
        for i in 0..<(arms * samplesPerArm) {
            let t = Double(i) / Double(arms * samplesPerArm) * 2 * .pi
            let radius = inner + (outer - inner) * pow((cos(Double(arms) * t) + 1) / 2, 3)
            points.append(point(east: cos(t) * radius, north: sin(t) * radius, index: i))
        }
        points.append(points[0])
        return route(points)
    }

    /// A plausible wandering walk — the general-purpose fixture.
    static func wanderingWalk(samples: Int = 500) -> Route {
        var east = 0.0
        var north = 0.0
        var heading = 0.3
        var points: [RoutePoint] = []
        // Deterministic pseudo-noise: tests must not depend on a random seed.
        for i in 0..<samples {
            let t = Double(i)
            heading += sin(t / 17) * 0.18 + cos(t / 7) * 0.05
            east += cos(heading) * 12
            north += sin(heading) * 12
            points.append(point(east: east, north: north, index: i))
        }
        return route(points)
    }
}
