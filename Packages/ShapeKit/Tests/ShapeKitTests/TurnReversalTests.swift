import Foundation
import Testing
@testable import ShapeKit

/// Measured on real geometry, not reasoned about.
///
/// Three metrics were written against these turns before one of them measured
/// what its rule claimed: a signed variance that grew with the teeth, a
/// left/right balance an S-curve also has, and a per-sample ratio that only
/// ever reported the sampling rate.
@Suite("Turn reversals")
struct TurnReversalTests {

    private func fingerprint(_ points: [RoutePoint]) throws -> ShapeFingerprint {
        var configuration = ShapePipeline.Configuration.walking
        configuration.trimMeters = 0
        return try ShapePipeline(configuration: configuration)
            .prepare(Fixtures.route(points)).canonical.fingerprint
    }

    @Test("A zigzag reverses many times and a smooth arc never does")
    func zigzagAndArc() throws {
        // Ten teeth, 60 m of run and 40 m of rise each.
        var teeth: [RoutePoint] = []
        for i in 0..<21 {
            teeth.append(Fixtures.point(
                east: Double(i) * 60, north: i.isMultiple(of: 2) ? 0 : 40, index: i
            ))
        }
        let saw = try fingerprint(teeth)

        // A half circle: every turn the same way.
        var arc: [RoutePoint] = []
        for i in 0..<60 {
            let angle = Double(i) / 59 * .pi
            arc.append(Fixtures.point(
                east: cos(angle) * 500, north: sin(angle) * 500, index: i
            ))
        }
        let bend = try fingerprint(arc)

        #expect(saw.turnReversals >= 6, "saw had \(saw.turnReversals)")
        #expect(bend.turnReversals < 6, "arc had \(bend.turnReversals)")
        // And the axis the first attempt used says the opposite of the truth:
        // the saw's signed variance is the larger of the two.
        #expect(saw.turnVariance > bend.turnVariance)
    }
}

/// The shape that is measured has to be the shape that is drawn.
@Suite("Closed-shape measures")
struct ClosedShapeMeasureTests {

    private func ring(gapAfter: Int?) -> Route {
        var points: [RoutePoint] = []
        for i in 0..<120 {
            let angle = Double(i) / 120 * 2 * .pi
            points.append(Fixtures.point(
                east: cos(angle) * 400, north: sin(angle) * 400, index: i
            ))
        }
        guard let gapAfter else { return Route(points: points) }
        return Route(points: points, segments: [
            RouteSegment(startIndex: 0, endIndex: gapAfter, kind: .moving),
            RouteSegment(startIndex: gapAfter, endIndex: gapAfter, kind: .gap),
            RouteSegment(startIndex: gapAfter, endIndex: points.count, kind: .moving),
        ])
    }

    private func fingerprint(_ route: Route) throws -> ShapeFingerprint {
        var configuration = ShapePipeline.Configuration.walking
        configuration.trimMeters = 0
        return try ShapePipeline(configuration: configuration)
            .prepare(route).canonical.fingerprint
    }

    /// Flattened, a dropout adds an edge from the end of one run to the start
    /// of the next, and the area and perimeter then describe a polygon the
    /// renderer deliberately leaves open.
    @Test("A ring with a dropout has no roundness to report")
    func brokenRingReportsNothing() throws {
        let whole = try fingerprint(ring(gapAfter: nil))
        #expect(whole.circularity != nil)
        #expect(whole.convexRatio != nil)

        let broken = try fingerprint(ring(gapAfter: 60))
        #expect(broken.circularity == nil)
        #expect(broken.convexRatio == nil)
    }
}
