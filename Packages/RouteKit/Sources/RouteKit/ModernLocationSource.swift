import CoreLocation
import Foundation

/// The `CLLocationUpdate` path — the other half of OQ-D.
///
/// `PLAN.md` §M2-B put two implementations behind `LocationSource` so T-1 only
/// has to pick a default. Only the classic one existed.
///
/// The API shape is the difference: no delegate and no authorization request —
/// permission arrives as flags on an update, so `start` waits for one.
public final class ModernLocationSource: LocationSource, @unchecked Sendable {

    /// Everything one `start` owns.
    ///
    /// One object rather than eight fields. Every race this type has had was a
    /// retired attempt touching state a newer one owned, and each fix was one
    /// more guard at one more site. Held together, "is this still mine?" is
    /// `run === mine`, and letting go of it lets go of all of it at once —
    /// there is no separate flag left to forget.
    private final class Run: @unchecked Sendable {
        var task: Task<Void, Never>?
        var waiters: [CheckedContinuation<Void, any Error>] = []
        var result: Result<Void, any Error>?
        /// Why it ended, when it ended after a verdict was already given.
        /// `settle` is a no-op by then, so without this a `start` waiting on a
        /// stream that has since died returns as though nothing happened.
        var terminal: (any Error)?
        #if os(iOS)
        var session: CLBackgroundActivitySession?
        #endif
    }

    /// Status only. `liveUpdates` prompts on its own and needs no delegate, but
    /// Precise Location has no diagnostic below iOS 18 and refusing it is part
    /// of the contract both sources share.
    private let manager = CLLocationManager()

    private let lock = NSLock()
    /// Installed by `updates()` before any run starts, so it outlives them.
    private var continuation: AsyncStream<LocationFix>.Continuation?
    private var run: Run?

    public init() {}

    public func updates() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    public func start(mode: RecordingMode) async throws {
        // One transaction. A second caller joins the run already going rather
        // than reporting a started session — `RecordView` leaves Start enabled
        // while the first call waits on the permission prompt.
        let (run, isLead) = lock.withLock { () -> (Run, Bool) in
            if let existing = self.run { return (existing, false) }
            let fresh = Run()
            self.run = fresh
            return (fresh, true)
        }
        guard isLead else {
            try await verdict(run)
            return
        }

        #if os(iOS)
        // Without a session the stream stops at the first suspension, which is
        // most of a recorded run (`DESIGN.md` §5.1). Once handed over, `retire`
        // owns it; if the run was dropped first, nobody else will.
        var mine = CLBackgroundActivitySession()
        let handedOver = lock.withLock { () -> Bool in
            guard self.run === run else { return false }
            run.session = mine
            return true
        }
        if !handedOver { mine.invalidate() }
        #endif

        let configuration = Self.configuration(for: mode)
        let pump = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(configuration) {
                        self?.receive(update, run: run)
                    }
                    // The sequence ending on its own is not a stop this object
                    // asked for, so a `start` still waiting has to be told.
                    self?.conclude(
                        LocationSourceError.unavailable("the location stream ended"), run: run
                    )
                    break
                } catch let error as CLError where error.code == .locationUnknown {
                    // A tunnel, not a failure. `ClassicLocationSource` ignores
                    // this for the same reason: Core Location recovers, and
                    // ending someone's run over a momentary outage is worse
                    // than waiting. Paced so a persistent one does not spin.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard self?.isCurrent(run) == true else { break }
                } catch {
                    self?.conclude(Self.failure(for: error), run: run)
                    break
                }
            }
            self?.retire(run)
        }

        // A `stop()` between claiming the run and here has already dropped it;
        // installing the pump anyway would leave every verdict it produces
        // rejected and this call waiting for ever.
        let live = lock.withLock { () -> Bool in
            guard self.run === run else { return false }
            run.task = pump
            return true
        }
        guard live else {
            // The run is already gone, so whoever dropped it invalidated the
            // session with it. Invalidating again here would do it twice.
            pump.cancel()
            throw CancellationError()
        }

        do {
            try await verdict(run)
        } catch {
            // Only this run. A newer one may already own the source.
            retire(run)
            throw error
        }
    }

    public func stop() async {
        retire(nil)
    }

    /// Lets go of the live run — or of nothing, when `expected` names one that
    /// has already been dropped — and releases everything it holds.
    ///
    /// The only teardown path there is. The run and the stream come out in one
    /// transaction: detaching them separately lets a new subscription install
    /// its continuation in the gap, and this then finishes the new one.
    ///
    /// An unscoped `stop()` runs even with no live run. `updates()` installs a
    /// stream before anything starts, and its consumer is waiting either way —
    /// the protocol says updates finish when `stop()` is called.
    private func retire(_ expected: Run?) {
        let detached = lock.withLock { () -> (Run?, AsyncStream<LocationFix>.Continuation?)? in
            if let expected, self.run !== expected { return nil }
            defer {
                self.run = nil
                self.continuation = nil
            }
            return (self.run, self.continuation)
        }
        guard let (run, stream) = detached else { return }

        // Nothing else can reach the run now: every other path guards on
        // `self.run === run` under the lock, and that is no longer true.
        if let run {
            // Cleared as well as cancelled: the pump's closure holds the run,
            // and the run holds the pump.
            run.task?.cancel()
            run.task = nil
            let reason = run.terminal ?? CancellationError()
            for waiter in run.waiters { waiter.resume(throwing: reason) }
            run.waiters = []
            #if os(iOS)
            run.session?.invalidate()
            run.session = nil
            #endif
        }
        stream?.finish()
    }

    private func isCurrent(_ run: Run) -> Bool {
        lock.withLock { self.run === run }
    }

    // MARK: - Updates

    private func receive(_ update: CLLocationUpdate, run: Run) {
        // A pump whose run is gone has nothing to say about the one that
        // replaced it. The locked reads below check again, because the run can
        // be dropped between here and them.
        guard isCurrent(run) else { return }

        switch effectiveVerdict(for: update) {
        case .undecided:
            // The system prompt is still open. Answering now would report a
            // running session that the person is about to refuse.
            return
        case .refused(let error):
            // After the first verdict `settle` is a no-op, so a permission
            // revoked mid-run would only drop updates and leave the recorder
            // showing a run nothing is recording. Ending the stream is the
            // strongest signal this protocol has.
            let started = lock.withLock { self.run === run && run.result != nil }
            conclude(error, run: run)
            if started { retire(run) }
            return
        case .usable:
            settle(.success(()), run: run)
        }

        guard let location = update.location else { return }
        // On a quick stop and restart, a fix from the old run would otherwise
        // become the first point of the new one.
        let continuation = lock.withLock { () -> AsyncStream<LocationFix>.Continuation? in
            guard self.run === run else { return nil }
            return self.continuation
        }
        continuation?.yield(
            LocationFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.altitude,
                timestamp: location.timestamp,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy,
                speed: location.speed
            )
        )
    }

    /// Waits for the first conclusive update, then for what no update reports.
    private func verdict(_ run: Run) async throws {
        try await firstUpdate(run)
        // Reduced Accuracy is an *authorized* mode: the stream hands over
        // approximate fixes rather than throwing, which the classic source
        // refuses outright. `receive` keeps checking for the rest of the run.
        if let refusal = accuracyRefusal() { throw refusal }
        // A `stop()`, or a pump that died, landing while this was suspended
        // took the waiter with it — so the resume above says nothing about
        // whether the run survived. Returning success would start a recording
        // with nothing behind it.
        let ended = lock.withLock { () -> (any Error)? in
            self.run === run ? nil : (run.terminal ?? CancellationError())
        }
        if let ended { throw ended }
    }

    /// Waits for the verdict, or takes it if it has already arrived.
    private func firstUpdate(_ run: Run) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let settled = lock.withLock { () -> Result<Void, any Error>? in
                guard self.run === run else {
                    return .failure(run.terminal ?? CancellationError())
                }
                if let result = run.result { return result }
                run.waiters.append(continuation)
                return nil
            }
            if let settled { continuation.resume(with: settled) }
        }
    }

    /// Records why this run is over, then answers anyone still waiting. The
    /// reason outlives `settle`, which does nothing once a verdict is in.
    private func conclude(_ error: any Error, run: Run) {
        lock.withLock { if self.run === run { run.terminal = error } }
        settle(.failure(error), run: run)
    }

    /// Answers everyone waiting, exactly once. Every later update carries the
    /// same flags, and resuming a continuation twice is a crash.
    private func settle(_ result: Result<Void, any Error>, run: Run) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            guard self.run === run, run.result == nil else { return [] }
            run.result = result
            defer { run.waiters = [] }
            return run.waiters
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    // MARK: - Mapping

    enum Verdict: Equatable {
        /// Nothing decided yet — an authorization prompt is open.
        case undecided
        case usable
        case refused(LocationSourceError)
    }

    static func configuration(for mode: RecordingMode) -> CLLocationUpdate.LiveConfiguration {
        switch mode {
        case .walk, .run: .fitness
        case .drive: .automotiveNavigation
        }
    }

    /// The update's own verdict, plus what no update reports below iOS 18.
    private func effectiveVerdict(for update: CLLocationUpdate) -> Verdict {
        let verdict = Self.verdict(for: update)
        guard case .usable = verdict, let refusal = accuracyRefusal() else { return verdict }
        return .refused(refusal)
    }

    /// Precise Location, read per update on systems whose updates do not carry
    /// it. Someone can turn it off mid-run, and approximate fixes recorded as
    /// though they were precise are worse than a recording that stops.
    private func accuracyRefusal() -> LocationSourceError? {
        if #available(iOS 18.0, macOS 15.0, *) { return nil }
        return manager.accuracyAuthorization == .fullAccuracy ? nil : .reducedAccuracy
    }

    /// Reads an update's diagnostics, so both sources reject for the same reasons.
    ///
    /// **The flags are iOS 18, not 17.** Below that an update says nothing and a
    /// refusal arrives only by throwing — hence the Precise Location check
    /// above, and a mark against this arm for T-1.
    static func verdict(for update: CLLocationUpdate) -> Verdict {
        guard #available(iOS 18.0, macOS 15.0, *) else { return .usable }
        if update.authorizationRequestInProgress { return .undecided }
        if update.authorizationDenied || update.authorizationDeniedGlobally
            || update.authorizationRestricted {
            return .refused(.authorizationDenied)
        }
        if update.accuracyLimited { return .refused(.reducedAccuracy) }
        // Not a refusal — the app is not in a state that earns updates yet.
        if update.insufficientlyInUse {
            return .refused(.unavailable("the app is not in use, so location updates are withheld"))
        }
        return .usable
    }

    /// What the stream throws when it will not run at all. `.locationUnknown`
    /// is not here on purpose — the pump retries it rather than ending the run.
    static func failure(for error: any Error) -> any Error {
        guard let error = error as? CLError else { return error }
        switch error.code {
        case .denied: return LocationSourceError.authorizationDenied
        default: return LocationSourceError.unavailable(error.localizedDescription)
        }
    }
}
