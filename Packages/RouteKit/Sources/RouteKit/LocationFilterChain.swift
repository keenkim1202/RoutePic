import Foundation

/// Decides which raw fixes become part of the stored route.
///
/// `DESIGN.md` §5.3. Two rules matter more than the thresholds:
///
/// 1. **Nothing here smooths.** v0.1 put a moving average in this chain;
///    smoothing rounds off corners and therefore changes the shape the whole
///    product is built on. Smoothing belongs to the render pipeline
///    (`ShapeKit.Smoothing`), where it can be re-run or undone.
/// 2. **An outlier is held, not dropped.** A single fast fix might be a GPS
///    jump or might be the moment a car pulled away. Dropping it immediately
///    loses real movement; the next fix settles which it was.
public struct LocationFilterChain: Sendable {

    public enum Rejection: String, Sendable, Equatable {
        case stale
        /// Timestamped in the future — a clock that has just been corrected, or
        /// a bad reading. Accepting it poisons every later age and speed check.
        case fromTheFuture
        case warmingUp
        case invalidAccuracy
        case poorAccuracy
        /// Same timestamp as, or earlier than, the last accepted fix. Not an
        /// outlier: there is no elapsed time to judge speed against.
        case outOfOrder
        case tooClose
    }

    public enum Decision: Sendable, Equatable {
        /// One or two fixes joined the route.
        ///
        /// Two happens when a previously held outlier is confirmed by the fix
        /// that follows it: both belong to the route. An API returning a single
        /// fix would silently drop the held one — it would live in the chain's
        /// internal state but never reach the caller, losing real movement.
        case accepted([LocationFix])
        case rejected(Rejection)
        /// Held pending the next fix; may still be accepted.
        case pending

        public var fixes: [LocationFix] {
            if case .accepted(let fixes) = self { fixes } else { [] }
        }
    }

    /// A fix older than this describes where the device used to be.
    public static let maximumAge: TimeInterval = 5

    public let mode: RecordingMode

    private var hasWarmedUp = false
    private var lastAccepted: LocationFix?
    private var heldOutlier: LocationFix?

    public init(mode: RecordingMode) {
        self.mode = mode
    }

    public private(set) var acceptedCount = 0

    /// Feeds one fix through the chain.
    ///
    /// `now` is injected so tests can run without sleeping.
    /// The checks that decide whether a fix is worth looking at at all.
    ///
    /// Exposed so the session can run them *before* deciding a silence was a
    /// dropout: a stale or unusable fix must not be allowed to cut the route in
    /// two.
    public func preliminaryRejection(_ fix: LocationFix, now: Date) -> Rejection? {
        let age = now.timeIntervalSince(fix.timestamp)
        if age > Self.maximumAge { return .stale }
        // A negative age is a fix from the future. `age <= maximumAge` alone
        // waves those through.
        if age < -Self.maximumAge { return .fromTheFuture }
        if !fix.hasValidHorizontalAccuracy { return .invalidAccuracy }
        return nil
    }

    public mutating func accept(_ fix: LocationFix, now: Date) -> Decision {
        if let rejection = preliminaryRejection(fix, now: now) {
            return .rejected(rejection)
        }

        // Warm-up is measured by accuracy, not by counting fixes. v0.1 dropped
        // the first three unconditionally, which throws away good data when the
        // GPS was already converged and keeps bad data when it was not.
        if !hasWarmedUp {
            guard fix.horizontalAccuracy <= mode.accuracyCeiling else {
                return .rejected(.warmingUp)
            }
            hasWarmedUp = true
        }

        guard fix.horizontalAccuracy <= mode.accuracyCeiling else {
            return .rejected(.poorAccuracy)
        }

        guard let previous = lastAccepted else {
            return store(fix)
        }

        // A fix that is not strictly later than the last accepted one has no
        // elapsed time to judge speed against. Treating it as an outlier would
        // let it evict a genuinely held fix.
        guard fix.timestamp > previous.timestamp else {
            return .rejected(.outOfOrder)
        }

        if let held = heldOutlier {
            // The held fix is confirmed if the new one continues from it at a
            // plausible speed — that is real movement, not a jump.
            if isPlausible(from: held, to: fix) {
                heldOutlier = nil
                _ = store(held)
                _ = store(fix)
                return .accepted([held, fix])
            }
            heldOutlier = nil
            // Fall through and judge the new fix against the last accepted one.
        }

        if !isPlausible(from: previous, to: fix) {
            heldOutlier = fix
            return .pending
        }

        guard previous.distance(to: fix) >= mode.minimumStoredDistance else {
            return .rejected(.tooClose)
        }
        return store(fix)
    }

    /// Speed between two fixes, preferring the device's own measurement.
    ///
    /// `CLLocation.speed` is negative when unmeasurable; using it raw treats
    /// "unknown" as "-1 m/s".
    private func isPlausible(from previous: LocationFix, to fix: LocationFix) -> Bool {
        let elapsed = fix.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return false }

        let measured = fix.hasMeasuredSpeed ? fix.speed : nil
        let derived = previous.distance(to: fix) / elapsed
        let speed = measured ?? derived

        // 1.5× headroom: GPS noise inflates short-interval derived speed.
        return speed <= mode.maximumSpeed * 1.5
    }

    @discardableResult
    private mutating func store(_ fix: LocationFix) -> Decision {
        lastAccepted = fix
        acceptedCount += 1
        return .accepted([fix])
    }

    /// Hands back any held outlier and stops holding it.
    ///
    /// The session calls this when there will be no next fix to confirm with —
    /// a pause, a dropout, the end of a session. It **returns** the fix rather
    /// than discarding it: an unconfirmed fix is still a coordinate the device
    /// reported, and `DESIGN.md` §5.4 makes losing a received coordinate the
    /// worst failure this engine has. One suspicious point at the end of a
    /// segment is visible and correctable; a silently deleted one is neither.
    public mutating func takePending() -> LocationFix? {
        defer { heldOutlier = nil }
        return heldOutlier
    }
}
