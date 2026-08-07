import Foundation

/// Tracks how many generations the user has left.
///
/// `DESIGN.md` §8.3 — the server is authoritative; this is the client's view,
/// kept so the UI can show a count and block obviously doomed requests before
/// spending a round trip. It never grants anything the server did not.
///
/// The reserve → commit → refund shape exists because a generation can fail
/// after the quota was taken. Decrementing on success alone lets a user fire
/// twenty concurrent requests against a quota of one.
public actor QuotaLedger {

    public struct State: Sendable, Equatable, Codable {
        public var allowance: Int
        public var used: Int
        public var reserved: Int
        public var periodStart: Date

        public var remaining: Int { max(0, allowance - used - reserved) }
        public var isExhausted: Bool { remaining <= 0 }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case exhausted(remaining: Int)
        case unknownReservation(String)

        public var description: String {
            switch self {
            case .exhausted:
                return "You have used this month's free pictures."
            case .unknownReservation(let key):
                return "No reservation found for \(key)."
            }
        }
    }

    private var state: State
    /// Reservation key → how many it holds. Keyed by idempotency key so a
    /// resend reuses its reservation rather than taking a second one.
    private var reservations: [String: Int] = [:]

    public init(allowance: Int, periodStart: Date) {
        self.state = State(allowance: allowance, used: 0, reserved: 0, periodStart: periodStart)
    }

    public func snapshot() -> State { state }

    /// Rolls the period over if a month has passed.
    public func refreshPeriod(now: Date, calendar: Calendar = .current) {
        guard !calendar.isDate(now, equalTo: state.periodStart, toGranularity: .month) else {
            return
        }
        state.used = 0
        state.periodStart = now
        // Reservations are deliberately kept: a job in flight across the period
        // boundary still has to be committed or refunded.
    }

    /// Takes `count` from the allowance and holds them.
    ///
    /// Reserving twice with the same key is a no-op, which is what makes a
    /// retried request safe.
    @discardableResult
    public func reserve(_ count: Int = 1, key: String, now: Date) throws -> State {
        refreshPeriod(now: now)
        if let existing = reservations[key] {
            _ = existing
            return state
        }
        guard state.remaining >= count else {
            throw Failure.exhausted(remaining: state.remaining)
        }
        reservations[key] = count
        state.reserved += count
        return state
    }

    /// Converts a reservation into usage — the generation succeeded.
    @discardableResult
    public func commit(key: String) throws -> State {
        guard let count = reservations.removeValue(forKey: key) else {
            throw Failure.unknownReservation(key)
        }
        state.reserved -= count
        state.used += count
        return state
    }

    /// Returns a reservation — the generation failed, was cancelled, or expired.
    @discardableResult
    public func refund(key: String) -> State {
        guard let count = reservations.removeValue(forKey: key) else { return state }
        state.reserved -= count
        return state
    }

    /// Applies whatever a job's terminal status implies.
    @discardableResult
    public func settle(_ job: GenerationJob) -> State {
        guard job.status.isTerminal else { return state }
        if job.status.refundsQuota {
            return refund(key: job.idempotencyKey)
        }
        return (try? commit(key: job.idempotencyKey)) ?? state
    }

    /// Sets the client's view from the server's, which is authoritative.
    public func adopt(allowance: Int, used: Int, periodStart: Date) {
        state.allowance = allowance
        state.used = used
        state.periodStart = periodStart
    }
}
