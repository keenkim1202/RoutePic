import Foundation
import RouteKit
import ShapeKit

/// The three forms a route takes, and the rule that keeps them apart.
///
/// `DESIGN.md` §8.4 — v0.1 stored only a trim setting and never said where it
/// applied, so the same route could be shared trimmed in one place and untrimmed
/// in another. The stored route is always the untouched original; display and
/// share forms are derived on demand and never persisted, which is also what
/// makes a trim change retroactive for free.
public enum DerivedRoute {

    public enum Purpose: Sendable, Equatable {
        /// On-screen map and thumbnails.
        case display
        /// Anything leaving the device: a share card, a map snapshot.
        case share
        /// The control image sent to the generation proxy.
        case control
    }

    public struct Result: Sendable {
        public var shape: PreparedShape
        public var trim: RouteTrimmer.Result

        /// Sharing a map of this route would expose the start point despite the
        /// trim, because the route returns to it (`DESIGN.md` §8.4).
        public var mapSnapshotIsUnsafe: Bool
    }

    /// Builds a derived form.
    ///
    /// `share` and `control` always recompute — never cache, never reuse a
    /// display-derived shape. A cached share form is how a stale, less-trimmed
    /// route leaks after the user tightens the setting.
    public static func make(
        from activity: Activity,
        purpose: Purpose,
        canvasSize: Double = Normalize.defaultCanvasSize
    ) throws -> Result {
        let route = try activity.route()
        return try make(
            from: route,
            mode: activity.mode,
            trimMeters: Double(activity.privacyTrimMeters),
            purpose: purpose,
            canvasSize: canvasSize
        )
    }

    public static func make(
        from route: Route,
        mode: RecordingMode,
        trimMeters: Double,
        purpose: Purpose,
        canvasSize: Double = Normalize.defaultCanvasSize
    ) throws -> Result {
        var configuration = mode.shapeConfiguration
        configuration.canvasSize = canvasSize
        configuration.trimMeters = trimMeters

        let prepared = try ShapePipeline(configuration: configuration).prepare(route)
        let trim = prepared.trim

        // A loop returns to where it started, so trimming both ends still leaves
        // that point on the map. Too short a route has nothing left after
        // trimming at all.
        let unsafe = purpose == .share && (trim.isLoop || trim.isTooShortToShare)

        return Result(shape: prepared, trim: trim, mapSnapshotIsUnsafe: unsafe)
    }
}
