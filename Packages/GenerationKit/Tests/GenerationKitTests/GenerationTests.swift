import Foundation
import ShapeKit
import Testing
@testable import GenerationKit

private let epoch = Date(timeIntervalSince1970: 1_780_000_000)

private func fingerprint(degenerate: Bool = false) -> ShapeFingerprint {
    ShapeFingerprint(
        closureRatio: 0.4,
        aspectRatio: 1.2,
        tortuosity: degenerate ? 1.02 : 3.5,
        meanAbsoluteTurn: 0.3,
        turnVariance: 0.1,
        turnSkewness: 0,
        occupancyFillRatio: 0.1,
        protrusionCount: 3,
        selfIntersectionCount: 1,
        convexRatio: nil
    )
}

private func request(key: String = "key-1") -> GenerationRequest {
    GenerationRequest(
        orientationImages: Array(repeating: Data([0x89, 0x50]), count: 16),
        fingerprint: fingerprint(),
        stylePreset: "flat-vector",
        conditionMode: "centreline",
        controlStrength: 0.65,
        idempotencyKey: key
    )
}

/// Scripted transport: each poll returns the next status in the list.
private actor ScriptedTransport: GenerationTransport {
    var statuses: [GenerationJob.Status]
    var candidates: [GeneratedCandidate]
    var submitError: (any Error)?
    var pollError: (any Error)?
    private(set) var submitCount = 0
    private(set) var cancelCount = 0
    private var index = 0

    init(
        statuses: [GenerationJob.Status],
        candidates: [GeneratedCandidate] = [],
        submitError: (any Error)? = nil,
        pollError: (any Error)? = nil
    ) {
        self.statuses = statuses
        self.candidates = candidates
        self.submitError = submitError
        self.pollError = pollError
    }

    func submit(_ request: GenerationRequest) async throws -> GenerationJob {
        submitCount += 1
        if let submitError { throw submitError }
        return GenerationJob(
            id: "job-1", idempotencyKey: request.idempotencyKey,
            status: .queued, createdAt: epoch, updatedAt: epoch
        )
    }

    func poll(jobID: String) async throws -> GenerationJob {
        if let pollError { throw pollError }
        let status = statuses[min(index, statuses.count - 1)]
        index += 1
        return GenerationJob(
            id: jobID, idempotencyKey: "key-1", status: status,
            createdAt: epoch, updatedAt: epoch,
            candidates: status == .succeeded ? candidates : [],
            failureReason: status == .failed ? "provider outage" : nil
        )
    }

    func cancel(jobID: String) async throws { cancelCount += 1 }
    func download(_ url: URL) async throws -> Data { Data([1, 2, 3]) }
}

private func candidate() -> GeneratedCandidate {
    GeneratedCandidate(
        imageURL: URL(string: "https://example.invalid/a.png")!,
        subject: "웅크린 여우", why: "닫힌 곡선", seed: 7,
        controlStrength: 0.65, renderIndex: 5, costCents: 4
    )
}

private func makeClient(
    _ transport: ScriptedTransport, allowance: Int = 5
) -> (GenerationClient, QuotaLedger) {
    let quota = QuotaLedger(allowance: allowance, periodStart: epoch)
    let client = GenerationClient(
        transport: transport,
        quota: quota,
        policy: .init(intervals: [0], timeout: 600),
        sleep: { _ in }              // tests never wait
    )
    return (client, quota)
}

@Suite("QuotaLedger")
struct QuotaLedgerTests {

    @Test("Reserve holds against the allowance without spending it")
    func reserveHolds() async throws {
        let ledger = QuotaLedger(allowance: 3, periodStart: epoch)
        try await ledger.reserve(key: "a", now: epoch)

        let state = await ledger.snapshot()
        #expect(state.reserved == 1)
        #expect(state.used == 0)
        #expect(state.remaining == 2)
    }

    @Test("Reserving twice with the same key takes nothing extra")
    func reserveIsIdempotent() async throws {
        // DESIGN.md §8.3 — a resend after a dropped response must not charge twice.
        let ledger = QuotaLedger(allowance: 3, periodStart: epoch)
        try await ledger.reserve(key: "a", now: epoch)
        try await ledger.reserve(key: "a", now: epoch)
        #expect(await ledger.snapshot().reserved == 1)
    }

    @Test("Concurrent requests cannot overdraw the allowance")
    func cannotOverdraw() async throws {
        // Without reservations, ten parallel requests all see "1 remaining".
        let ledger = QuotaLedger(allowance: 1, periodStart: epoch)
        try await ledger.reserve(key: "a", now: epoch)

        await #expect(throws: QuotaLedger.Failure.self) {
            try await ledger.reserve(key: "b", now: epoch)
        }
    }

    @Test("Commit turns a reservation into usage")
    func commit() async throws {
        let ledger = QuotaLedger(allowance: 3, periodStart: epoch)
        try await ledger.reserve(key: "a", now: epoch)
        try await ledger.commit(key: "a")

        let state = await ledger.snapshot()
        #expect(state.used == 1)
        #expect(state.reserved == 0)
        #expect(state.remaining == 2)
    }

    @Test("Refund returns a reservation")
    func refund() async throws {
        let ledger = QuotaLedger(allowance: 3, periodStart: epoch)
        try await ledger.reserve(key: "a", now: epoch)
        await ledger.refund(key: "a")

        let state = await ledger.snapshot()
        #expect(state.used == 0)
        #expect(state.remaining == 3)
    }

    @Test("Refunding an unknown key is harmless")
    func refundUnknown() async {
        let ledger = QuotaLedger(allowance: 3, periodStart: epoch)
        #expect(await ledger.refund(key: "nope").remaining == 3)
    }

    @Test("Every non-success terminal status refunds")
    func settleByStatus() async throws {
        for status in [GenerationJob.Status.failed, .cancelled, .expired] {
            let ledger = QuotaLedger(allowance: 3, periodStart: epoch)
            try await ledger.reserve(key: "a", now: epoch)
            let job = GenerationJob(
                id: "j", idempotencyKey: "a", status: status,
                createdAt: epoch, updatedAt: epoch
            )
            #expect(await ledger.settle(job).used == 0, "\(status) should refund")
        }
    }

    @Test("A new month resets usage but keeps reservations in flight")
    func periodRollover() async throws {
        let ledger = QuotaLedger(allowance: 2, periodStart: epoch)
        try await ledger.reserve(key: "a", now: epoch)
        try await ledger.commit(key: "a")
        try await ledger.reserve(key: "b", now: epoch)

        let nextMonth = epoch.addingTimeInterval(40 * 86_400)
        await ledger.refreshPeriod(now: nextMonth)

        let state = await ledger.snapshot()
        #expect(state.used == 0)
        #expect(state.reserved == 1)      // job "b" is still running

        // And it can still be settled after the rollover.
        try await ledger.commit(key: "b")
        #expect(await ledger.snapshot().used == 1)
    }

    @Test("The server's numbers win")
    func adoptServerState() async {
        let ledger = QuotaLedger(allowance: 5, periodStart: epoch)
        await ledger.adopt(allowance: 3, used: 3, periodStart: epoch)
        #expect(await ledger.snapshot().isExhausted)
    }
}

@Suite("GenerationClient")
struct GenerationClientTests {

    @Test("A successful job returns candidates and spends one generation")
    func success() async throws {
        let transport = ScriptedTransport(statuses: [.running, .succeeded], candidates: [candidate()])
        let (client, quota) = makeClient(transport)

        let result = try await client.generate(request())
        #expect(result.count == 1)

        let state = await quota.snapshot()
        #expect(state.used == 1)
        #expect(state.reserved == 0)
    }

    @Test("A failed job refunds the quota")
    func failureRefunds() async {
        // DESIGN.md §8.3 — the user must not pay for a picture they never got.
        let transport = ScriptedTransport(statuses: [.running, .failed])
        let (client, quota) = makeClient(transport)

        await #expect(throws: GenerationClient.Failure.self) {
            try await client.generate(request())
        }
        let state = await quota.snapshot()
        #expect(state.used == 0)
        #expect(state.remaining == 5)
    }

    @Test("Success with no images refunds rather than charging for nothing")
    func emptySuccessRefunds() async {
        let transport = ScriptedTransport(statuses: [.succeeded], candidates: [])
        let (client, quota) = makeClient(transport)

        await #expect(throws: GenerationClient.Failure.self) {
            try await client.generate(request())
        }
        #expect(await quota.snapshot().used == 0)
    }

    @Test("A submit failure refunds without starting anything")
    func submitFailureRefunds() async {
        let transport = ScriptedTransport(
            statuses: [.queued], submitError: URLError(.notConnectedToInternet)
        )
        let (client, quota) = makeClient(transport)

        await #expect(throws: GenerationClient.Failure.self) {
            try await client.generate(request())
        }
        #expect(await quota.snapshot().remaining == 5)
    }

    @Test("A polling failure refunds")
    func pollFailureRefunds() async {
        let transport = ScriptedTransport(
            statuses: [.running], pollError: URLError(.timedOut)
        )
        let (client, quota) = makeClient(transport)

        await #expect(throws: GenerationClient.Failure.self) {
            try await client.generate(request())
        }
        #expect(await quota.snapshot().remaining == 5)
    }

    @Test("An exhausted quota fails before anything is submitted")
    func exhaustedQuotaDoesNotSubmit() async throws {
        let transport = ScriptedTransport(statuses: [.succeeded], candidates: [candidate()])
        let (client, quota) = makeClient(transport, allowance: 1)

        _ = try await client.generate(request(key: "first"))
        await #expect(throws: GenerationClient.Failure.self) {
            try await client.generate(request(key: "second"))
        }
        #expect(await transport.submitCount == 1)
        _ = quota
    }

    @Test("Failures other than an unsuitable route offer the local card")
    func fallbackAdvice() {
        // DESIGN.md §4.4 — the app must keep working when generation does not.
        #expect(GenerationClient.Failure.jobFailed("x").suggestsLocalFallback)
        #expect(GenerationClient.Failure.transport("x").suggestsLocalFallback)
        #expect(GenerationClient.Failure.expired.suggestsLocalFallback)
        #expect(!GenerationClient.Failure.routeUnsuitable("straight").suggestsLocalFallback)
    }

    @Test("A near-straight route is blocked before any money is spent")
    func degenerateRouteBlocked() async {
        let transport = ScriptedTransport(statuses: [.succeeded])
        let (client, _) = makeClient(transport)

        let availability = await client.availability(
            for: fingerprint(degenerate: true), lengthMeters: 5_000
        )
        #expect(!availability.canGenerate)
        #expect(await transport.submitCount == 0)
    }

    @Test("A very short route is blocked")
    func shortRouteBlocked() async {
        let transport = ScriptedTransport(statuses: [.succeeded])
        let (client, _) = makeClient(transport)

        let availability = await client.availability(for: fingerprint(), lengthMeters: 120)
        #expect(!availability.canGenerate)
    }

    @Test("Offline is reported as offline, not as a bad route")
    func offline() async {
        let transport = ScriptedTransport(statuses: [.succeeded])
        let (client, _) = makeClient(transport)

        let availability = await client.availability(
            for: fingerprint(), lengthMeters: 5_000, isOnline: false
        )
        #expect(availability == .offline)
    }

    @Test("A suitable route with quota is available")
    func availableRoute() async {
        let transport = ScriptedTransport(statuses: [.succeeded])
        let (client, _) = makeClient(transport)

        #expect(
            await client.availability(for: fingerprint(), lengthMeters: 5_000)
                == .available(remaining: 5)
        )
    }

    @Test("Backoff grows and then holds")
    func backoff() {
        let policy = GenerationClient.PollingPolicy()
        #expect(policy.interval(forAttempt: 0) == 2)
        #expect(policy.interval(forAttempt: 4) == 10)
        #expect(policy.interval(forAttempt: 99) == 10)
    }
}

@Suite("GenerationJob")
struct GenerationJobTests {

    @Test("Terminal statuses are classified correctly")
    func terminalStatuses() {
        #expect(!GenerationJob.Status.queued.isTerminal)
        #expect(!GenerationJob.Status.running.isTerminal)
        for status in [GenerationJob.Status.succeeded, .failed, .cancelled, .expired] {
            #expect(status.isTerminal)
        }
    }

    @Test("Only success keeps the quota")
    func refundClassification() {
        #expect(!GenerationJob.Status.succeeded.refundsQuota)
        #expect(GenerationJob.Status.failed.refundsQuota)
        #expect(GenerationJob.Status.cancelled.refundsQuota)
        #expect(GenerationJob.Status.expired.refundsQuota)
    }

    @Test("A job that never finishes expires")
    func expiry() {
        let job = GenerationJob(
            id: "j", idempotencyKey: "k", status: .running,
            createdAt: epoch, updatedAt: epoch
        )
        #expect(!job.expired(at: epoch.addingTimeInterval(60)))
        #expect(job.expired(at: epoch.addingTimeInterval(700)))
    }

    @Test("A finished job never expires afterwards")
    func terminalDoesNotExpire() {
        let job = GenerationJob(
            id: "j", idempotencyKey: "k", status: .succeeded,
            createdAt: epoch, updatedAt: epoch
        )
        #expect(!job.expired(at: epoch.addingTimeInterval(10_000)))
    }

    @Test("A request carries no coordinates")
    func requestHasNoCoordinates() {
        // DESIGN.md §11 — the server never receives location. The type makes
        // that structural rather than a promise: there is nowhere to put one.
        let submitted = request()
        #expect(submitted.orientationImages.count == 16)
        #expect(Mirror(reflecting: submitted).children.allSatisfy { child in
            !(child.label ?? "").lowercased().contains("lat")
                && !(child.label ?? "").lowercased().contains("lon")
                && !(child.label ?? "").lowercased().contains("coordinate")
        })
    }
}
