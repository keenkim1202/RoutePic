import Foundation
import Testing
@testable import ShapeKit

@Suite("Geometry")
struct GeometryTests {

    @Test("Polyline length sums segment distances")
    func polylineLength() {
        let points = [Point2D(x: 0, y: 0), Point2D(x: 3, y: 4), Point2D(x: 3, y: 14)]
        #expect(Geometry.polylineLength(points) == 15)
    }

    @Test("Perpendicular distance clamps to the segment, not its infinite line")
    func perpendicularDistanceClamps() {
        let a = Point2D(x: 0, y: 0)
        let b = Point2D(x: 10, y: 0)
        // Beyond b: the nearest point is b itself, not the foot of the perpendicular.
        #expect(Geometry.perpendicularDistance(Point2D(x: 20, y: 0), a: a, b: b) == 10)
        #expect(Geometry.perpendicularDistance(Point2D(x: 5, y: 3), a: a, b: b) == 3)
    }

    @Test("Degenerate segments fall back to point distance")
    func perpendicularDistanceDegenerate() {
        let a = Point2D(x: 4, y: 4)
        #expect(Geometry.perpendicularDistance(Point2D(x: 4, y: 9), a: a, b: a) == 5)
    }

    @Test("Convex hull of a square with an interior point is the square")
    func convexHull() {
        let hull = Geometry.convexHull([
            Point2D(x: 0, y: 0), Point2D(x: 10, y: 0),
            Point2D(x: 10, y: 10), Point2D(x: 0, y: 10),
            Point2D(x: 5, y: 5),
        ])
        #expect(hull.count == 4)
        #expect(!hull.contains(Point2D(x: 5, y: 5)))
    }

    @Test("Shoelace area of a unit square is 1")
    func shoelaceArea() {
        let square = [
            Point2D(x: 0, y: 0), Point2D(x: 1, y: 0),
            Point2D(x: 1, y: 1), Point2D(x: 0, y: 1),
        ]
        #expect(abs(Geometry.shoelaceArea(square) - 1) < 1e-12)
    }

    @Test("Crossing segments intersect, parallel ones do not")
    func segmentsIntersect() {
        #expect(Geometry.segmentsIntersect(
            Point2D(x: 0, y: 0), Point2D(x: 10, y: 10),
            Point2D(x: 0, y: 10), Point2D(x: 10, y: 0)
        ))
        #expect(!Geometry.segmentsIntersect(
            Point2D(x: 0, y: 0), Point2D(x: 10, y: 0),
            Point2D(x: 0, y: 5), Point2D(x: 10, y: 5)
        ))
    }

    @Test("Segments sharing an endpoint are not counted as intersecting")
    func sharedEndpointIsNotAnIntersection() {
        // Consecutive polyline segments always touch. Counting that would make
        // every route maximally self-intersecting.
        #expect(!Geometry.segmentsIntersect(
            Point2D(x: 0, y: 0), Point2D(x: 10, y: 0),
            Point2D(x: 10, y: 0), Point2D(x: 10, y: 10)
        ))
    }

    @Test("Turning angles are signed and sized correctly")
    func turningAngles() {
        let leftTurn = [Point2D(x: 0, y: 0), Point2D(x: 10, y: 0), Point2D(x: 10, y: 10)]
        let angles = Geometry.turningAngles(leftTurn)
        #expect(angles.count == 1)
        #expect(abs(angles[0] - .pi / 2) < 1e-9)

        let rightTurn = [Point2D(x: 0, y: 0), Point2D(x: 10, y: 0), Point2D(x: 10, y: -10)]
        #expect(Geometry.turningAngles(rightTurn)[0] < 0)
    }

    @Test("Bounding box of no points is nil, not a degenerate box")
    func emptyBoundingBox() {
        #expect(BoundingBox([]) == nil)
    }
}
