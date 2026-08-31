import Foundation
import GenerationKit
import RouteKit
import RoutePicStore
import ShapeKit
import SwiftUI

/// What a collection cell needs, worked out once per activity rather than once
/// per scroll pass — a screenful of polyline decodes, file reads and shape
/// pipelines on the main actor is the delay.
///
/// Not `@Observable` on purpose: a cache that publishes invalidates every cell
/// watching it each time one of them fills in.
@MainActor
final class RouteRenderCache {

    /// What a tile needs, from one decode. Asked separately it was two:
    /// `routeSummary()` decoded the polyline to answer "is this readable" and
    /// the pipeline decoded it again to draw the line.
    struct Tile: Sendable {
        var shape: OrientedShape?
        var isReadable: Bool
        /// What the shape reads as. From the same fingerprint the drawing came
        /// from, so it costs nothing the tile was not already paying.
        var subject: String?
    }

    private var tiles: [Key: Tile] = [:]
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

    /// A file read and an image decode, off the main actor. Caching alone was
    /// half the fix: a first scroll through a long collection is nothing but
    /// misses, which is the scroll this exists to smooth.
    func image(named name: String, from store: any ArtworkStore) async -> Image? {
        if let hit = images[name] { return hit }
        guard let image = await decode(name, from: store) else { return nil }
        guard !Task.isCancelled else { return image }
        if images.count >= Self.limit { images.removeAll(keepingCapacity: true) }
        images[name] = image
        return image
    }

    private nonisolated func decode(_ name: String, from store: any ArtworkStore) async -> Image? {
        guard let data = try? store.data(named: name) else { return nil }
        return PlatformImage.from(data)
    }

    /// The stored bytes are read here; decoding and the pipeline are not.
    ///
    /// Nothing inside `DerivedRoute.make` checks for cancellation, so once
    /// started it runs to the end — the check that counts is the one before.
    func tile(for activity: Activity, canvasSize: Double) async -> Tile {
        let key = Key(activity)
        if let hit = tiles[key] { return hit }
        guard !Task.isCancelled else { return Tile(shape: nil, isReadable: true, subject: nil) }

        let value = await derive(
            activity.storedRoute, mode: activity.mode,
            trim: Double(activity.privacyTrimMeters), canvasSize: canvasSize
        )
        // Half a pipeline is not an answer: caching what a cancelled task got
        // to would leave the shape permanently missing for that activity.
        guard !Task.isCancelled else { return value }
        if tiles.count >= Self.limit { tiles.removeAll(keepingCapacity: true) }
        tiles[key] = value
        return value
    }

    private nonisolated func derive(
        _ stored: StoredRoute, mode: RecordingMode, trim: Double, canvasSize: Double
    ) async -> Tile {
        guard let route = try? stored.decode() else {
            return Tile(shape: nil, isReadable: false, subject: nil)
        }
        guard let shape = try? DerivedRoute.make(
            from: route, mode: mode, trimMeters: trim,
            purpose: .display, canvasSize: canvasSize
        ).shape.canonical else {
            return Tile(shape: nil, isReadable: true, subject: nil)
        }
        // The fallback, not nil: a straight commute proposes nothing, and a
        // tile that says nothing is the feature disappearing on the most
        // common route there is.
        let reading = FingerprintInterpreter().read(shape.fingerprint)
        return Tile(
            shape: shape, isReadable: true,
            subject: reading.candidates.first?.subject
                ?? FingerprintInterpreter.unrecognised.subject
        )
    }
}
