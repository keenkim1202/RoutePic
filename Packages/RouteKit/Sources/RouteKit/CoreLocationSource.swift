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

        manager.desiredAccuracy = Self.desiredAccuracy(for: mode)
        manager.activityType = Self.activityType(for: mode)

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

        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }

    private func requestAuthorization() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { authorizationContinuation = continuation }
            manager.requestWhenInUseAuthorization()
        }
    }

    static func desiredAccuracy(for mode: RecordingMode) -> CLLocationAccuracy {
        switch mode {
        case .walk: kCLLocationAccuracyBest
        case .run, .drive: kCLLocationAccuracyBestForNavigation
        }
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
