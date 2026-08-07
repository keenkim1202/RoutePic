import Foundation
import ShapeKit
import Testing
@testable import RouteKit

@Suite("ActivityStatistics")
struct ActivityStatisticsTests {

    private func route(_ fixes: [LocationFix]) -> Route {
        Route(points: fixes.map(\.routePoint))
    }

    @Test("Distance sums the geodesic steps")
    func distance() {
        let statistics = ActivityStatistics.compute(
            for: route(Sim.straightWalk(count: 11, metresPerFix: 10))
        )
        #expect(abs(statistics.distanceMeters - 100) < 1)
    }

    @Test("Moving duration is the span of the moving runs")
    func movingDuration() {
        let statistics = ActivityStatistics.compute(for: route(Sim.straightWalk(count: 61)))
        #expect(statistics.movingDuration == 60)
        #expect(statistics.elapsedDuration == 60)
    }

    @Test("Distance is not measured across a gap")
    func distanceExcludesGaps() {
        // DESIGN.md §9 — crediting the straight line across a dropout would
        // report ground the user may not have covered.
        var points = Sim.straightWalk(count: 10, metresPerFix: 10).map(\.routePoint)
        let secondRun = Sim.straightWalk(count: 10, metresPerFix: 10, startingAt: 600)
            .map { fix -> RoutePoint in
                var point = fix.routePoint
                point.longitude += 0.05          // several kilometres away
                return point
            }
        let firstCount = points.count
        points.append(contentsOf: secondRun)

        let route = Route(
            points: points,
            segments: [
                RouteSegment(startIndex: 0, endIndex: firstCount, kind: .moving),
                RouteSegment(startIndex: firstCount, endIndex: firstCount, kind: .gap),
                RouteSegment(startIndex: firstCount, endIndex: points.count, kind: .moving),
            ]
        )

        let statistics = ActivityStatistics.compute(for: route)
        // Two 90 m runs, not 90 + 4,000 + 90.
        #expect(statistics.distanceMeters < 250)
        #expect(statistics.gapDuration > 0)
    }

    @Test("Paused time is separated from moving time")
    func pausedDuration() {
        var points = Sim.straightWalk(count: 10).map(\.periodPoint)
        let firstCount = points.count
        points.append(contentsOf: Sim.straightWalk(count: 10, startingAt: 300).map(\.periodPoint))

        let route = Route(
            points: points,
            segments: [
                RouteSegment(startIndex: 0, endIndex: firstCount, kind: .moving),
                RouteSegment(startIndex: firstCount, endIndex: firstCount, kind: .paused),
                RouteSegment(startIndex: firstCount, endIndex: points.count, kind: .moving),
            ]
        )

        let statistics = ActivityStatistics.compute(for: route)
        #expect(statistics.pausedDuration == 291)     // 300 − 9
        #expect(statistics.movingDuration == 18)      // two 9-second runs
        #expect(statistics.gapDuration == 0)
    }

    @Test("Pace is nil when nothing moved")
    func paceWithoutMovement() {
        #expect(ActivityStatistics.zero.paceSecondsPerKilometre == nil)
        #expect(ActivityStatistics.zero.averageSpeed == 0)
    }

    @Test("Pace is seconds per kilometre over moving time")
    func pace() {
        // 1,000 m in 300 s → 5:00/km.
        let statistics = ActivityStatistics.compute(
            for: route((0..<101).map { Sim.fix(east: Double($0) * 10, north: 0, secondsIn: Double($0) * 3) })
        )
        let pace = statistics.paceSecondsPerKilometre ?? 0
        #expect(abs(pace - 300) < 5)
    }

    @Test("Climb ignores fixes with poor vertical accuracy")
    func elevationAccuracyFilter() {
        // GPS altitude is far noisier than position; unfiltered it invents
        // hundreds of metres of ascent on a flat run.
        let fixes = (0..<20).map { i in
            Sim.fix(
                east: Double(i) * 10, north: 0, secondsIn: Double(i),
                verticalAccuracy: 60,                 // all above the ceiling
                altitude: Double(i) * 20
            )
        }
        #expect(ActivityStatistics.compute(for: route(fixes)).elevationGainMeters == 0)
    }

    @Test("Climb accumulates real ascent")
    func elevationGain() {
        let fixes = (0..<20).map { i in
            Sim.fix(
                east: Double(i) * 10, north: 0, secondsIn: Double(i),
                verticalAccuracy: 5, altitude: 30 + Double(i) * 10
            )
        }
        let gain = ActivityStatistics.compute(for: route(fixes)).elevationGainMeters
        #expect(abs(gain - 190) < 1)
    }

    @Test("Altitude noise does not accumulate into phantom climb")
    func elevationHysteresis() {
        // ±2 m oscillation on flat ground — mild for GPS altitude. Consecutive
        // readings differ by 4 m, so DESIGN.md's original 3 m hysteresis let
        // every upswing through and invented 76 m of ascent over 40 fixes.
        let fixes = (0..<40).map { i in
            Sim.fix(
                east: Double(i) * 10, north: 0, secondsIn: Double(i),
                verticalAccuracy: 5, altitude: 30 + (i % 2 == 0 ? 2 : -2)
            )
        }
        #expect(ActivityStatistics.compute(for: route(fixes)).elevationGainMeters == 0)
    }

    @Test("Larger noise still does not accumulate")
    func elevationLargerNoise() {
        // ±4 m swings, 8 m peak-to-peak, still under the ceiling.
        let fixes = (0..<40).map { i in
            Sim.fix(
                east: Double(i) * 10, north: 0, secondsIn: Double(i),
                verticalAccuracy: 5, altitude: 30 + (i % 2 == 0 ? 4 : -4)
            )
        }
        #expect(ActivityStatistics.compute(for: route(fixes)).elevationGainMeters == 0)
    }

    @Test("Descending then climbing measures from the bottom")
    func elevationAfterDescent() {
        let altitudes = [100.0, 90, 80, 70, 80, 90, 100]
        let fixes = altitudes.enumerated().map { index, altitude in
            Sim.fix(
                east: Double(index) * 10, north: 0, secondsIn: Double(index),
                verticalAccuracy: 5, altitude: altitude
            )
        }
        // 30 m of climb out of the dip, not 0 and not 60.
        let gain = ActivityStatistics.compute(for: route(fixes)).elevationGainMeters
        #expect(abs(gain - 30) < 1)
    }

    @Test("An empty route yields zeroes rather than crashing")
    func emptyRoute() {
        let statistics = ActivityStatistics.compute(for: Route(points: []))
        #expect(statistics.distanceMeters == 0)
        #expect(statistics.elapsedDuration == 0)
    }
}

private extension LocationFix {
    /// The tests above need points that keep their timestamps.
    var periodPoint: RoutePoint { routePoint }
}
