import Foundation
import Testing
@testable import RouteKit

@Suite("LocationFilterChain")
struct LocationFilterChainTests {

    private func run(
        _ fixes: [LocationFix],
        mode: RecordingMode = .run
    ) -> (decisions: [LocationFilterChain.Decision], chain: LocationFilterChain) {
        var chain = LocationFilterChain(mode: mode)
        let decisions = fixes.map { chain.accept($0, now: $0.timestamp) }
        return (decisions, chain)
    }

    @Test("A clean walk is accepted end to end")
    func cleanWalk() {
        let (decisions, _) = run(Sim.straightWalk(count: 20))
        #expect(decisions.acceptedCount == 20)
    }

    @Test("Stale fixes are rejected")
    func staleFix() {
        var chain = LocationFilterChain(mode: .run)
        let fix = Sim.fix(east: 0, north: 0, secondsIn: 0)
        let decision = chain.accept(fix, now: fix.timestamp.addingTimeInterval(30))
        #expect(decision == .rejected(.stale))
    }

    @Test("Negative accuracy is treated as invalid, not as very accurate")
    func negativeAccuracy() {
        let fix = Sim.fix(east: 0, north: 0, secondsIn: 0, accuracy: -1)
        let (decisions, _) = run([fix])
        #expect(decisions.rejections == [.invalidAccuracy])
    }

    @Test("Warm-up waits for accuracy, not for a fixed number of fixes")
    func warmUpIsAccuracyBased() {
        // DESIGN.md §5.3 — v0.1 dropped the first three fixes unconditionally,
        // which throws away good data and keeps bad data.
        var fixes = Sim.straightWalk(count: 6)
        fixes[0].horizontalAccuracy = 120
        fixes[1].horizontalAccuracy = 80

        let (decisions, _) = run(fixes)
        #expect(decisions.rejections.prefix(2) == [.warmingUp, .warmingUp])
        #expect(decisions.acceptedCount == 4)
    }

    @Test("Good fixes right at the start are not thrown away")
    func noBlanketWarmUpDiscard() {
        let (decisions, _) = run(Sim.straightWalk(count: 3))
        #expect(decisions.acceptedCount == 3)
    }

    @Test("Poor accuracy after warm-up is rejected")
    func poorAccuracy() {
        var fixes = Sim.straightWalk(count: 5)
        fixes[3].horizontalAccuracy = 90
        let (decisions, _) = run(fixes)
        #expect(decisions.rejections == [.poorAccuracy])
    }

    @Test("Fixes closer than the mode's spacing are dropped")
    func tooClose() {
        // 1 m apart in run mode, whose minimum is 8 m.
        let fixes = Sim.straightWalk(count: 5, metresPerFix: 1)
        let (decisions, _) = run(fixes)
        #expect(decisions.acceptedCount == 1)
        #expect(decisions.rejections.allSatisfy { $0 == .tooClose })
    }

    @Test("A lone GPS jump is held, then discarded when it is not confirmed")
    func unconfirmedJumpIsDiscarded() {
        // DESIGN.md §5.3 — hold, do not drop: the next fix decides.
        var fixes = Sim.straightWalk(count: 6)
        fixes[3] = Sim.fix(east: 4_000, north: 4_000, secondsIn: 3)   // ~5.6 km in 1 s

        let (decisions, _) = run(fixes)
        #expect(decisions[3] == .pending)
        #expect(decisions.acceptedCount == 5)
    }

    @Test("A fix that looks like a jump but is confirmed is kept, not lost")
    func confirmedJumpIsKept() {
        // GPS lagging then catching up looks identical to a jump for exactly one
        // fix. Dropping it immediately would lose 200 m of real driving.
        var fixes = Sim.straightWalk(count: 4, metresPerFix: 30)     // 30 m/s
        fixes.append(Sim.fix(east: 290, north: 0, secondsIn: 4))     // 200 m in 1 s
        fixes.append(Sim.fix(east: 320, north: 0, secondsIn: 5))     // resumes 30 m/s

        var chain = LocationFilterChain(mode: .drive)
        let decisions = fixes.map { chain.accept($0, now: $0.timestamp) }
        #expect(decisions[4] == .pending)
        #expect(decisions.acceptedCount == 6)      // the held fix is accepted too
    }

    @Test("Measured speed is preferred over derived speed")
    func usesMeasuredSpeed() {
        var chain = LocationFilterChain(mode: .run)
        _ = chain.accept(Sim.fix(east: 0, north: 0, secondsIn: 0), now: Sim.epoch)

        // Position implies 40 m/s, but the device says 4 m/s. Trust the device.
        let fix = Sim.fix(east: 40, north: 0, secondsIn: 1, speed: 4)
        #expect(chain.accept(fix, now: fix.timestamp) == .accepted([fix]))
    }

    @Test("Unmeasurable speed falls back to distance over time")
    func fallsBackToDerivedSpeed() {
        // CLLocation reports -1 when it cannot measure speed. Using that raw
        // would read as "moving backwards" and pass every plausibility check.
        var chain = LocationFilterChain(mode: .run)
        _ = chain.accept(Sim.fix(east: 0, north: 0, secondsIn: 0), now: Sim.epoch)

        let fix = Sim.fix(east: 400, north: 0, secondsIn: 1, speed: -1)
        #expect(chain.accept(fix, now: fix.timestamp) == .pending)
    }

    @Test("Standing still is never filtered out")
    func slowMovementSurvives() {
        // DESIGN.md v0.2 removed the lower speed bound: it deleted uphill
        // stretches and traffic lights. Auto-pause handles stillness instead.
        var chain = LocationFilterChain(mode: .walk)
        var accepted = 0
        for i in 0..<10 {
            // 6 m per 30 s — 0.2 m/s, below v0.1's 0.3 m/s floor.
            let fix = Sim.fix(east: Double(i) * 6, north: 0, secondsIn: Double(i) * 30)
            if case .accepted = chain.accept(fix, now: fix.timestamp) { accepted += 1 }
        }
        #expect(accepted == 10)
    }

    @Test("Modes have different tolerances")
    func modeTolerances() {
        // 30 m/s is impossible on foot and unremarkable in a car.
        let fixes = [
            Sim.fix(east: 0, north: 0, secondsIn: 0),
            Sim.fix(east: 30, north: 0, secondsIn: 1),
        ]
        #expect(run(fixes, mode: .run).decisions[1] == .pending)
        #expect(run(fixes, mode: .drive).decisions.acceptedCount == 2)
    }

    @Test("A fix from the future is rejected, not treated as fresh")
    func futureFix() {
        // `now - timestamp <= maximumAge` is satisfied by any negative age, so a
        // clock correction would otherwise wave a future fix straight through.
        var chain = LocationFilterChain(mode: .run)
        let fix = Sim.fix(east: 0, north: 0, secondsIn: 3_600)
        #expect(chain.accept(fix, now: Sim.epoch) == .rejected(.fromTheFuture))
    }

    @Test("A held outlier is handed back rather than dropped")
    func takePendingReturnsTheFix() {
        // DESIGN.md §5.4 — the caller decides what to do with it; the filter
        // must not delete a coordinate the device reported.
        var chain = LocationFilterChain(mode: .run)
        _ = chain.accept(Sim.fix(east: 0, north: 0, secondsIn: 0), now: Sim.epoch)

        let jump = Sim.fix(east: 5_000, north: 0, secondsIn: 1)
        #expect(chain.accept(jump, now: jump.timestamp) == .pending)
        #expect(chain.takePending() == jump)
        #expect(chain.takePending() == nil)
    }

    @Test("An out-of-order fix does not evict a held one")
    func outOfOrderDoesNotEvictPending() {
        var chain = LocationFilterChain(mode: .run)
        _ = chain.accept(Sim.fix(east: 0, north: 0, secondsIn: 10), now: Sim.epoch.addingTimeInterval(10))

        let jump = Sim.fix(east: 5_000, north: 0, secondsIn: 11)
        #expect(chain.accept(jump, now: jump.timestamp) == .pending)

        // Same timestamp as the last accepted fix: no elapsed time to judge.
        let sameTime = Sim.fix(east: 50, north: 0, secondsIn: 10)
        #expect(chain.accept(sameTime, now: sameTime.timestamp.addingTimeInterval(1)) == .rejected(.outOfOrder))
        #expect(chain.takePending() == jump)     // still held
    }

    @Test("Zero and negative time deltas are not plausible")
    func nonPositiveTimeDelta() {
        var chain = LocationFilterChain(mode: .run)
        _ = chain.accept(Sim.fix(east: 0, north: 0, secondsIn: 10), now: Sim.epoch.addingTimeInterval(10))

        // Same timestamp: dividing by zero would otherwise produce infinity.
        let sameTime = Sim.fix(east: 50, north: 0, secondsIn: 10)
        #expect(chain.accept(sameTime, now: sameTime.timestamp) == .rejected(.outOfOrder))
    }
}
