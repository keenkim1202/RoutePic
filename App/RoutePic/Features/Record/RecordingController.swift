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

    /// What the person can do about a refusal. `DESIGN.md` §14.1 — a banner
    /// that only states the problem leaves the Settings app as the only way
    /// forward, and for reduced accuracy there is a way that stays in the app.
    enum Remedy: Equatable {
        case openSettings
        case askForPreciseLocation
    }

    private(set) var remedy: Remedy?

    private(set) var phase: Phase = .idle

    /// Why a recording ended without the person asking. Cleared once shown.
    var interruption: String?

    /// The location stream ended by itself. Read after `start` finishes too:
    /// it can end between the source starting and the phase becoming
    /// `.running`, and a run that is already over must not be shown as live.
    private var streamEnded = false
    /// Whether the interruption is already being dealt with. The pump and the
    /// tail of `start` can both reach it, and `finish()` holds the session
    /// across awaits — so twice means the same route saved twice.
    private var handlingInterruption = false
    /// Fixes that arrived before the session was recording. The first update
    /// both answers `start` and carries a position, so the pump can reach
    /// `handle` first — and `ingest` refuses an idle session, dropping exactly
    /// the beginning of the route.
    private var pendingFixes: [LocationFix] = []
    /// Low Power Mode throttles location updates, so the route comes back
    /// coarser than the mode asked for (`DESIGN.md` §14.1). Watched rather than
    /// read once: it can be switched on mid-run, and iOS gives no other sign.
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

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
        watchPowerState()
    }

    private func watchPowerState() {
        let changes = NotificationCenter.default.notifications(
            named: .NSProcessInfoPowerStateDidChange
        )
        Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }

    var isRecording: Bool { phase == .running || phase == .paused }

    // MARK: - Lifecycle

    func scanForRecovery() {
        guard let journalDirectory else { return }
        recoveryCandidates = SessionRecovery.candidates(in: journalDirectory)
            .filter { $0.isUsable }
    }

    func start(mode: RecordingMode) async {
        // `.starting` is not `isRecording`, so a second tap during the
        // permission prompt would build a whole second session: a new journal,
        // a `pumpTask` orphaning the first, and a second `updates()`.
        guard !isRecording, phase != .starting else { return }
        self.mode = mode
        // The last refusal's remedy does not survive the next attempt: coming
        // back from Settings with permission granted would otherwise still
        // offer the button that sent you there.
        remedy = nil
        streamEnded = false
        handlingInterruption = false
        pendingFixes = []
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
            // The stream ending on its own means the source gave up — a
            // permission revoked mid-run, or a session the system tore down.
            // Cancellation is the ordinary path and is not that.
            guard !Task.isCancelled else { return }
            await self?.locationStopped()
        }

        do {
            try await locationSource.start(mode: mode)
        } catch {
            pumpTask?.cancel()
            pumpTask = nil
            phase = .failed(describe(error))
            remedy = Self.remedy(for: error)
            self.session = nil
            return
        }

        await session.start(now: Date())
        // Drained before the phase opens, and drained until empty: a fix
        // arriving mid-drain joins the back of the queue instead of overtaking
        // it. Out of order, the filter chain rejects the older ones and the
        // beginning of the route goes with them.
        while !pendingFixes.isEmpty {
            await session.ingest(pendingFixes.removeFirst(), now: Date())
        }
        phase = .running
        snapshot = await session.snapshot()

        // The stream can finish while the lines above are still running, and
        // the pump's own report is discarded because the phase was `.starting`.
        if streamEnded { await reportInterruption() }
    }

    /// The source stopped delivering while a recording was still going.
    ///
    /// Saved rather than failed — the route so far is real. What must not
    /// happen is the screen going on showing a run nothing is recording.
    private func locationStopped() async {
        streamEnded = true
        await reportInterruption()
    }

    private func reportInterruption() async {
        guard isRecording, !handlingInterruption else { return }
        handlingInterruption = true

        let saved = await finish()
        // A failed save already puts its own message on screen, and that one
        // says the recording can be recovered — which this must not overwrite.
        if case .failed = phase { return }
        interruption = saved != nil
            ? """
                Location updates stopped, so this recording was saved where it \
                got to. Check that RoutePic still has permission and that \
                Precise Location is on.
                """
            : """
                Location updates stopped before anything was recorded, so there \
                was nothing to save. Check that RoutePic still has permission \
                and that Precise Location is on.
                """
    }

    private func handle(_ fix: LocationFix) async {
        guard let session else { return }
        guard phase != .starting else {
            pendingFixes.append(fix)
            return
        }
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
        pendingFixes = []
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

    private static func remedy(for error: any Error) -> Remedy? {
        switch error as? LocationSourceError {
        case .authorizationDenied: .openSettings
        case .reducedAccuracy: .askForPreciseLocation
        case .unavailable, .none: nil
        }
    }

    /// Asks inside the app instead of sending the person to Settings.
    /// `true` means the refusal is gone and starting is worth another try.
    func askForPreciseLocation() async -> Bool {
        guard await locationSource.requestTemporaryFullAccuracy() else {
            // iOS shows this prompt once a session. A second tap does nothing
            // and reads as a broken button, so the offer becomes the one that
            // still works.
            remedy = .openSettings
            return false
        }
        remedy = nil
        phase = .idle
        return true
    }

    private func describe(_ error: any Error) -> String {
        (error as? LocationSourceError)?.description ?? error.localizedDescription
    }
}
