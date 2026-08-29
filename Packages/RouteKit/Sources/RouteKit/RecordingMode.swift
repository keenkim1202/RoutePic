import Foundation
import ShapeKit

/// Walking, running or driving — and the tuning that follows from it.
///
/// `DESIGN.md` §5.2. Every threshold here is `[미검증]` until real device logs
/// exist (`PLAN.md` M3 DoD); they are starting points, not measurements.
public enum RecordingMode: String, Sendable, Codable, CaseIterable {
    case walk
    case run
    case drive

    /// Upper bound on plausible speed, m/s. A fix implying more than this is
    /// held back for confirmation rather than trusted.
    ///
    /// There is deliberately **no lower bound**: `DESIGN.md` v0.2 removed the
    /// "slower than 0.3 m/s is noise" rule because it deletes uphill stretches,
    /// traffic lights and crowded pavements. Standing still is the auto-pause
    /// detector's job, not the filter's.
    public var maximumSpeed: Double {
        switch self {
        case .walk: 4
        case .run: 9
        case .drive: 65
        }
    }

    /// Fixes worse than this are dropped outright.
    public var accuracyCeiling: Double {
        switch self {
        case .walk, .run: 25
        case .drive: 50
        }
    }

    /// Minimum distance between two stored points.
    public var minimumStoredDistance: Double {
        switch self {
        case .walk: 5
        case .run: 8
        case .drive: 25
        }
    }

    /// A silence longer than this is a dropout, not a pause — the route is cut
    /// rather than joined (`DESIGN.md` §5.4).
    public var gapThreshold: TimeInterval {
        switch self {
        case .walk: 90
        case .run: 60
        case .drive: 45
        }
    }

    /// Auto-pause is off for driving: sitting at a red light is not a pause.
    public var suggestsAutoPause: Bool {
        switch self {
        case .walk, .run: true
        case .drive: false
        }
    }

    public var shapeConfiguration: ShapePipeline.Configuration {
        switch self {
        case .walk: .walking
        case .run: .running
        case .drive: .driving
        }
    }
}

extension RecordingMode {
    /// The mode's name as a person reads it. Lives with the type because the
    /// store speaks it too, in `Activity.accessibilityDescription`.
    public var title: String {
        switch self {
        case .walk: "Walk"
        case .run: "Run"
        case .drive: "Drive"
        }
    }
}
