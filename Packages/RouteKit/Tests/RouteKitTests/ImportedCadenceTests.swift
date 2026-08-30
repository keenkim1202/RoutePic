import Foundation
import ShapeKit
import Testing
@testable import RouteKit

/// A real Health history imported 36 of 51, and the 15 said "this track is only
/// 0 m long". They were not short. They were sampled slower than the recorder's
/// gap threshold, so every interval read as a dropout, no moving run survived,
/// and distance — which only accumulates inside a run — came out zero.
@Suite("Imported tracks keep their own cadence")
struct ImportedCadenceTests {

    private func points(
        count: Int, everySeconds: Double, metresApart: Double, holeAfter: Int? = nil
    ) -> [RoutePoint] {
        let perDegree = ENUProjection.earthRadius * .pi / 180
        var elapsed = 0.0
        return (0..<count).map { index in
            if index > 0 {
                elapsed += everySeconds + (index == holeAfter ? 3_600 : 0)
            }
            return RoutePoint(
                latitude: 37.5665 + Double(index) * metresApart / perDegree,
                longitude: 126.9780,
                altitude: 10,
                timestamp: Date(timeIntervalSince1970: 1_780_000_000 + elapsed),
                horizontalAccuracy: 10,
                verticalAccuracy: 10
            )
        }
    }

    @Test("A five-kilometre walk sampled every two minutes is five kilometres")
    func sparseSamplingKeepsItsDistance() {
        let sparse = points(count: 100, everySeconds: 120, metresApart: 50)
        let route = Route(
            points: sparse,
            splittingGapsLongerThan: Route.dropoutThreshold(for: sparse, mode: .walk)
        )
        let stats = ActivityStatistics.compute(for: route)

        #expect(route.movingRuns.count == 1)
        #expect(stats.distanceMeters > 4_500)
    }

    /// The bar moving with the source must not stop it finding a real hole.
    @Test("An hour-long hole is still a hole in a sparse track")
    func realDropoutSurvivesInASparseTrack() {
        let sparse = points(count: 100, everySeconds: 120, metresApart: 50, holeAfter: 50)
        let route = Route(
            points: sparse,
            splittingGapsLongerThan: Route.dropoutThreshold(for: sparse, mode: .walk)
        )

        #expect(route.segments.contains { $0.kind == .gap })
        #expect(ActivityStatistics.compute(for: route).distanceMeters > 4_000)
    }

    /// A densely sampled track must keep the recorder's own threshold: at one
    /// fix a second, eight medians is eight seconds, and a minute of tunnel
    /// would stop reading as a dropout.
    @Test("A dense track keeps the recorder's threshold as its floor")
    func denseTrackKeepsTheFloor() {
        let dense = points(count: 300, everySeconds: 1, metresApart: 3)
        #expect(Route.dropoutThreshold(for: dense, mode: .walk) == RecordingMode.walk.gapThreshold)
    }

    /// Two points make one interval, and that interval is the whole list — a
    /// two-hour hole would declare itself ordinary and be drawn straight
    /// through as movement.
    @Test("A track too short to have a rhythm does not get to invent one")
    func shortTrackFallsBackToTheMode() {
        let perDegree = ENUProjection.earthRadius * .pi / 180
        let pair = [
            RoutePoint(latitude: 37.5665, longitude: 126.9780,
                       timestamp: Date(timeIntervalSince1970: 1_780_000_000)),
            RoutePoint(latitude: 37.5665 + 500 / perDegree, longitude: 126.9780,
                       timestamp: Date(timeIntervalSince1970: 1_780_007_200)),
        ]
        #expect(Route.dropoutThreshold(for: pair, mode: .walk) == RecordingMode.walk.gapThreshold)

        let route = Route(
            points: pair,
            splittingGapsLongerThan: Route.dropoutThreshold(for: pair, mode: .walk)
        )
        #expect(route.segments.contains { $0.kind == .gap })
    }

    /// Several holes in a shortish track would carry the middle of the list
    /// with them; the quarter point stays with the ordinary intervals.
    @Test("A few holes do not become the typical interval")
    func holesDoNotBecomeTypical() {
        let perDegree = ENUProjection.earthRadius * .pi / 180
        var elapsed = 0.0
        let mixed = (0..<12).map { index -> RoutePoint in
            if index > 0 { elapsed += index % 3 == 0 ? 3_600 : 120 }
            return RoutePoint(
                latitude: 37.5665 + Double(index) * 100 / perDegree, longitude: 126.9780,
                timestamp: Date(timeIntervalSince1970: 1_780_000_000 + elapsed)
            )
        }
        let threshold = Route.dropoutThreshold(for: mixed, mode: .walk)
        #expect(threshold < 3_600)

        let route = Route(points: mixed, splittingGapsLongerThan: threshold)
        #expect(route.segments.contains { $0.kind == .gap })
    }

    /// A source that logs a dense burst and then settles into two-minute steps.
    /// Taking a lower point in the interval list lets the burst set the bar, and
    /// every ordinary step after it reads as a hole — the original bug, wearing
    /// a different hat.
    @Test("A burst of dense sampling does not set the bar for the rest")
    func denseBurstDoesNotDominate() {
        let perDegree = ENUProjection.earthRadius * .pi / 180
        var elapsed = 0.0
        let mixed = (0..<100).map { index -> RoutePoint in
            if index > 0 { elapsed += index < 30 ? 1 : 120 }
            return RoutePoint(
                latitude: 37.5665 + Double(index) * 50 / perDegree, longitude: 126.9780,
                timestamp: Date(timeIntervalSince1970: 1_780_000_000 + elapsed)
            )
        }
        let route = Route(
            points: mixed,
            splittingGapsLongerThan: Route.dropoutThreshold(for: mixed, mode: .walk)
        )

        #expect(!route.segments.contains { $0.kind == .gap })
        #expect(ActivityStatistics.compute(for: route).distanceMeters > 4_000)
    }

    @Test("A track with no usable times falls back to the mode")
    func untimedTrackFallsBack() {
        let untimed = [
            RoutePoint(latitude: 37.5, longitude: 126.9, timestamp: nil),
            RoutePoint(latitude: 37.6, longitude: 126.9, timestamp: nil),
        ]
        #expect(Route.dropoutThreshold(for: untimed, mode: .run) == RecordingMode.run.gapThreshold)
    }
}
