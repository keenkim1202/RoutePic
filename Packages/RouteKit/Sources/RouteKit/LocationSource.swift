import Foundation

/// Where fixes come from.
///
/// `PLAN.md` §0.1 ③ — `DESIGN.md` OQ-D (classic `CLLocationManager` versus
/// `CLLocationUpdate` + `CLBackgroundActivitySession`) is settled by measuring
/// on a device, which cannot happen until T-1 runs. Putting both behind this
/// protocol means the rest of `RouteKit` does not wait for that answer: T-1
/// decides only which implementation is the default.
public protocol LocationSource: Sendable {
    /// Fixes, in arrival order. Finishes when `stop()` is called.
    func updates() -> AsyncStream<LocationFix>
    func start(mode: RecordingMode) async throws
    func stop() async
}

public enum LocationAuthorization: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    /// Enough for a session the user starts in the foreground — but only for as
    /// long as that session lives (`DESIGN.md` §5.1).
    case whenInUse
    case always
}

public enum LocationSourceError: Error, Equatable, CustomStringConvertible {
    case authorizationDenied
    case reducedAccuracy
    case unavailable(String)

    public var description: String {
        switch self {
        case .authorizationDenied:
            return "Location permission is not granted."
        case .reducedAccuracy:
            return "Precise Location is off; a route cannot be recorded from approximate fixes."
        case .unavailable(let detail):
            return "Location services unavailable: \(detail)"
        }
    }
}

/// Replays a fixed list of fixes.
///
/// This is what makes `DESIGN.md` §14.2 T-6 — outlier and jump injection — an
/// ordinary unit test rather than something requiring a device and a walk.
public final class SimulatedLocationSource: LocationSource, @unchecked Sendable {

    private let fixes: [LocationFix]
    private let lock = NSLock()
    private var continuation: AsyncStream<LocationFix>.Continuation?

    public init(fixes: [LocationFix]) {
        self.fixes = fixes
    }

    public func updates() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    public func start(mode: RecordingMode) async throws {
        // Deliver everything immediately; tests control time via the fix
        // timestamps rather than by waiting.
        let continuation = lock.withLock { self.continuation }
        for fix in fixes { continuation?.yield(fix) }
    }

    public func stop() async {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }
}
