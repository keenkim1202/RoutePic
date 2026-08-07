import Foundation
import RouteKit
import RoutePicStore
import ShapeKit
import SwiftUI

/// Drives a recording session from the UI.
///
/// `RecordingSession` is an actor and time-injected; this is the main-actor
/// adapter that pumps the location stream into it and republishes snapshots.
@Observable
@MainActor
final class RecordingController {

    enum Phase: Equatable {
        case idle
        case starting
        case running
        case paused
        case saving
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var snapshot: RecordingSession.Snapshot?
    private(set) var mode: RecordingMode = .run

    /// Unfinished journals found at launch (`DESIGN.md` §5.4).
    private(set) var recoveryCandidates: [SessionRecovery.Candidate] = []

    private let locationSource: any LocationSource
    private let repository: ActivityRepository
    private var session: RecordingSession?
    private var pumpTask: Task<Void, Never>?
    private var journalDirectory: URL?

    init(locationSource: any LocationSource, repository: ActivityRepository) {
        self.locationSource = locationSource
        self.repository = repository
        self.journalDirectory = try? SessionRecovery.journalDirectory()
    }

    var isRecording: Bool { phase == .running || phase == .paused }

    // MARK: - Lifecycle

    func scanForRecovery() {
        guard let journalDirectory else { return }
        recoveryCandidates = SessionRecovery.candidates(in: journalDirectory)
            .filter { $0.isUsable }
    }

    func start(mode: RecordingMode) async {
        guard !isRecording else { return }
        self.mode = mode
        phase = .starting

        let id = UUID()
        let journal = journalDirectory.flatMap {
            try? SessionJournal(url: SessionRecovery.journalURL(for: id, in: $0))
        }
        let session = RecordingSession(id: id, mode: mode, journal: journal)
        self.session = session

        // The stream is installed *before* the source starts. The other order
        // is a race: `start()` can deliver its first fixes before `updates()`
        // has somewhere to put them, and those fixes are simply lost — which is
        // precisely the beginning of the route.
        let stream = locationSource.updates()
        pumpTask = Task { [weak self] in
            for await fix in stream {
                guard let self else { return }
                await self.handle(fix)
            }
        }

        do {
            try await locationSource.start(mode: mode)
        } catch {
            pumpTask?.cancel()
            pumpTask = nil
            phase = .failed(describe(error))
            self.session = nil
            return
        }

        await session.start(now: Date())
        phase = .running
        snapshot = await session.snapshot()
    }

    private func handle(_ fix: LocationFix) async {
        guard let session else { return }
        await session.ingest(fix, now: Date())
        snapshot = await session.snapshot()
    }

    func pause() async {
        guard let session, phase == .running else { return }
        await session.pause(now: Date())
        phase = .paused
        snapshot = await session.snapshot()
    }

    func resume() async {
        guard let session, phase == .paused else { return }
        await session.resume(now: Date())
        phase = .running
        snapshot = await session.snapshot()
    }

    /// Ends the session and saves it. Returns the stored activity, or `nil` when
    /// nothing usable was recorded.
    @discardableResult
    func finish() async -> Activity? {
        guard let session else { return nil }
        phase = .saving
        pumpTask?.cancel()
        await locationSource.stop()

        let route = await session.finish(now: Date())
        self.session = nil
        pumpTask = nil

        guard let route, let first = route.points.first?.timestamp,
              let last = route.points.last?.timestamp else {
            phase = .idle
            snapshot = nil
            discardJournal(for: session)
            return nil
        }

        do {
            let activity = try repository.save(
                route: route, mode: mode, startedAt: first, endedAt: last
            )
            discardJournal(for: session)
            phase = .idle
            snapshot = nil
            return activity
        } catch {
            // The journal is deliberately kept: the recording still exists on
            // disk and can be recovered on the next launch.
            phase = .failed("Could not save this activity. It will be offered for recovery next launch. \(error.localizedDescription)")
            return nil
        }
    }

    func discard() async {
        pumpTask?.cancel()
        await locationSource.stop()
        if let session { discardJournal(for: session) }
        session = nil
        pumpTask = nil
        snapshot = nil
        phase = .idle
    }

    /// Forces buffered fixes to disk — call when the app backgrounds, which is
    /// the moment before it is most likely to be killed.
    func flush() async {
        await session?.flushJournal(now: Date())
    }

    // MARK: - Recovery

    @discardableResult
    func restore(_ candidate: SessionRecovery.Candidate) -> Activity? {
        guard
            let first = candidate.route.points.first?.timestamp,
            let last = candidate.route.points.last?.timestamp
        else { return nil }

        let activity = try? repository.save(
            route: candidate.route, mode: candidate.mode, startedAt: first, endedAt: last
        )
        if activity != nil {
            SessionRecovery.discard(candidate)
            recoveryCandidates.removeAll { $0.url == candidate.url }
        }
        return activity
    }

    func dismiss(_ candidate: SessionRecovery.Candidate) {
        SessionRecovery.discard(candidate)
        recoveryCandidates.removeAll { $0.url == candidate.url }
    }

    // MARK: - Helpers

    private func discardJournal(for session: RecordingSession) {
        guard let journalDirectory else { return }
        let url = SessionRecovery.journalURL(for: session.id, in: journalDirectory)
        try? FileManager.default.removeItem(at: url)
    }

    private func describe(_ error: any Error) -> String {
        (error as? LocationSourceError)?.description ?? error.localizedDescription
    }
}
