import CoreLocation
import Foundation
import Testing
@testable import RouteKit

/// A flag a test can wait on without awaiting the thing it is testing — the
/// bugs here are ones that hang, and awaiting them stalls the suite instead of
/// failing it.
private final class Done: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// The stream itself needs a device and a walk (`PLAN.md` T-1). What is checked
/// here is the mapping either side of it — the part that decides whether the
/// two sources refuse a session for the same reasons.
@Suite("Modern location source mapping")
struct ModernLocationSourceTests {

    @Test("Driving asks for the navigation configuration, moving on foot does not")
    func configurationFollowsTheMode() {
        #expect(ModernLocationSource.configuration(for: .walk) == .fitness)
        #expect(ModernLocationSource.configuration(for: .run) == .fitness)
        #expect(ModernLocationSource.configuration(for: .drive) == .automotiveNavigation)
    }

    /// A refused permission has to read the same whichever source is running,
    /// or T-1 would be comparing error handling instead of location quality.
    @Test("A refusal maps to the same error the classic path throws")
    func refusalsMatchTheClassicPath() {
        #expect(
            ModernLocationSource.failure(for: CLError(.denied)) as? LocationSourceError
                == .authorizationDenied
        )
        guard case .unavailable = ModernLocationSource.failure(for: CLError(.locationUnknown))
            as? LocationSourceError
        else {
            Issue.record("a missing fix is not a permission problem")
            return
        }
    }

    /// A tunnel is not a reason to end someone's run. The pump retries this
    /// one, so it must never be turned into a terminal error.
    @Test("A momentary outage is not mapped to a failure")
    func transientOutageIsNotTerminal() {
        let mapped = ModernLocationSource.failure(for: CLError(.locationUnknown))
        #expect((mapped as? LocationSourceError) != .authorizationDenied)
        // Whatever it maps to, it must not read as a permission problem — that
        // is the one the recorder surfaces as "check your settings".
        guard case .unavailable = mapped as? LocationSourceError else {
            Issue.record("a lost fix should read as unavailable, not as a refusal")
            return
        }
    }

    @Test("An error that is not CoreLocation's passes through unchanged")
    func foreignErrorsAreNotRelabelled() {
        struct Odd: Error, Equatable {}
        #expect(ModernLocationSource.failure(for: Odd()) as? Odd == Odd())
    }

    /// `updates()` installs a stream before anything starts, and the protocol
    /// says updates finish when `stop()` is called. A teardown that only runs
    /// when a run exists leaves that consumer waiting for ever.
    @Test("Stopping finishes the stream even when nothing was started")
    func stopFinishesAnUnstartedStream() async throws {
        let source = ModernLocationSource()
        let stream = source.updates()
        let done = Done()
        let consumer = Task {
            for await _ in stream {}
            done.set()
        }

        await source.stop()

        for _ in 0..<40 where !done.isSet {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(done.isSet)
        consumer.cancel()
    }

    @Test("Stopping before starting is not an error")
    func stopWithoutStart() async {
        let source = ModernLocationSource()
        await source.stop()
    }

    /// `stop()` retires the attempt, so the pump's verdict is discarded. A
    /// `start` still waiting on it would wait for ever.
    @Test("Stopping while a start is waiting releases it")
    func stopReleasesAPendingStart() async throws {
        let source = ModernLocationSource()
        let done = Done()
        let started = Task {
            defer { done.set() }
            try await source.start(mode: .walk)
        }

        // Stopped repeatedly rather than once after a delay. A single stop
        // timed by a sleep can land before `start` has claimed its attempt, and
        // then it is stopping nothing while the real one waits on a device
        // verdict that never comes on a test runner.
        for _ in 0..<40 where !done.isSet {
            await source.stop()
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(done.isSet)
    }

}
