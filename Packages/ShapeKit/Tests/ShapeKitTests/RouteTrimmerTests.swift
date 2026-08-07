import Foundation
import Testing
@testable import ShapeKit

@Suite("RouteTrimmer")
struct RouteTrimmerTests {

    @Test("Both ends are trimmed by roughly the requested distance")
    func trimsBothEnds() {
        let route = Fixtures.straightLine          // 1,990 m of 10 m steps
        let result = RouteTrimmer.trim(route.points, meters: 200)

        #expect(result.trimmedStartMeters >= 200)
        #expect(result.trimmedEndMeters >= 200)
        #expect(result.points.count < route.points.count)
        #expect(!result.trimWasCapped)
    }

    @Test("Trim is capped so a short route is not erased")
    func capsOnShortRoutes() {
        // 400 m route, 200 m requested from each end would remove everything.
        let points = (0..<41).map { Fixtures.point(east: Double($0) * 10, north: 0, index: $0) }
        let result = RouteTrimmer.trim(points, meters: 200)

        #expect(result.trimWasCapped)
        #expect(result.points.count >= 2)
        let removed = result.trimmedStartMeters + result.trimmedEndMeters
        #expect(removed <= 400 * RouteTrimmer.maximumTrimFraction + 20)
    }

    @Test("A loop is flagged because trimming cannot hide its start point")
    func loopIsFlagged() {
        // DESIGN.md §8.4 — start and end are the same place, so trimming both
        // ends still exposes it. The caller must suppress the map snapshot.
        let result = RouteTrimmer.trim(Fixtures.closedLoop().points, meters: 200)
        #expect(result.isLoop)
    }

    @Test("An open walk is not flagged as a loop")
    func openRouteIsNotALoop() {
        #expect(!RouteTrimmer.trim(Fixtures.wanderingWalk().points).isLoop)
    }

    @Test("Routes under 300 m are marked unshareable")
    func shortRouteIsUnshareable() {
        let points = (0..<20).map { Fixtures.point(east: Double($0) * 10, north: 0, index: $0) }
        #expect(RouteTrimmer.trim(points).isTooShortToShare)
    }

    @Test("A long route is shareable")
    func longRouteIsShareable() {
        #expect(!RouteTrimmer.trim(Fixtures.wanderingWalk().points).isTooShortToShare)
    }

    @Test("Zero trim returns the route untouched but still reports its properties")
    func zeroTrim() {
        let route = Fixtures.wanderingWalk()
        let result = RouteTrimmer.trim(route.points, meters: 0)
        #expect(result.points.count == route.points.count)
        #expect(result.trimmedStartMeters == 0)
        #expect(!result.isTooShortToShare)
    }

    @Test("Degenerate routes do not crash")
    func degenerate() {
        #expect(RouteTrimmer.trim([]).points.isEmpty)
        #expect(RouteTrimmer.trim(Fixtures.singlePoint.points).isTooShortToShare)
        #expect(RouteTrimmer.trim(Fixtures.twoPoints.points).points.count >= 1)
    }

    @Test("Length matches the sum of geodesic steps")
    func length() {
        // 200 steps of 10 m.
        let length = RouteTrimmer.length(of: Fixtures.straightLine.points)
        #expect(abs(length - 1_990) < 5)
    }
}
