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

    /// Status only. `liveUpdates` prompts on its own and needs no delegate, but
    /// Precise Location has no diagnostic below iOS 18 and refusing it is part
    /// of the contract both sources share.
    private let manager = CLLocationManager()

    private let lock = NSLock()
    private var continuation: AsyncStream<LocationFix>.Continuation?
    /// Everyone waiting on the verdict. More than one because a second Start
    /// tap arrives while the first is still waiting for the prompt to close.
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    /// The first conclusive verdict, kept because it can land before anyone is
    /// waiting for it — the stream runs before `start` suspends.
    private var startResult: Result<Void, any Error>?
    /// Why the attempt ended, when it ended after a verdict had already been
    /// given. `settle` is a no-op by then, so without this a `start` waiting on
    /// a stream that has since died returns as though nothing happened.
    private var terminal: (any Error)?
    private var task: Task<Void, Never>?
    /// An attempt that has claimed the source but has no pump yet. Without it
    /// a `stop()` in that gap sees nothing to stop, and the pump then arrives
    /// carrying a generation already retired.
    private var isStarting = false
    /// Which attempt is current. A cancelled pump can still deliver one more
    /// update, and without this it would write its verdict over the next
    /// `start` — which then answers from an attempt that already failed.
    private var attempt = 0
    #if os(iOS)
    /// Tagged with the attempt that made it. An untagged one gets torn down by
    /// whichever attempt fails last, including the one that did not make it.
    private var session: (attempt: Int, value: CLBackgroundActivitySession)?
    #endif

    public init() {}

    public func updates() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    public func start(mode: RecordingMode) async throws {
        // A second caller joins the attempt already running rather than
        // reporting a started session. `RecordView` leaves Start enabled while
        // the first call is still waiting on the permission prompt.
        // One transaction, so a joiner leaves with the generation it actually
        // saw. Reading it again afterwards can pick up an idle generation a
        // `stop()` moved to in between, and then wait on a pump that is not there.
        let claim = lock.withLock { () -> (attempt: Int, isLead: Bool) in
            guard task == nil, !isStarting else { return (self.attempt, false) }
            self.attempt += 1
            isStarting = true
            startResult = nil
            terminal = nil
            return (self.attempt, true)
        }
        guard claim.isLead else {
            try await verdict(attempt: claim.attempt)
            return
        }
        let attempt = claim.attempt

        #if os(iOS)
        // Without a session the stream stops at the first suspension, which is
        // most of a recorded run (`DESIGN.md` §5.1).
        var mine = CLBackgroundActivitySession()
        // Only if this attempt still owns the source. Storing it blind would
        // overwrite a newer attempt's session, and the cleanup below would then
        // clear the entry while that attempt reports a successful start with no
        // background delivery behind it.
        lock.withLock { if attempt == self.attempt { session = (attempt, mine) } }
        #endif

        let configuration = Self.configuration(for: mode)
        let pump = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(configuration) {
                        self?.receive(update, attempt: attempt)
                    }
                    // The sequence ending on its own is not a stop this object
                    // asked for, so a `start` still waiting has to be told.
                    self?.conclude(
                        LocationSourceError.unavailable("the location stream ended"),
                        attempt: attempt
                    )
                    break
                } catch let error as CLError where error.code == .locationUnknown {
                    // A tunnel, not a failure. `ClassicLocationSource` ignores
                    // this for the same reason: Core Location recovers, and
                    // ending someone's run over a momentary outage is worse
                    // than waiting. Paced so a persistent one does not spin.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    // The wait is a suspension like any other: the attempt can
                    // be retired while it runs.
                    guard self?.isCurrent(attempt) == true else { break }
                } catch {
                    self?.conclude(Self.failure(for: error), attempt: attempt)
                    break
                }
            }
            self?.retire(attempt: attempt)
        }
        // A `stop()` between claiming the attempt and here has already retired
        // this generation; installing the pump anyway would leave every one of
        // its verdicts rejected and this call waiting for ever.
        let live = lock.withLock { () -> Bool in
            // The guard comes first. A stale attempt clearing the flag would
            // release the reservation a live one is holding, and that one then
            // gets cancelled as stale by whoever claims the source next.
            guard attempt == self.attempt else { return false }
            isStarting = false
            self.task = pump
            return true
        }
        guard live else {
            pump.cancel()
            #if os(iOS)
            // Only this attempt's session. The stored one may belong to an
            // attempt that started after the `stop()` retired this one, and
            // killing that leaves it running with no background delivery.
            lock.withLock { if session?.attempt == attempt { session = nil } }
            mine.invalidate()
            #endif
            throw CancellationError()
        }

        do {
            try await verdict(attempt: attempt)
        } catch {
            // Leaving the pump and the session installed would make the next
            // Start return successfully on the strength of a dead attempt —
            // but only if this attempt still owns them.
            await teardown(onlyAttempt: attempt)
            throw error
        }
    }

    public func stop() async {
        await teardown(onlyAttempt: nil)
    }

    /// Stops whatever is current, or nothing at all when `onlyAttempt` names an
    /// attempt that has already been retired.
    ///
    /// The check lives inside the same lock as the capture. A caller that tests
    /// first and then stops has a window in which a newer attempt takes over,
    /// and stops that one instead.
    private func teardown(onlyAttempt: Int?) async {
        // Everything this generation owns comes out under one lock. Retiring
        // afterwards would reach a `start` that began in the meantime and clear
        // its stream and session out from under it.
        let stopped = lock.withLock { () -> Stopped? in
            if let onlyAttempt, onlyAttempt != self.attempt { return nil }
            defer {
                // A new generation, so anything the cancelled pump still
                // delivers is ignored rather than answering the next start.
                self.attempt += 1
                self.isStarting = false
                self.task = nil
                self.startResult = nil
                self.waiters = []
                self.continuation = nil
                #if os(iOS)
                self.session = nil
                #endif
            }
            #if os(iOS)
            return Stopped(task: task, waiters: waiters, stream: continuation, session: session?.value)
            #else
            return Stopped(task: task, waiters: waiters, stream: continuation)
            #endif
        }
        guard let stopped else { return }

        stopped.task?.cancel()
        // The pump's verdict is now ignored, so anyone still waiting for one
        // would wait for ever.
        for waiter in stopped.waiters { waiter.resume(throwing: CancellationError()) }
        stopped.stream?.finish()
        #if os(iOS)
        stopped.session?.invalidate()
        #endif
    }

    private struct Stopped {
        var task: Task<Void, Never>?
        var waiters: [CheckedContinuation<Void, any Error>]
        var stream: AsyncStream<LocationFix>.Continuation?
        #if os(iOS)
        var session: CLBackgroundActivitySession?
        #endif
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

    /// Whether `attempt` is still the live one.
    ///
    /// Every race this type has had was the same shape: an attempt that
    /// `stop()` already retired going on to mutate state a newer attempt now
    /// owns — its pump, its stream, its background session. Nothing here
    /// touches shared state without asking this first.
    private func isCurrent(_ attempt: Int) -> Bool {
        lock.withLock { attempt == self.attempt }
    }

    // MARK: - Updates

    private func receive(_ update: CLLocationUpdate, attempt: Int) {
        // A pump whose attempt is gone has nothing to say about the one that
        // replaced it. The locked reads below check again, because the
        // generation can move between here and them.
        guard isCurrent(attempt) else { return }

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
            let started = lock.withLock { attempt == self.attempt && startResult != nil }
            conclude(error, attempt: attempt)
            if started { retire(attempt: attempt) }
            return
        case .usable:
            settle(.success(()), attempt: attempt)
        }

        guard let location = update.location else { return }
        // On a quick stop and restart, a fix from the old run would otherwise
        // become the first point of the new one.
        let continuation = lock.withLock { () -> AsyncStream<LocationFix>.Continuation? in
            guard attempt == self.attempt else { return nil }
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
    private func verdict(attempt: Int) async throws {
        try await firstUpdate(attempt: attempt)
        // A `stop()` or a dead pump landing while this was suspended took the
        // waiter with it, so the resume above says nothing about whether the
        // attempt survived. Returning success would start a recording with
        // nothing behind it.
        // Both reads in one transaction: split, a new `start` can clear the
        // reason in between and this reports a bare cancellation instead of
        // saying what actually ended the attempt.
        let ended = lock.withLock { () -> (any Error)? in
            attempt == self.attempt ? nil : (terminal ?? CancellationError())
        }
        if let ended { throw ended }
        // Below iOS 18 no update carries this, and Reduced Accuracy is an
        // *authorized* mode — the stream would hand over approximate fixes
        // rather than throw, which the classic source refuses outright.
        guard manager.accuracyAuthorization == .fullAccuracy else {
            throw LocationSourceError.reducedAccuracy
        }
    }

    /// Waits for the verdict, or takes it if it has already arrived.
    private func firstUpdate(attempt: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let settled = lock.withLock { () -> Result<Void, any Error>? in
                // A `stop()` can land between the pump being installed and this
                // line. It captured no waiter, so appending one now would leave
                // it with no pump left that could ever answer it.
                guard attempt == self.attempt else { return .failure(CancellationError()) }
                if let startResult { return startResult }
                waiters.append(continuation)
                return nil
            }
            if let settled { continuation.resume(with: settled) }
        }
    }

    /// Records why this attempt is over, then answers anyone still waiting.
    /// The reason outlives `settle`, which does nothing once a verdict is in.
    private func conclude(_ error: any Error, attempt: Int) {
        lock.withLock { if attempt == self.attempt { terminal = error } }
        settle(.failure(error), attempt: attempt)
    }

    /// Answers everyone waiting, exactly once. Every later update carries the
    /// same flags, and resuming a continuation twice is a crash.
    private func settle(_ result: Result<Void, any Error>, attempt: Int) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            guard attempt == self.attempt, startResult == nil else { return [] }
            startResult = result
            defer { self.waiters = [] }
            return self.waiters
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    /// Drops the machinery without discarding the verdict a waiting `start`
    /// has not read yet.
    private func retire(attempt: Int) {
        let retired = lock.withLock { () -> Stopped? in
            guard attempt == self.attempt else { return nil }
            defer {
                // A retired attempt is finished, so its generation has to go
                // stale too — otherwise `isCurrent` keeps saying yes for a
                // source that has already stopped.
                self.attempt += 1
                // And the reservation goes with it. A pump that dies before
                // `start` installs it would otherwise leave the flag set, and
                // every later `start` joins an attempt that does not exist.
                self.isStarting = false
                self.task = nil
                self.continuation = nil
                self.waiters = []
                #if os(iOS)
                self.session?.value.invalidate()
                self.session = nil
                #endif
            }
            #if os(iOS)
            return Stopped(task: task, waiters: waiters, stream: continuation, session: nil)
            #else
            return Stopped(task: task, waiters: waiters, stream: continuation)
            #endif
        }
        guard let retired else { return }

        // Cancelled, not just dropped. A refusal after start retires from
        // inside `receive`, and letting go of the handle there would leave
        // `liveUpdates` looping with nothing left that can stop it.
        retired.task?.cancel()
        // `conclude` normally answers these first. Anyone still here would
        // otherwise wait on a pump that no longer exists.
        let reason: any Error = lock.withLock { terminal } ?? CancellationError()
        for waiter in retired.waiters { waiter.resume(throwing: reason) }
        retired.stream?.finish()
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

    /// Reads an update's diagnostics, so both sources reject for the same reasons.
    ///
    /// **The flags are iOS 18, not 17.** Below that an update says nothing and a
    /// refusal arrives only as a thrown `CLError` — hence the Precise Location
    /// check in `start`, and a mark against this arm for T-1.
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
