import Foundation
import ShapeKit

/// A recording in progress.
///
/// `DESIGN.md` §5.4–§5.5. Time is always passed in rather than read from the
/// clock, so gap detection, auto-pause and the flush policy are all testable
/// without waiting.
public actor RecordingSession {

    public enum State: String, Sendable, Equatable {
        case idle
        case recording
        case paused
        case finished
    }

    /// What the UI renders. A value type so it can cross to the main actor.
    public struct Snapshot: Sendable, Equatable {
        public var state: State
        public var mode: RecordingMode
        public var statistics: ActivityStatistics
        public var pointCount: Int
        public var gapCount: Int
        /// The device stopped moving; `DESIGN.md` §5.5 suggests rather than
        /// forces a pause, because a suggestion the user ignores is recoverable
        /// and an automatic pause they did not want is not.
        public var suggestsPause: Bool
        /// Journal writes are failing — the UI must warn (`DESIGN.md` §14.1).
        public var storageWarning: String?
    }

    /// `DESIGN.md` §5.5 — still for this long inside `autoPauseRadius`.
    public static let autoPauseDuration: TimeInterval = 60
    public static let autoPauseRadius: Double = 15

    /// `nonisolated` because callers need the identity to find the journal file
    /// without awaiting the actor.
    public nonisolated let id: UUID
    public nonisolated let mode: RecordingMode
    public private(set) var state: State = .idle

    private var points: [RoutePoint] = []
    private var segments: [RouteSegment] = []
    private var runStart = 0

    private var filter: LocationFilterChain
    private let journal: SessionJournal?

    private var startedAt: Date?
    private var lastAcceptedFix: LocationFix?
    /// Last fix we could derive a position from — accepted, or rejected only
    /// for being too close. Drives gap detection.
    private var lastPositionedAt: Date?
    private var stillnessAnchor: (fix: LocationFix, since: Date)?
    private var suggestsPause = false
    private var lastCheckpoint: Date?

    public init(
        id: UUID = UUID(),
        mode: RecordingMode,
        journal: SessionJournal? = nil
    ) {
        self.id = id
        self.mode = mode
        self.journal = journal
        self.filter = LocationFilterChain(mode: mode)
    }

    public func start(now: Date) {
        guard state == .idle else { return }
        state = .recording
        startedAt = now
        journal?.append(.header(sessionID: id, mode: mode, startedAt: now), now: now)
    }

    /// Feeds one raw fix in. Returns whether it became part of the route.
    @discardableResult
    public func ingest(_ fix: LocationFix, now: Date) -> Bool {
        guard state == .recording else { return false }

        // A silence longer than the mode's threshold is a dropout. The break is
        // recorded before the fix that ended it, so the render never joins the
        // two stretches with a line nobody walked (`DESIGN.md` §5.4).
        //
        // "Silence" is measured against the last fix we could get a position
        // from — accepted *or* rejected only for being too close. Measuring
        // against the last stored point instead would call standing still a
        // dropout, and would re-fire on every subsequent fix because the
        // reference never advances.
        // A fix that fails the basic checks must not be allowed to cut the
        // route: a single stale reading arriving late would otherwise split a
        // continuous walk in two.
        let isUsable = filter.preliminaryRejection(fix, now: now) == nil

        if isUsable, let last = lastPositionedAt,
           fix.timestamp.timeIntervalSince(last) > mode.gapThreshold {
            // A held outlier belongs to the run that is ending, not to the one
            // after the gap. It is committed rather than dropped.
            commitPendingFix(now: now)
            closeRun(.gap, at: fix.timestamp)
            journal?.append(.segmentBoundary(kind: .gap, at: fix.timestamp), now: now)
            // Nothing before the gap says anything about what comes after it.
            filter = LocationFilterChain(mode: mode)
            lastAcceptedFix = nil
            lastPositionedAt = nil
            stillnessAnchor = nil
        }

        // Stillness is judged on the raw fix, before the distance gate.
        // Downstream of it the detector could never fire: standing still is
        // exactly the case where every fix is rejected as too close.
        updateStillness(with: fix, now: now)

        switch filter.accept(fix, now: now) {
        case .accepted(let accepted):
            // May be two: a held outlier confirmed by this fix.
            for entry in accepted {
                points.append(entry.routePoint)
                journal?.append(.fix(entry), now: now)
            }
            lastAcceptedFix = accepted.last
            lastPositionedAt = accepted.last?.timestamp
            writeCheckpointIfDue(now: now)
            return true

        case .rejected(.tooClose):
            // A usable position, just not far enough to store.
            lastPositionedAt = fix.timestamp
            return false

        case .rejected, .pending:
            return false
        }
    }

    public func pause(now: Date) {
        guard state == .recording else { return }
        state = .paused
        commitPendingFix(now: now)
        lastPositionedAt = nil
        closeRun(.paused, at: now)
        journal?.append(.segmentBoundary(kind: .paused, at: now), now: now)
        journal?.flush(now: now)
        suggestsPause = false
        stillnessAnchor = nil
    }

    public func resume(now: Date) {
        guard state == .paused else { return }
        state = .recording
        // A new filter chain: the pre-pause fix is not a valid reference for
        // plausibility once arbitrary time has passed.
        filter = LocationFilterChain(mode: mode)
        lastAcceptedFix = nil
        lastPositionedAt = nil
    }

    /// Ends the session and returns the route, or `nil` if nothing usable was
    /// recorded.
    public func finish(now: Date) -> Route? {
        guard state != .finished else { return route() }
        if state == .recording {
            // Nothing will arrive to confirm a held fix, and discarding a
            // coordinate the device reported is the worst thing this engine can
            // do (`DESIGN.md` §5.4).
            commitPendingFix(now: now)
            closeRun(.moving, at: now)
        }
        state = .finished
        journal?.flush(now: now)
        journal?.close()

        let result = route()
        return result.movingRuns.isEmpty ? nil : result
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            state: state,
            mode: mode,
            statistics: ActivityStatistics.compute(for: route()),
            pointCount: points.count,
            gapCount: segments.count { $0.kind == .gap },
            suggestsPause: suggestsPause,
            storageWarning: journal?.writeFailure
        )
    }

    /// Forces buffered fixes to disk. Call on background transition.
    public func flushJournal(now: Date) {
        journal?.flush(now: now)
    }

    // MARK: - Internals

    private func route() -> Route {
        var allSegments = segments
        if points.count > runStart {
            allSegments.append(
                RouteSegment(startIndex: runStart, endIndex: points.count, kind: .moving)
            )
        }
        return Route(points: points, segments: allSegments)
    }

    /// Closes the open moving run and, unless `kind` is `.moving`, records a
    /// zero-length boundary marker.
    private func closeRun(_ kind: SegmentKind, at date: Date) {
        if points.count > runStart {
            segments.append(
                RouteSegment(startIndex: runStart, endIndex: points.count, kind: .moving)
            )
        }
        if kind != .moving {
            segments.append(
                RouteSegment(startIndex: points.count, endIndex: points.count, kind: kind)
            )
        }
        runStart = points.count
    }

    /// Moves any held outlier into the route.
    ///
    /// Called wherever the confirming fix will never come. The alternative —
    /// dropping it — deletes a real reading to avoid showing a possibly wrong
    /// one, which is the wrong way round for a recorder.
    private func commitPendingFix(now: Date) {
        guard let pending = filter.takePending() else { return }
        points.append(pending.routePoint)
        journal?.append(.fix(pending), now: now)
        lastAcceptedFix = pending
    }

    private func updateStillness(with fix: LocationFix, now: Date) {
        guard mode.suggestsAutoPause else { return }
        // A wildly inaccurate fix must not be read as "you moved".
        guard fix.hasValidHorizontalAccuracy,
              fix.horizontalAccuracy <= mode.accuracyCeiling else { return }

        guard let anchor = stillnessAnchor else {
            stillnessAnchor = (fix, fix.timestamp)
            return
        }
        if anchor.fix.distance(to: fix) > Self.autoPauseRadius {
            stillnessAnchor = (fix, fix.timestamp)
            suggestsPause = false
        } else if fix.timestamp.timeIntervalSince(anchor.since) >= Self.autoPauseDuration {
            suggestsPause = true
        }
    }

    private func writeCheckpointIfDue(now: Date) {
        guard let journal else { return }
        let due = lastCheckpoint.map {
            now.timeIntervalSince($0) >= journal.policy.checkpointInterval
        } ?? true
        guard due else { return }

        lastCheckpoint = now
        let statistics = ActivityStatistics.compute(for: route())
        journal.append(
            .checkpoint(
                distanceMeters: statistics.distanceMeters,
                movingDuration: statistics.movingDuration,
                at: now
            ),
            now: now
        )
    }
}
