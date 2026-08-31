import Foundation
import RouteKit
import RoutePicStore
import ShapeKit
import SwiftUI

/// What a collection cell needs, worked out once per activity rather than once
/// per scroll pass.
///
/// Every visible tile was decoding the stored polyline, reading a file and
/// decoding an image on the main thread on each body evaluation, and deriving
/// the whole shape in a `.task` that inherits the main actor. A screenful of
/// that is the delay.
///
/// Deliberately not `@Observable`: a cache that publishes would invalidate
/// every cell watching it each time any one of them fills in.
@MainActor
final class RouteRenderCache {

    private var summaries: [Key: Activity.RouteSummary] = [:]
    private var shapes: [Key: OrientedShape?] = [:]
    private var images: [String: Image] = [:]

    /// Carries `updatedAt`, so an edit misses the cache instead of needing
    /// somebody to remember to clear it. `updateTrim` bumps it, and a trim is
    /// what the derivation depends on.
    private struct Key: Hashable {
        let id: UUID
        let updatedAt: Date

        init(_ activity: Activity) {
            id = activity.id
            updatedAt = activity.updatedAt
        }
    }

    /// ponytail: a few screens either way, then the whole map goes. Proper LRU
    /// if scrolling far and back ever costs more than the first pass did.
    private static let limit = 240

    func summary(for activity: Activity) -> Activity.RouteSummary {
        let key = Key(activity)
        if let hit = summaries[key] { return hit }
        let value = activity.routeSummary()
        if summaries.count >= Self.limit { summaries.removeAll(keepingCapacity: true) }
        summaries[key] = value
        return value
    }

    func image(named name: String, from store: any ArtworkStore) -> Image? {
        if let hit = images[name] { return hit }
        guard let data = try? store.data(named: name),
              let image = PlatformImage.from(data)
        else { return nil }
        if images.count >= Self.limit { images.removeAll(keepingCapacity: true) }
        images[name] = image
        return image
    }

    /// The shape pipeline runs off the main actor. It is pure work over two
    /// `Sendable` values, and on the main actor it is what stalls the scroll.
    func shape(for activity: Activity, canvasSize: Double) async -> OrientedShape? {
        let key = Key(activity)
        if let hit = shapes[key] { return hit }
        guard let route = try? activity.route() else {
            remember(nil, for: key)
            return nil
        }
        let derived = await derive(
            route, mode: activity.mode,
            trim: Double(activity.privacyTrimMeters), canvasSize: canvasSize
        )
        // A tile scrolled past has its `.task` cancelled mid-derivation, and
        // half a pipeline is not an answer — caching it would make the shape
        // permanently missing for that activity.
        guard !Task.isCancelled else { return derived }
        remember(derived, for: key)
        return derived
    }

    /// `nonisolated`, not `Task.detached`: both leave the main actor, but a
    /// detached task does not inherit cancellation. Scrolling fast past two
    /// hundred tiles would leave two hundred pipelines running that nobody is
    /// waiting for — in the change meant to make scrolling smooth.
    private nonisolated func derive(
        _ route: Route, mode: RecordingMode, trim: Double, canvasSize: Double
    ) async -> OrientedShape? {
        try? DerivedRoute.make(
            from: route, mode: mode, trimMeters: trim,
            purpose: .display, canvasSize: canvasSize
        ).shape.canonical
    }

    private func remember(_ shape: OrientedShape?, for key: Key) {
        if shapes.count >= Self.limit { shapes.removeAll(keepingCapacity: true) }
        shapes[key] = shape
    }
}
