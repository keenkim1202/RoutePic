import Foundation
import ShapeKit

/// One location reading, stripped of CoreLocation.
///
/// The filter chain, the journal and the session state machine all work on this
/// rather than `CLLocation`. That keeps `DESIGN.md` §14.2 T-6 — outlier and
/// jump injection — as ordinary unit tests instead of something that needs a
/// device and a walk around the block.
public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var timestamp: Date

    /// Metres. Negative means the reading is invalid, matching CoreLocation.
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double

    /// Metres per second, or negative when the device could not measure it.
    /// `DESIGN.md` §5.3 — v0.1 used this value directly, which silently treats
    /// "unknown" as "moving backwards".
    public var speed: Double

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double = 0,
        timestamp: Date,
        horizontalAccuracy: Double = 5,
        verticalAccuracy: Double = 5,
        speed: Double = -1
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
    }

    public var hasValidHorizontalAccuracy: Bool { horizontalAccuracy >= 0 }
    public var hasValidVerticalAccuracy: Bool { verticalAccuracy >= 0 }
    public var hasMeasuredSpeed: Bool { speed >= 0 }

    public var routePoint: RoutePoint {
        RoutePoint(
            latitude: latitude,
            longitude: longitude,
            altitude: hasValidVerticalAccuracy ? altitude : nil,
            timestamp: timestamp,
            horizontalAccuracy: hasValidHorizontalAccuracy ? horizontalAccuracy : nil,
            verticalAccuracy: hasValidVerticalAccuracy ? verticalAccuracy : nil
        )
    }

    public func distance(to other: LocationFix) -> Double {
        ENUProjection.haversineDistance(routePoint, other.routePoint)
    }
}
