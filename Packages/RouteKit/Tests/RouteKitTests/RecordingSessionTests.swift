import Foundation
import ShapeKit
import Testing
@testable import RouteKit

@Suite("RecordingSession")
struct RecordingSessionTests {

    @Test("A session records a route from a clean walk")
    func happyPath() async {
        let session = RecordingSession(mode: .run)
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 30), into: session)

        let route = await session.finish(now: Sim.epoch.addingTimeInterval(30))
        #expect(route?.points.count == 30)
        #expect(route?.movingRuns.count == 1)
    }

    @Test("Fixes before start are ignored")
    func ingestBeforeStart() async {
        let session = RecordingSession(mode: .run)
        let accepted = await session.ingest(Sim.fix(east: 0, north: 0, secondsIn: 0), now: Sim.epoch)
        #expect(!accepted)
    }

    @Test("A silence longer than the mode's threshold becomes a gap")
    func gapDetection() async throws {
        // DESIGN.md §5.4 — the two stretches must never be joined by a line the
        // person never walked.
        let session = RecordingSession(mode: .run)     // 60 s threshold
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 10), into: session)
        await Sim.feed(Sim.straightWalk(count: 10, startingAt: 400), into: session)

        let route = try #require(await session.finish(now: Sim.epoch.addingTimeInterval(500)))
        #expect(route.movingRuns.count == 2)
        #expect(route.segments.contains { $0.kind == .gap })
    }

    @Test("A short silence is not a gap")
    func shortSilenceIsNotAGap() async throws {
        let session = RecordingSession(mode: .run)
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 10), into: session)
        await Sim.feed(Sim.straightWalk(count: 10, startingAt: 40), into: session)

        let route = try #require(await session.finish(now: Sim.epoch.addingTimeInterval(60)))
        #expect(route.movingRuns.count == 1)
    }

    @Test("Gap thresholds differ by mode")
    func gapThresholdsByMode() async throws {
        // 50 s of silence: a gap while driving, not while walking.
        func runsAfterSilence(mode: RecordingMode) async throws -> Int {
            let session = RecordingSession(mode: mode)
            await session.start(now: Sim.epoch)
            await Sim.feed(Sim.straightWalk(count: 5, metresPerFix: 30), into: session)
            await Sim.feed(
                Sim.straightWalk(count: 5, metresPerFix: 30, startingAt: 55), into: session
            )
            let route = try #require(await session.finish(now: Sim.epoch.addingTimeInterval(80)))
            return route.movingRuns.count
        }
        #expect(try await runsAfterSilence(mode: .drive) == 2)   // 45 s threshold
        #expect(try await runsAfterSilence(mode: .walk) == 1)    // 90 s threshold
    }

    @Test("The snapshot hands the map the same runs the stored route has")
    func snapshotCarriesMovingRuns() async throws {
        let session = RecordingSession(mode: .run)
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 10), into: session)
        await Sim.feed(Sim.straightWalk(count: 10, startingAt: 200), into: session)

        // Two runs, not one: the live map must show the dropout as a break
        // rather than drawing a line across it.
        let snapshot = await session.snapshot()
        #expect(snapshot.movingRuns.count == 2)
        #expect(snapshot.movingRuns.allSatisfy { $0.count >= 2 })

        let route = try #require(await session.finish(now: Sim.epoch.addingTimeInterval(300)))
        #expect(snapshot.movingRuns.count == route.movingRuns.count)
    }

    @Test("Pause splits the route and resume starts a new run")
    func pauseAndResume() async throws {
        let session = RecordingSession(mode: .run)
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 10), into: session)

        await session.pause(now: Sim.epoch.addingTimeInterval(10))
        // Fixes arriving while paused are discarded.
        await Sim.feed(Sim.straightWalk(count: 5, startingAt: 15), into: session)
        #expect(await session.state == .paused)

        await session.resume(now: Sim.epoch.addingTimeInterval(60))
        await Sim.feed(Sim.straightWalk(count: 10, startingAt: 60), into: session)

        let route = try #require(await session.finish(now: Sim.epoch.addingTimeInterval(80)))
        #expect(route.points.count == 20)
        #expect(route.movingRuns.count == 2)
        #expect(route.segments.contains { $0.kind == .paused })
    }

    @Test("Resuming clears the plausibility reference")
    func resumeResetsFilter() async throws {
        // After an arbitrary pause the pre-pause fix says nothing about whether
        // the next one is plausible — the user may have driven home.
        let session = RecordingSession(mode: .walk)
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 5), into: session)
        await session.pause(now: Sim.epoch.addingTimeInterval(5))
        await session.resume(now: Sim.epoch.addingTimeInterval(3_600))

        let faraway = Sim.fix(east: 50_000, north: 0, secondsIn: 3_601)
        let accepted = await session.ingest(faraway, now: faraway.timestamp)
        #expect(accepted)
    }

    @Test("Standing still suggests a pause without forcing one")
    func autoPauseSuggestion() async {
        // DESIGN.md §5.5 — a suggestion the user ignores is recoverable; an
        // automatic pause they did not want is not.
        let session = RecordingSession(mode: .walk)
        await session.start(now: Sim.epoch)

        for i in 0..<40 {
            // Drifting within a couple of metres for 120 s.
            let fix = Sim.fix(east: Double(i % 3), north: 0, secondsIn: Double(i) * 3)
            await session.ingest(fix, now: fix.timestamp)
        }

        let snapshot = await session.snapshot()
        #expect(snapshot.suggestsPause)
        #expect(snapshot.state == .recording)
    }

    @Test("Moving again withdraws the pause suggestion")
    func autoPauseClears() async {
        let session = RecordingSession(mode: .walk)
        await session.start(now: Sim.epoch)
        for i in 0..<40 {
            let fix = Sim.fix(east: Double(i % 3), north: 0, secondsIn: Double(i) * 3)
            await session.ingest(fix, now: fix.timestamp)
        }
        #expect(await session.snapshot().suggestsPause)

        let moved = Sim.fix(east: 200, north: 0, secondsIn: 200)
        await session.ingest(moved, now: moved.timestamp)
        #expect(!(await session.snapshot().suggestsPause))
    }

    @Test("Driving never suggests a pause")
    func drivingHasNoAutoPause() async {
        // Sitting at a red light is not a pause.
        let session = RecordingSession(mode: .drive)
        await session.start(now: Sim.epoch)
        for i in 0..<40 {
            let fix = Sim.fix(east: Double(i % 3), north: 0, secondsIn: Double(i) * 3)
            await session.ingest(fix, now: fix.timestamp)
        }
        #expect(!(await session.snapshot().suggestsPause))
    }

    @Test("A held outlier is kept when the session ends, not discarded")
    func pendingIsKeptOnFinish() async throws {
        // DESIGN.md §5.4 — losing a coordinate the device reported is the worst
        // failure here. Nothing will arrive to confirm the held fix, so it is
        // committed rather than dropped.
        // Run mode: 10 m/s is plausible there, so the five approach fixes are
        // accepted and only the jump is held.
        let session = RecordingSession(mode: .run)
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 5, metresPerFix: 10), into: session)

        let jump = Sim.fix(east: 5_000, north: 0, secondsIn: 5)
        #expect(!(await session.ingest(jump, now: jump.timestamp)))   // held

        let route = try #require(await session.finish(now: Sim.epoch.addingTimeInterval(6)))
        #expect(route.points.count == 6)
        #expect(route.points.last?.longitude == jump.longitude)
    }

    @Test("A held outlier is kept when the session pauses")
    func pendingIsKeptOnPause() async throws {
        let session = RecordingSession(mode: .run)
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 5, metresPerFix: 10), into: session)

        let jump = Sim.fix(east: 5_000, north: 0, secondsIn: 5)
        await session.ingest(jump, now: jump.timestamp)
        await session.pause(now: Sim.epoch.addingTimeInterval(6))

        #expect(await session.snapshot().pointCount == 6)
    }

    @Test("A held outlier is kept when a gap interrupts the session")
    func pendingIsKeptOnGap() async throws {
        let session = RecordingSession(mode: .run)     // 60 s gap threshold
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 5, metresPerFix: 10), into: session)

        let jump = Sim.fix(east: 5_000, north: 0, secondsIn: 5)
        await session.ingest(jump, now: jump.timestamp)
        // Long silence, then a new stretch.
        await Sim.feed(Sim.straightWalk(count: 5, metresPerFix: 10, startingAt: 400), into: session)

        let route = try #require(await session.finish(now: Sim.epoch.addingTimeInterval(500)))
        #expect(route.points.count == 11)          // 5 + held + 5
        #expect(route.movingRuns.count == 2)
    }

    @Test("A stale fix does not cut the route in two")
    func staleFixDoesNotCreateGap() async throws {
        // A late-arriving reading must not be read as a dropout: that would
        // split a continuous walk and draw it as two disconnected pieces.
        let session = RecordingSession(mode: .run)
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 5, metresPerFix: 10), into: session)

        // Timestamped long after the last fix, but delivered stale.
        let stale = Sim.fix(east: 100, north: 0, secondsIn: 500)
        await session.ingest(stale, now: Sim.epoch.addingTimeInterval(600))

        await Sim.feed(Sim.straightWalk(count: 5, metresPerFix: 10, startingAt: 6), into: session)
        let route = try #require(await session.finish(now: Sim.epoch.addingTimeInterval(20)))
        #expect(route.movingRuns.count == 1)
    }

    @Test("A session with nothing usable finishes as nil")
    func emptySession() async {
        let session = RecordingSession(mode: .run)
        await session.start(now: Sim.epoch)
        #expect(await session.finish(now: Sim.epoch.addingTimeInterval(5)) == nil)
    }

    @Test("Finishing twice returns the same route")
    func idempotentFinish() async {
        let session = RecordingSession(mode: .run)
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 10), into: session)

        let first = await session.finish(now: Sim.epoch.addingTimeInterval(10))
        let second = await session.finish(now: Sim.epoch.addingTimeInterval(20))
        #expect(first?.points.count == second?.points.count)
    }

    @Test("The snapshot reports live statistics")
    func snapshotStatistics() async {
        let session = RecordingSession(mode: .run)
        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 11, metresPerFix: 10), into: session)

        let snapshot = await session.snapshot()
        #expect(snapshot.pointCount == 11)
        #expect(abs(snapshot.statistics.distanceMeters - 100) < 2)
        #expect(snapshot.statistics.movingDuration == 10)
    }

    @Test("A session writes a journal that recovers the same route")
    func journalIntegration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routepic-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let url = SessionRecovery.journalURL(for: id, in: directory)
        let journal = try SessionJournal(url: url)
        let session = RecordingSession(id: id, mode: .run, journal: journal)

        await session.start(now: Sim.epoch)
        await Sim.feed(Sim.straightWalk(count: 25), into: session)
        await session.flushJournal(now: Sim.epoch.addingTimeInterval(25))

        // Recover without finishing — the crash case.
        let candidate = try #require(SessionRecovery.candidate(at: url))
        #expect(candidate.sessionID == id)
        #expect(candidate.mode == .run)
        #expect(candidate.route.points.count == 25)
        #expect(candidate.isUsable)
    }
}

@Suite("SessionRecovery")
struct SessionRecoveryTests {

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("routepic-recovery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Unfinished journals are found, newest first")
    func findsCandidates() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for (index, offset) in [0.0, 3_600.0, 7_200.0].enumerated() {
            let id = UUID()
            let journal = try SessionJournal(url: SessionRecovery.journalURL(for: id, in: directory))
            journal.append(
                .header(
                    sessionID: id, mode: .walk, startedAt: Sim.epoch.addingTimeInterval(offset)
                )
            )
            for fix in Sim.straightWalk(count: 5, startingAt: offset + Double(index)) {
                journal.append(.fix(fix), now: fix.timestamp)
            }
            journal.close()
        }

        let candidates = SessionRecovery.candidates(in: directory)
        #expect(candidates.count == 3)
        #expect(candidates[0].startedAt == Sim.epoch.addingTimeInterval(7_200))
    }

    @Test("A journal with only a header is found but marked unusable")
    func headerOnlyIsUnusable() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let journal = try SessionJournal(url: SessionRecovery.journalURL(for: id, in: directory))
        journal.append(.header(sessionID: id, mode: .run, startedAt: Sim.epoch))
        journal.close()

        let candidate = try #require(SessionRecovery.candidates(in: directory).first)
        #expect(!candidate.isUsable)
    }

    @Test("A damaged tail is reported, not hidden")
    func reportsDamage() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let url = SessionRecovery.journalURL(for: id, in: directory)
        let journal = try SessionJournal(url: url)
        journal.append(.header(sessionID: id, mode: .run, startedAt: Sim.epoch))
        for fix in Sim.straightWalk(count: 20) { journal.append(.fix(fix), now: fix.timestamp) }
        journal.close()

        let full = try Data(contentsOf: url)
        try full.prefix(full.count - 20).write(to: url)

        let candidate = try #require(SessionRecovery.candidate(at: url))
        #expect(candidate.hadDamagedTail)
        #expect(candidate.isUsable)
    }

    @Test("Discarding removes the journal")
    func discard() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let url = SessionRecovery.journalURL(for: id, in: directory)
        let journal = try SessionJournal(url: url)
        journal.append(.header(sessionID: id, mode: .run, startedAt: Sim.epoch))
        for fix in Sim.straightWalk(count: 5) { journal.append(.fix(fix), now: fix.timestamp) }
        journal.close()

        let candidate = try #require(SessionRecovery.candidate(at: url))
        #expect(SessionRecovery.discard(candidate))
        #expect(SessionRecovery.candidates(in: directory).isEmpty)
    }

    @Test("An empty directory yields nothing")
    func emptyDirectory() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SessionRecovery.candidates(in: directory).isEmpty)
    }
}
