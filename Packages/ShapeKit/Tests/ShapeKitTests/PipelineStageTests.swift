import Foundation
import Testing
@testable import ShapeKit

@Suite("Resample")
struct ResampleTests {

    @Test("Vertices land at even spacing along the line")
    func evenSpacing() {
        let line = [Point2D(x: 0, y: 0), Point2D(x: 100, y: 0)]
        let resampled = Resample.evenly(line, spacing: 10)
        #expect(resampled.count == 11)
        for i in 1..<resampled.count {
            #expect(abs(resampled[i].distance(to: resampled[i - 1]) - 10) < 1e-9)
        }
    }

    @Test("Endpoints are preserved even when spacing does not divide evenly")
    func endpointsPreserved() {
        let line = [Point2D(x: 0, y: 0), Point2D(x: 95, y: 0)]
        let resampled = Resample.evenly(line, spacing: 10)
        #expect(resampled.first == Point2D(x: 0, y: 0))
        #expect(resampled.last?.x == 95)
    }

    @Test("A stall does not pile up vertices")
    func stallIsThinned() {
        // 60 coincident fixes at a crossing plus a short walk. Without
        // resampling, RDP and the fingerprint over-weight where the person stood.
        var points = [Point2D(x: 0, y: 0)]
        points.append(contentsOf: (0..<60).map { _ in Point2D(x: 50, y: 0) })
        points.append(Point2D(x: 100, y: 0))

        let resampled = Resample.evenly(points, spacing: 10)
        #expect(resampled.count <= 12)
    }

    @Test("Degenerate input passes through unchanged")
    func degenerate() {
        #expect(Resample.evenly([], spacing: 10).isEmpty)
        #expect(Resample.evenly([Point2D.zero], spacing: 10).count == 1)
    }
}

@Suite("Simplify")
struct SimplifyTests {

    @Test("RDP removes collinear points")
    func removesCollinear() {
        let line = (0..<50).map { Point2D(x: Double($0), y: 0) }
        #expect(Simplify.rdp(line, epsilon: 0.001).count == 2)
    }

    @Test("RDP keeps a genuine corner")
    func keepsCorner() {
        let corner = [
            Point2D(x: 0, y: 0), Point2D(x: 5, y: 0), Point2D(x: 10, y: 0),
            Point2D(x: 10, y: 5), Point2D(x: 10, y: 10),
        ]
        let simplified = Simplify.rdp(corner, epsilon: 0.5)
        #expect(simplified.count == 3)
        #expect(simplified[1] == Point2D(x: 10, y: 0))
    }

    @Test("Adaptive simplification lands in the target vertex range")
    func adaptiveHitsTarget() throws {
        let route = Fixtures.wanderingWalk(samples: 2_000)
        let projection = try ENUProjection(centeredOn: route.points)
        let projected = projection.project(route.points)

        let simplified = Simplify.adaptive(projected, targetRange: 60...200)
        #expect(simplified.count >= 2)
        #expect(simplified.count <= 200)
    }

    @Test("Input already under the target is left alone")
    func shortInputUntouched() {
        let points = (0..<20).map { Point2D(x: Double($0), y: sin(Double($0))) }
        #expect(Simplify.adaptive(points).count == 20)
    }

    @Test("A route collapsed to a single location degrades to two points")
    func allCoincident() {
        let points = [Point2D](repeating: Point2D(x: 5, y: 5), count: 500)
        #expect(Simplify.adaptive(points).count == 2)
    }
}

@Suite("Normalize")
struct NormalizeTests {

    @Test("Shape fits the canvas with the requested padding")
    func fitsCanvas() {
        let square = [
            Point2D(x: -100, y: -100), Point2D(x: 100, y: -100),
            Point2D(x: 100, y: 100), Point2D(x: -100, y: 100),
        ]
        let canvas = Normalize.toCanvas(square, canvasSize: 1000, paddingFraction: 0.1)
        let box = BoundingBox(canvas)!

        #expect(abs(box.minX - 100) < 1e-6)
        #expect(abs(box.maxX - 900) < 1e-6)
        #expect(abs(box.width - 800) < 1e-6)
    }

    @Test("Aspect ratio is preserved")
    func preservesAspect() {
        let wide = [Point2D(x: 0, y: 0), Point2D(x: 400, y: 0), Point2D(x: 400, y: 100)]
        let canvas = Normalize.toCanvas(wide, canvasSize: 1000, paddingFraction: 0)
        let box = BoundingBox(canvas)!
        #expect(abs(box.width / box.height - 4) < 1e-6)
    }

    @Test("Y is flipped for image space")
    func flipsY() {
        // Projected space is north-up; image space is top-down. Without the flip
        // every route renders mirrored about the horizontal.
        let canvas = Normalize.toCanvas(
            [Point2D(x: 0, y: 0), Point2D(x: 0, y: 100)],
            canvasSize: 1000, paddingFraction: 0
        )
        #expect(canvas[0].y > canvas[1].y)
    }

    @Test("A single point does not divide by zero")
    func singlePoint() {
        let canvas = Normalize.toCanvas([Point2D(x: 42, y: 42)], canvasSize: 1000)
        #expect(canvas.count == 1)
        #expect(canvas[0].x.isFinite && canvas[0].y.isFinite)
    }

    @Test("Runs are normalised together, not each to its own box")
    func runsShareOneTransform() {
        let runs = [
            [Point2D(x: 0, y: 0), Point2D(x: 10, y: 0)],
            [Point2D(x: 100, y: 0), Point2D(x: 110, y: 0)],
        ]
        let canvas = Normalize.toCanvas(runs, canvasSize: 1000, paddingFraction: 0)
        #expect(canvas[0][0].x < canvas[1][0].x)
        #expect(abs(canvas[0][0].x - 0) < 1e-6)
        #expect(abs(canvas[1][1].x - 1000) < 1e-6)
    }
}

@Suite("Smoothing")
struct SmoothingTests {

    @Test("Curve passes through every input point")
    func interpolatesInputs() {
        let points = [
            Point2D(x: 0, y: 0), Point2D(x: 10, y: 20),
            Point2D(x: 30, y: 10), Point2D(x: 40, y: 30),
        ]
        let segments = Smoothing.catmullRom(points)
        #expect(segments.count == 3)
        #expect(segments[0].start == points[0])
        #expect(segments[2].end == points[3])
    }

    @Test("Endpoints are exact, not approximated")
    func endpointsExact() {
        // Start and end carry meaning: privacy trim and closure ratio both use them.
        let points = Fixtures.wanderingWalk(samples: 40).points
        let canvas = Normalize.toCanvas(
            try! ENUProjection(centeredOn: points).project(points)
        )
        let segments = Smoothing.catmullRom(canvas)
        #expect(segments.first?.start == canvas.first)
        #expect(segments.last?.end == canvas.last)
    }

    @Test("Two points produce one straight segment")
    func twoPoints() {
        let segments = Smoothing.catmullRom([Point2D(x: 0, y: 0), Point2D(x: 30, y: 0)])
        #expect(segments.count == 1)
        let mid = Smoothing.point(on: segments[0], at: 0.5)
        #expect(abs(mid.x - 15) < 1e-9 && abs(mid.y) < 1e-9)
    }

    @Test("Fewer than two points produce nothing")
    func degenerate() {
        #expect(Smoothing.catmullRom([]).isEmpty)
        #expect(Smoothing.catmullRom([Point2D.zero]).isEmpty)
    }

    @Test("Flattening returns a polyline through the curve")
    func flatten() {
        let segments = Smoothing.catmullRom([
            Point2D(x: 0, y: 0), Point2D(x: 10, y: 10), Point2D(x: 20, y: 0),
        ])
        let flat = Smoothing.flatten(segments, samplesPerSegment: 4)
        #expect(flat.count == 1 + segments.count * 4)
        #expect(flat.first == segments[0].start)
        #expect(flat.last == segments.last?.end)
    }
}
