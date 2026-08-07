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
        case warmingUp
        case invalidAccuracy
        case poorAccuracy
        case implausibleSpeed
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
    public mutating func accept(_ fix: LocationFix, now: Date) -> Decision {
        guard now.timeIntervalSince(fix.timestamp) <= Self.maximumAge else {
            return .rejected(.stale)
        }
        guard fix.hasValidHorizontalAccuracy else {
            return .rejected(.invalidAccuracy)
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

    /// Drops any held outlier. Called when a session pauses or ends so a
    /// pending fix cannot leak into the next segment.
    public mutating func flushPending() {
        heldOutlier = nil
    }
}
