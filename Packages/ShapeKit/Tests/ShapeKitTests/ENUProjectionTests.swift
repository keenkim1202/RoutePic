import Foundation
import Testing
@testable import ShapeKit

@Suite("ENU projection")
struct ENUProjectionTests {

    @Test("Projected distance matches the geodesic within 0.1% over a few km")
    func projectionAccuracy() throws {
        let route = Fixtures.wanderingWalk(samples: 200)
        let projection = try ENUProjection(centeredOn: route.points)

        let a = route.points[0]
        let b = route.points[150]
        let geodesic = ENUProjection.haversineDistance(a, b)
        let planar = projection.project(a).distance(to: projection.project(b))

        #expect(abs(planar - geodesic) / geodesic < 0.001)
    }

    @Test("Longitude delta wraps across the antimeridian")
    func longitudeWrapping() {
        // 179.9 → -179.9 is 0.2°, not 359.8°.
        #expect(abs(ENUProjection.normalizedLongitudeDelta(-359.8) - 0.2) < 1e-9)
        #expect(abs(ENUProjection.normalizedLongitudeDelta(359.8) + 0.2) < 1e-9)
        #expect(ENUProjection.normalizedLongitudeDelta(180) == 180)
    }

    @Test("A route straddling the antimeridian does not explode")
    func datelineRoute() throws {
        let route = Fixtures.datelineCrossing
        let projection = try ENUProjection(centeredOn: route.points)
        let projected = projection.project(route.points)

        // The fixture spans ~1.2 km. An arithmetic-mean centroid would put the
        // origin half a world away and produce millions of metres.
        let box = try #require(BoundingBox(projected))
        #expect(box.width < 2_000)
        #expect(box.height < 2_000)
    }

    @Test("Centroid uses a circular mean for longitude")
    func circularMeanLongitude() throws {
        let points = [
            RoutePoint(latitude: 0, longitude: 179.0),
            RoutePoint(latitude: 0, longitude: -179.0),
        ]
        let projection = try ENUProjection(centeredOn: points)
        // The true midpoint is ±180, not 0.
        #expect(abs(abs(projection.originLongitude) - 180) < 1e-6)
    }

    @Test("High latitude inside the limit still projects")
    func highLatitudeProjects() throws {
        let projection = try ENUProjection(centeredOn: Fixtures.highLatitude.points)
        #expect(projection.originLatitude > 83)
    }

    @Test("Polar latitude is refused rather than rendered as garbage")
    func polarLatitudeThrows() {
        #expect(throws: ENUProjection.Failure.self) {
            try ENUProjection(centeredOn: Fixtures.polar.points)
        }
    }

    @Test("Empty input is refused")
    func emptyThrows() {
        #expect(throws: ENUProjection.Failure.noPoints) {
            try ENUProjection(centeredOn: [])
        }
    }

    @Test("Haversine matches a known distance")
    func haversineKnownDistance() {
        // Seoul City Hall → Gyeongbokgung, roughly 2.4 km.
        let a = RoutePoint(latitude: 37.5665, longitude: 126.9780)
        let b = RoutePoint(latitude: 37.5796, longitude: 126.9770)
        let distance = ENUProjection.haversineDistance(a, b)
        #expect(distance > 1_400 && distance < 1_500)
    }
}
