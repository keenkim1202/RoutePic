import Foundation
import ShapeKit
import Testing
@testable import RouteKit

@Suite("Route import")
struct RouteImportTests {

    /// Metres east of `Sim.baseLongitude`, `seconds` after `Sim.epoch`.
    private func point(east: Double, seconds: Double) -> RoutePoint {
        Sim.fix(east: east, north: 0, secondsIn: seconds).routePoint
    }

    @Test("A hole longer than the threshold becomes a gap, not a straight line")
    func splitsOnGap() {
        let points = [
            point(east: 0, seconds: 0),
            point(east: 10, seconds: 10),
            point(east: 900, seconds: 400),   // 390 s hole
            point(east: 910, seconds: 410),
        ]

        let route = Route(points: points, splittingGapsLongerThan: 60)

        #expect(route.segments.map(\.kind) == [.moving, .gap, .moving])
        #expect(route.movingRuns.count == 2)
        // The two ends of the hole must not end up in the same run, or the
        // renderer draws the 890 m the person never walked.
        #expect(route.movingRuns[0].count == 2)
        #expect(route.movingRuns[1].count == 2)
    }

    @Test("A continuous track stays one run")
    func keepsContinuousTrackWhole() {
        let points = (0..<20).map { point(east: Double($0) * 5, seconds: Double($0) * 5) }
        let route = Route(points: points, splittingGapsLongerThan: 60)

        #expect(route.segments.map(\.kind) == [.moving])
        #expect(route.movingRuns.count == 1)
    }

    @Test("Empty and single-point tracks do not trap")
    func handlesDegenerateInput() {
        #expect(Route(points: [], splittingGapsLongerThan: 60).movingRuns.isEmpty)
        #expect(Route(points: [point(east: 0, seconds: 0)], splittingGapsLongerThan: 60)
            .movingRuns.isEmpty)
    }

    @Test("A break the source declared survives even with no hole in the clock")
    func keepsDeclaredBreaks() {
        // Two runs five seconds apart: the clock alone would join them.
        let points = (0..<20).map { point(east: Double($0) * 5, seconds: Double($0) * 5) }
        let declared = Route(points: points, segments: [
            RouteSegment(startIndex: 0, endIndex: 10, kind: .moving),
            RouteSegment(startIndex: 10, endIndex: 10, kind: .gap),
            RouteSegment(startIndex: 10, endIndex: 20, kind: .moving),
        ])

        let result = declared.splittingGaps(longerThan: 60)

        #expect(result.segments.map(\.kind) == [.moving, .gap, .moving])
        #expect(result.points.count == 20)
    }

    /// One median over the whole track lets the sparse run set the bar for the
    /// dense one, and the hole inside the dense run is then drawn as movement —
    /// the inverse of the collapse `dropoutThreshold` was written for.
    @Test("A dense run keeps its own dropout bar when a sparse run shares the track")
    func cadenceIsJudgedPerRun() {
        // 30 fixes two minutes apart, then 12 ten seconds apart with a five
        // minute hole in the middle of them.
        var points = (0..<30).map { point(east: Double($0) * 100, seconds: Double($0) * 120) }
        var clock = 3600.0
        for i in 0..<12 {
            clock += (i == 6 ? 300 : 10)
            points.append(point(east: 3000 + Double(i) * 10, seconds: clock))
        }
        let declared = Route(points: points, segments: [
            RouteSegment(startIndex: 0, endIndex: 30, kind: .moving),
            RouteSegment(startIndex: 30, endIndex: 30, kind: .gap),
            RouteSegment(startIndex: 30, endIndex: 42, kind: .moving),
        ])
        func gaps(_ route: Route) -> Int { route.segments.filter { $0.kind == .gap }.count }

        let routeWide = declared.splittingGaps(
            longerThan: Route.dropoutThreshold(for: declared.points, mode: .walk)
        )
        let perRun = declared.splittingGapsByCadence(mode: .walk)

        // The sparse run's median raises the bar to 960 s and swallows the hole.
        #expect(gaps(routeWide) == 1)
        #expect(gaps(perRun) == 2)
    }

    @Test("Mode is inferred from median step speed", arguments: [
        (1.3, RecordingMode.walk),
        (3.2, RecordingMode.run),
        (14.0, RecordingMode.drive),
    ])
    func infersMode(speed: Double, expected: RecordingMode) {
        let points = (0..<40).map { point(east: Double($0) * speed, seconds: Double($0)) }
        #expect(RecordingMode.inferred(from: points) == expected)
    }

    @Test("A long stop does not drag the guess down a mode")
    func medianIgnoresStops() {
        // Ten minutes standing still, then a run. The average would read as a walk.
        var points = (0..<30).map { point(east: 0, seconds: Double($0) * 20) }
        points += (0..<30).map { point(east: Double($0) * 3.2, seconds: 600 + Double($0)) }

        #expect(RecordingMode.inferred(from: points) == .run)
    }
}
