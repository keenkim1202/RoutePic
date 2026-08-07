import Foundation
import Testing
@testable import ShapeKit

@Suite("ShapePipeline")
struct ShapePipelineTests {

    private let pipeline = ShapePipeline(
        configuration: ShapePipeline.Configuration(trimMeters: 0)
    )

    @Test("A normal route produces a canvas-space shape inside the canvas")
    func normalRoute() throws {
        let prepared = try pipeline.prepare(Fixtures.wanderingWalk())
        let shape = prepared.canonical

        let all = shape.runs.flatMap { $0 }
        let box = try #require(BoundingBox(all))
        #expect(box.minX >= 0 && box.maxX <= shape.canvasSize)
        #expect(box.minY >= 0 && box.maxY <= shape.canvasSize)
        #expect(prepared.vertexCount <= 200)
    }

    @Test("Gaps stay as separate runs and are never joined")
    func gapsStaySeparate() throws {
        // DESIGN.md §5.4 — joining them would draw a route the person never took.
        let prepared = try pipeline.prepare(Fixtures.multipleGaps)
        #expect(prepared.projectedRuns.count == 3)
        #expect(prepared.canonical.curves.count == 3)
    }

    @Test("A single point is refused rather than rendered as a dot")
    func singlePointRefused() {
        #expect(throws: ShapePipeline.Failure.notEnoughPoints) {
            try pipeline.prepare(Fixtures.singlePoint)
        }
    }

    @Test("Two points are enough to produce a shape")
    func twoPoints() throws {
        let prepared = try pipeline.prepare(Fixtures.twoPoints)
        #expect(prepared.canonical.curves.first?.isEmpty == false)
    }

    @Test("Coincident points collapse without crashing")
    func duplicateCoordinates() throws {
        let prepared = try pipeline.prepare(Fixtures.duplicateCoordinates)
        #expect(prepared.vertexCount >= 2)
        #expect(prepared.canonical.runs.flatMap { $0 }.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test("A polar route surfaces the projection failure instead of drawing garbage")
    func polarRouteFails() {
        #expect(throws: ShapePipeline.Failure.self) {
            try pipeline.prepare(Fixtures.polar)
        }
    }

    @Test("A dateline route produces a sane shape")
    func datelineRoute() throws {
        let prepared = try pipeline.prepare(Fixtures.datelineCrossing)
        let box = try #require(BoundingBox(prepared.canonical.runs.flatMap { $0 }))
        #expect(box.width > 100)      // not collapsed to a point
        #expect(box.width <= 1024)
    }

    @Test("Trim runs before projection, so it shortens the shape")
    func trimAppliesBeforeProjection() throws {
        let trimmed = ShapePipeline(configuration: .init(trimMeters: 300))
        let untrimmedLength = try pipeline.prepare(Fixtures.straightLine).lengthMeters
        let trimmedLength = try trimmed.prepare(Fixtures.straightLine).lengthMeters
        #expect(trimmedLength < untrimmedLength)
    }

    @Test("Mode presets change resample density")
    func modePresets() throws {
        let route = Fixtures.wanderingWalk(samples: 1_000)
        var walking = ShapePipeline.Configuration.walking
        var driving = ShapePipeline.Configuration.driving
        walking.trimMeters = 0
        driving.trimMeters = 0

        let walkVertices = try ShapePipeline(configuration: walking).prepare(route).vertexCount
        let driveVertices = try ShapePipeline(configuration: driving).prepare(route).vertexCount
        #expect(walkVertices >= driveVertices)
    }
}

@Suite("Orientation")
struct OrientationTests {

    @Test("There are exactly 16 orientations in a fixed order")
    func sixteenInFixedOrder() {
        // The index is persisted as Artwork.renderIndex (DESIGN.md §8.1), so
        // reordering this array silently invalidates stored artwork.
        #expect(Orientation.all.count == 16)
        #expect(Orientation.all[0] == Orientation(rotationDegrees: 0, mirrored: false))
        #expect(Orientation.all[8] == Orientation(rotationDegrees: 0, mirrored: true))
        #expect(Orientation.all[15] == Orientation(rotationDegrees: 315, mirrored: true))
    }

    @Test("Identity leaves points untouched")
    func identity() {
        let points = [Point2D(x: 3, y: 4), Point2D(x: -7, y: 1)]
        let rotated = Orientation.identity.apply(to: points)
        for (a, b) in zip(points, rotated) {
            #expect(abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9)
        }
    }

    @Test("90° rotates counter-clockwise")
    func rotation() {
        let rotated = Orientation(rotationDegrees: 90, mirrored: false)
            .apply(to: [Point2D(x: 10, y: 0)])
        #expect(abs(rotated[0].x) < 1e-9)
        #expect(abs(rotated[0].y - 10) < 1e-9)
    }

    @Test("Mirroring flips x")
    func mirroring() {
        let mirrored = Orientation(rotationDegrees: 0, mirrored: true)
            .apply(to: [Point2D(x: 10, y: 5)])
        #expect(mirrored[0].x == -10)
        #expect(mirrored[0].y == 5)
    }

    @Test("Rotation preserves distances")
    func preservesDistances() {
        let points = [Point2D(x: 0, y: 0), Point2D(x: 30, y: 40)]
        for orientation in Orientation.all {
            let rotated = orientation.apply(to: points)
            #expect(abs(rotated[0].distance(to: rotated[1]) - 50) < 1e-9)
        }
    }

    @Test("Every orientation of a real route renders inside the canvas")
    func allOrientationsFitCanvas() throws {
        let prepared = try ShapePipeline(configuration: .init(trimMeters: 0))
            .prepare(Fixtures.wanderingWalk())

        for shape in prepared.allOrientations() {
            let box = try #require(BoundingBox(shape.runs.flatMap { $0 }))
            #expect(box.minX >= -1e-6 && box.maxX <= shape.canvasSize + 1e-6)
            #expect(box.minY >= -1e-6 && box.maxY <= shape.canvasSize + 1e-6)
        }
    }

    @Test("Rotation-invariant fingerprint metrics stay stable across orientations")
    func rotationInvariants() throws {
        let prepared = try ShapePipeline(configuration: .init(trimMeters: 0))
            .prepare(Fixtures.figureEight())
        let prints = prepared.allOrientations().map(\.fingerprint)

        // Closure and self-intersection count describe the shape itself, not how
        // it is presented — if these drift, the orientation transform is wrong.
        let closures = prints.map(\.closureRatio)
        #expect((closures.max()! - closures.min()!) < 0.02)
        #expect(Set(prints.map(\.selfIntersectionCount)).count == 1)
    }
}
