import Foundation
import Testing
@testable import ShapeKit

@Suite("ShapeFingerprint")
struct ShapeFingerprintTests {

    private func fingerprint(_ route: Route, spacing: Double = 8) throws -> ShapeFingerprint {
        var configuration = ShapePipeline.Configuration(resampleSpacing: spacing)
        configuration.trimMeters = 0
        return try ShapePipeline(configuration: configuration).prepare(route).canonical.fingerprint
    }

    @Test("A closed loop reads as closed and gets polygon metrics")
    func closedLoop() throws {
        let print = try fingerprint(Fixtures.closedLoop())
        #expect(print.isClosed)
        #expect(print.closureRatio < ShapeFingerprint.closureThreshold)
        #expect(print.convexRatio != nil)
        // A circle nearly fills its own convex hull.
        #expect((print.convexRatio ?? 0) > 0.9)
    }

    @Test("An open route gets no polygon metrics at all")
    func openRouteHasNoConvexRatio() throws {
        // DESIGN.md §6.2 — v0.1 computed polygon area on open polylines, where
        // it is undefined: closing with an arbitrary chord lets that chord
        // dominate the measurement.
        let print = try fingerprint(Fixtures.wanderingWalk())
        #expect(!print.isClosed)
        #expect(print.convexRatio == nil)
    }

    @Test("A straight line is flagged degenerate")
    func straightLineIsDegenerate() throws {
        let print = try fingerprint(Fixtures.straightLine)
        #expect(abs(print.tortuosity - 1) < 0.01)
        #expect(print.isDegenerate)
    }

    @Test("A wandering route is not degenerate")
    func wanderingIsNotDegenerate() throws {
        #expect(!(try fingerprint(Fixtures.wanderingWalk()).isDegenerate))
    }

    @Test("Tortuosity of a loop is capped instead of dividing by zero")
    func loopTortuosityCapped() throws {
        let print = try fingerprint(Fixtures.closedLoop())
        #expect(print.tortuosity.isFinite)
        #expect(print.tortuosity <= ShapeFingerprint.tortuosityCeiling)
    }

    @Test("A figure-eight reports a self-intersection")
    func figureEightSelfIntersects() throws {
        let print = try fingerprint(Fixtures.figureEight())
        #expect(print.selfIntersectionCount >= 1)
    }

    @Test("A simple loop does not report self-intersections")
    func circleDoesNotSelfIntersect() throws {
        // The closing vertex touches the start, but touching is not crossing.
        #expect(try fingerprint(Fixtures.closedLoop()).selfIntersectionCount == 0)
    }

    @Test("Aspect ratio distinguishes elongated from square shapes")
    func aspectRatio() throws {
        let circle = try fingerprint(Fixtures.closedLoop())
        #expect(abs(circle.aspectRatio - 1) < 0.15)

        let line = try fingerprint(Fixtures.straightLine)
        #expect(line.aspectRatio > 10 || line.aspectRatio < 0.1)
    }

    @Test("Occupancy fill ratio is a sane fraction")
    func occupancyFillRatio() throws {
        let print = try fingerprint(Fixtures.wanderingWalk())
        #expect(print.occupancyFillRatio > 0)
        #expect(print.occupancyFillRatio < 1)
    }

    @Test("A circle has no protrusions; a figure-eight has two lobes")
    func protrusions() throws {
        // A constant radius means nothing sticks out.
        #expect(try fingerprint(Fixtures.closedLoop()).protrusionCount == 0)
        #expect(try fingerprint(Fixtures.figureEight()).protrusionCount == 2)
    }

    @Test("A five-armed star reports five protrusions")
    func starProtrusions() throws {
        let star = Fixtures.star(arms: 5)
        #expect(try fingerprint(star).protrusionCount == 5)
    }

    @Test("A self-crossing loop gets no convex ratio")
    func selfCrossingLoopHasNoConvexRatio() throws {
        // Shoelace sums signed area, so a figure-eight's lobes cancel to ~0 —
        // a number that looks like a measurement but is not one.
        #expect(try fingerprint(Fixtures.figureEight()).convexRatio == nil)
    }

    @Test("Fingerprint is Codable for transport to the VLM")
    func codable() throws {
        let original = try fingerprint(Fixtures.wanderingWalk())
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ShapeFingerprint.self, from: data) == original)
    }
}

@Suite("OccupancyGrid")
struct OccupancyGridTests {

    @Test("A rasterised line fills cells")
    func rasterize() {
        let grid = OccupancyGrid.rasterize(
            [[Point2D(x: 0, y: 512), Point2D(x: 1023, y: 512)]],
            canvasSize: 1024, gridSize: 32
        )
        #expect(grid.filledCount == 32)
        #expect(grid.fillRatio == 32.0 / 1024.0)
    }

    @Test("Crossing number identifies endpoints, lines and junctions")
    func crossingNumber() {
        var grid = OccupancyGrid(size: 7)
        for x in 1...5 { grid[x, 3] = true }
        #expect(grid.crossingNumber(1, 3) == 1)   // endpoint
        #expect(grid.crossingNumber(3, 3) == 2)   // on the line

        grid[3, 2] = true                          // add a stub upward
        #expect(grid.crossingNumber(3, 3) == 3)   // junction
    }

    @Test("A plain line has no branch points")
    func lineHasNoBranches() {
        var grid = OccupancyGrid(size: 16)
        for x in 2...13 { grid[x, 8] = true }
        #expect(grid.thinned().branchPointCount() == 0)
    }

    @Test("Out-of-bounds access is safe in both directions")
    func boundsAreSafe() {
        var grid = OccupancyGrid(size: 4)
        grid[-1, 0] = true
        grid[99, 0] = true
        #expect(grid.filledCount == 0)
        #expect(grid[-1, -1] == false)
    }
}
