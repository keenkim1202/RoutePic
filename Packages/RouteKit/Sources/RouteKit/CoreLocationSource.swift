import CoreLocation
import Foundation

/// The classic `CLLocationManager` path.
///
/// `DESIGN.md` §5.1 / OQ-D. This is one of two candidates; T-1 measures both on
/// the same device and route before either becomes the default. Nothing else in
/// `RouteKit` depends on which one wins.
public final class ClassicLocationSource: NSObject, LocationSource, @unchecked Sendable {

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var continuation: AsyncStream<LocationFix>.Continuation?
    private var authorizationContinuation: CheckedContinuation<Void, Error>?
    /// The mode of the running session, so the power-state watcher can re-apply
    /// the accuracy for it. Nil when nothing is recording.
    private var runningMode: RecordingMode?
    private var powerWatcher: Task<Void, Never>?

    public override init() {
        super.init()
        manager.delegate = self
        manager.distanceFilter = kCLDistanceFilterNone   // filtering is ours
        manager.pausesLocationUpdatesAutomatically = false
    }

    public var authorization: LocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorizedWhenInUse: .whenInUse
        #if os(iOS)
        case .authorizedAlways: .always
        #else
        case .authorized, .authorizedAlways: .always
        #endif
        @unknown default: .denied
        }
    }

    public var hasFullAccuracy: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    public func updates() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    public func start(mode: RecordingMode) async throws {
        if manager.authorizationStatus == .notDetermined {
            try await requestAuthorization()
        }
        switch authorization {
        case .denied, .restricted, .notDetermined:
            throw LocationSourceError.authorizationDenied
        case .whenInUse, .always:
            break
        }
        guard hasFullAccuracy else { throw LocationSourceError.reducedAccuracy }

        lock.withLock { runningMode = mode }
        applyAccuracy(for: mode)
        manager.activityType = Self.activityType(for: mode)
        watchPowerState()

        #if os(iOS)
        // When In Use is sufficient *while a foreground-started session runs*,
        // provided background updates are enabled and the indicator is shown.
        // It is not equivalent to Always: once the session stops, the app is a
        // normal suspension candidate (`DESIGN.md` §5.1).
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        #endif

        manager.startUpdatingLocation()
    }

    public func stop() async {
        manager.stopUpdatingLocation()
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = false
        #endif

        let (continuation, watcher) = lock.withLock {
            defer {
                self.continuation = nil
                self.runningMode = nil
                self.powerWatcher = nil
            }
            return (self.continuation, self.powerWatcher)
        }
        watcher?.cancel()
        continuation?.finish()
    }

    private func requestAuthorization() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { authorizationContinuation = continuation }
            manager.requestWhenInUseAuthorization()
        }
    }

    /// One step down in Low Power Mode.
    ///
    /// iOS does not touch the accuracy an app asks for — Low Power Mode is a
    /// signal to the app, not a change to Core Location. Left alone, the most
    /// expensive setting keeps running on the emptiest battery, which is the
    /// state `DESIGN.md` §14.1 exists to handle.
    static func desiredAccuracy(
        for mode: RecordingMode, lowPower: Bool = false
    ) -> CLLocationAccuracy {
        switch (mode, lowPower) {
        case (.walk, false): kCLLocationAccuracyBest
        case (.walk, true): kCLLocationAccuracyNearestTenMeters
        case (.run, false), (.drive, false): kCLLocationAccuracyBestForNavigation
        case (.run, true), (.drive, true): kCLLocationAccuracyBest
        }
    }

    private func applyAccuracy(for mode: RecordingMode) {
        manager.desiredAccuracy = Self.desiredAccuracy(
            for: mode, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// Low Power Mode can be switched on halfway through a run, and the setting
    /// applied at `start` would then outlive the battery it was chosen for.
    private func watchPowerState() {
        guard lock.withLock({ powerWatcher == nil }) else { return }
        let changes = NotificationCenter.default.notifications(
            named: .NSProcessInfoPowerStateDidChange
        )
        let task = Task { [weak self] in
            for await _ in changes {
                guard let self, let mode = self.lock.withLock({ self.runningMode })
                else { return }
                self.applyAccuracy(for: mode)
            }
        }
        lock.withLock { powerWatcher = task }
    }

    static func activityType(for mode: RecordingMode) -> CLActivityType {
        switch mode {
        case .walk, .run: .fitness
        case .drive: .automotiveNavigation
        }
    }
}

extension ClassicLocationSource: CLLocationManagerDelegate {

    public func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        let continuation = lock.withLock { self.continuation }
        for location in locations {
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
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let continuation = lock.withLock {
            defer { authorizationContinuation = nil }
            return authorizationContinuation
        }
        continuation?.resume()
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient failure is not the end of the session: CoreLocation
        // recovers on its own, and tearing down the stream would end a run
        // because of a momentary signal loss.
        let continuation = lock.withLock {
            defer { authorizationContinuation = nil }
            return authorizationContinuation
        }
        continuation?.resume(throwing: error)
    }
}
