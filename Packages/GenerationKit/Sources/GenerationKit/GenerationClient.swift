import Foundation
import ShapeKit

/// Talks to the proxy. Abstracted so the policy above it is testable without a
/// network, an API key, or money.
public protocol GenerationTransport: Sendable {
    /// Whether running this transport costs the user's allowance.
    ///
    /// On-device generation spends battery, not money, so quota must not be
    /// reserved against it — a metered ledger on a free path would refuse
    /// generations for no reason and make the free tier look broken.
    var isMetered: Bool { get }

    func submit(_ request: GenerationRequest) async throws -> GenerationJob
    func poll(jobID: String) async throws -> GenerationJob
    func cancel(jobID: String) async throws
    func download(_ url: URL) async throws -> Data
}

extension GenerationTransport {
    /// Metered by default: a transport that costs nothing has to say so
    /// explicitly, so the safe assumption is the one that protects the budget.
    public var isMetered: Bool { true }
}

/// What the app should do with a route right now.
public enum GenerationAvailability: Sendable, Equatable {
    case available(remaining: Int)
    /// `DESIGN.md` §4.4 — a near-straight or very short route is blocked before
    /// any money is spent, because there is nothing to interpret.
    case routeUnsuitable(reason: String)
    case quotaExhausted
    case offline

    public var canGenerate: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Runs a generation to completion and keeps the quota honest.
///
/// `DESIGN.md` §4.4 sets the rule this enforces: generation is additive. Every
/// failure path here ends with the caller able to fall back to a locally
/// rendered card, and with the user's quota returned.
public actor GenerationClient {

    public struct PollingPolicy: Sendable {
        /// Backoff in seconds — `DESIGN.md` §8.3.
        public var intervals: [TimeInterval]
        public var timeout: TimeInterval

        public init(
            intervals: [TimeInterval] = [2, 2, 5, 5, 10],
            timeout: TimeInterval = GenerationJob.expiry
        ) {
            self.intervals = intervals
            self.timeout = timeout
        }

        public func interval(forAttempt attempt: Int) -> TimeInterval {
            intervals[min(attempt, intervals.count - 1)]
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case quota(QuotaLedger.Failure)
        case routeUnsuitable(String)
        case jobFailed(String)
        case cancelled
        case expired
        case transport(String)

        public var description: String {
            switch self {
            case .quota(let failure): failure.description
            case .routeUnsuitable(let reason): reason
            case .jobFailed(let reason): "Generation failed: \(reason)"
            case .cancelled: "Generation was cancelled."
            case .expired: "Generation took too long and was abandoned."
            case .transport(let detail): "Could not reach the picture service: \(detail)"
            }
        }

        /// Whether a locally rendered card should be offered instead.
        /// Everything except an unsuitable route, which has nothing to draw.
        public var suggestsLocalFallback: Bool {
            if case .routeUnsuitable = self { return false }
            return true
        }
    }

    private let transport: any GenerationTransport
    private let quota: QuotaLedger
    private let policy: PollingPolicy
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        transport: any GenerationTransport,
        quota: QuotaLedger,
        policy: PollingPolicy = PollingPolicy(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.transport = transport
        self.quota = quota
        self.policy = policy
        self.sleep = sleep
    }

    /// Whether it is worth starting at all.
    public func availability(
        for fingerprint: ShapeFingerprint,
        lengthMeters: Double,
        isOnline: Bool = true
    ) async -> GenerationAvailability {
        if fingerprint.isDegenerate {
            return .routeUnsuitable(
                reason: "This route is almost a straight line, so there is no shape to work with."
            )
        }
        if lengthMeters < RouteTrimmer.minimumShareableLength {
            return .routeUnsuitable(
                reason: "This route is too short to make a picture from."
            )
        }
        // An unmetered transport has no allowance to exhaust, and works
        // offline — the two remaining reasons to refuse do not apply.
        guard transport.isMetered else { return .available(remaining: .max) }
        guard isOnline else { return .offline }

        let state = await quota.snapshot()
        return state.isExhausted ? .quotaExhausted : .available(remaining: state.remaining)
    }

    /// Submits, polls until terminal, and settles the quota either way.
    public func generate(
        _ request: GenerationRequest,
        now: @Sendable @escaping () -> Date = Date.init
    ) async throws -> [GeneratedCandidate] {
        let metered = transport.isMetered
        if metered {
            do {
                try await quota.reserve(1, key: request.idempotencyKey, now: now())
            } catch let failure as QuotaLedger.Failure {
                throw Failure.quota(failure)
            }
        }

        var job: GenerationJob
        do {
            job = try await transport.submit(request)
        } catch {
            // Nothing was started, so the reservation goes straight back.
            if metered { await quota.refund(key: request.idempotencyKey) }
            throw Failure.transport(error.localizedDescription)
        }

        // Elapsed time is measured from this client's own submission, not from
        // the server's `createdAt`. Comparing two clocks would abandon healthy
        // jobs whenever the device's time differs from the server's.
        let startedAt = now()
        var attempt = 0
        while !job.status.isTerminal {
            if now().timeIntervalSince(startedAt) >= policy.timeout {
                if metered { await quota.refund(key: request.idempotencyKey) }
                try? await transport.cancel(jobID: job.id)
                throw Failure.expired
            }
            do {
                try await sleep(policy.interval(forAttempt: attempt))
                job = try await transport.poll(jobID: job.id)
            } catch is CancellationError {
                if metered { await quota.refund(key: request.idempotencyKey) }
                try? await transport.cancel(jobID: job.id)
                throw Failure.cancelled
            } catch {
                if metered { await quota.refund(key: request.idempotencyKey) }
                throw Failure.transport(error.localizedDescription)
            }
            attempt += 1
        }

        // Settling happens *after* the result is judged, not before. Committing
        // first and refunding afterwards does nothing: the reservation is
        // already gone, so the refund finds no key and the user pays for an
        // empty result.
        switch job.status {
        case .succeeded where job.candidates.isEmpty:
            if metered { await quota.refund(key: request.idempotencyKey) }
            throw Failure.jobFailed("The service returned no images.")

        case .succeeded:
            if metered { await quota.settle(job) }
            return job.candidates

        case .cancelled:
            if metered { await quota.settle(job) }
            throw Failure.cancelled

        case .expired:
            if metered { await quota.settle(job) }
            throw Failure.expired

        default:
            if metered { await quota.settle(job) }
            throw Failure.jobFailed(job.failureReason ?? "unknown")
        }
    }

    public func fetchImage(_ candidate: GeneratedCandidate) async throws -> Data {
        do {
            return try await transport.download(candidate.imageURL)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    public func quotaState() async -> QuotaLedger.State {
        await quota.snapshot()
    }
}
