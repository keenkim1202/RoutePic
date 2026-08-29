import CoreGraphics
import Foundation
import RouteKit
import ShapeKit
import SwiftData
import Testing
@testable import RoutePicStore

/// Route fixtures for the store layer.
enum StoreFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    static func route(points: Int = 100, gapAfter: Int? = nil) -> Route {
        let metresPerDegree = ENUProjection.earthRadius * .pi / 180
        var routePoints: [RoutePoint] = []
        for i in 0..<points {
            routePoints.append(
                RoutePoint(
                    latitude: 37.5665 + Double(i) * 10 / metresPerDegree,
                    longitude: 126.9780 + sin(Double(i) / 8) * 0.002,
                    altitude: 30,
                    timestamp: epoch.addingTimeInterval(Double(i) * 5),
                    horizontalAccuracy: 8,
                    verticalAccuracy: 5
                )
            )
        }
        guard let gapAfter, gapAfter < points else { return Route(points: routePoints) }
        return Route(
            points: routePoints,
            segments: [
                RouteSegment(startIndex: 0, endIndex: gapAfter, kind: .moving),
                RouteSegment(startIndex: gapAfter, endIndex: gapAfter, kind: .gap),
                RouteSegment(startIndex: gapAfter, endIndex: points, kind: .moving),
            ]
        )
    }

    static func pngData(_ side: Int = 32) -> Data {
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try! ThumbnailRenderer.encodePNG(context.makeImage()!)
    }
}

@MainActor
@Suite("ActivityRepository")
struct ActivityRepositoryTests {

    private func makeRepository() throws -> ActivityRepository {
        let container = try ActivityRepository.inMemoryContainer()
        return ActivityRepository(
            context: ModelContext(container),
            artworkStore: InMemoryArtworkStore()
        )
    }

    @Test("Saving stores the route and its statistics")
    func save() throws {
        let repository = try makeRepository()
        let route = StoreFixtures.route()

        let activity = try repository.save(
            route: route, mode: .run,
            startedAt: StoreFixtures.epoch,
            endedAt: StoreFixtures.epoch.addingTimeInterval(495)
        )

        #expect(activity.distanceMeters > 900)
        #expect(try activity.route().points.count == 100)
        #expect(try repository.count() == 1)
    }

    @Test("Segments survive the round-trip through the blob")
    func segmentsRoundTrip() throws {
        // DESIGN.md §5.4 — losing the segmentation joins gaps with a straight
        // line the user never walked. It has to survive storage too.
        let repository = try makeRepository()
        let activity = try repository.save(
            route: StoreFixtures.route(gapAfter: 40), mode: .walk,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(495)
        )

        let restored = try activity.route()
        #expect(restored.movingRuns.count == 2)
        #expect(activity.gapCount == 1)
    }

    @Test("The feed is newest first and pages")
    func feedOrderAndPaging() throws {
        let repository = try makeRepository()
        for day in 0..<5 {
            _ = try repository.save(
                route: StoreFixtures.route(points: 20), mode: .run,
                startedAt: StoreFixtures.epoch.addingTimeInterval(Double(day) * 86_400),
                endedAt: StoreFixtures.epoch.addingTimeInterval(Double(day) * 86_400 + 600)
            )
        }

        let page = try repository.activities(limit: 2)
        #expect(page.count == 2)
        #expect(page[0].startedAt > page[1].startedAt)

        let second = try repository.activities(offset: 2, limit: 2)
        #expect(second.count == 2)
        #expect(second[0].startedAt < page[1].startedAt)
    }

    @Test("Mode filtering works")
    func modeFilter() throws {
        let repository = try makeRepository()
        for (index, mode) in [RecordingMode.walk, .run, .drive, .run].enumerated() {
            _ = try repository.save(
                route: StoreFixtures.route(points: 20), mode: mode,
                startedAt: StoreFixtures.epoch.addingTimeInterval(Double(index) * 3_600),
                endedAt: StoreFixtures.epoch.addingTimeInterval(Double(index) * 3_600 + 600)
            )
        }
        #expect(try repository.activities(mode: .run).count == 2)
        #expect(try repository.activities(mode: .drive).count == 1)
    }

    @Test("The first artwork is selected automatically")
    func firstArtworkIsSelected() throws {
        let repository = try makeRepository()
        let activity = try repository.save(
            route: StoreFixtures.route(), mode: .run,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(495)
        )
        let artwork = try attach(to: activity, using: repository)
        #expect(artwork.isSelected)

        let second = try attach(to: activity, using: repository)
        #expect(!second.isSelected)
    }

    @Test("Selecting an artwork deselects the others")
    func selection() throws {
        let repository = try makeRepository()
        let activity = try repository.save(
            route: StoreFixtures.route(), mode: .run,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(495)
        )
        _ = try attach(to: activity, using: repository)
        let second = try attach(to: activity, using: repository)

        try repository.select(second)
        #expect(activity.artworks.count(where: \.isSelected) == 1)
        #expect(second.isSelected)
    }

    @Test("Deleting an activity removes its artwork rows and files")
    func cascadeDelete() throws {
        // DESIGN.md §8.1 — cascade is not the default delete rule, so without an
        // explicit inverse the artwork rows and their images outlive the activity.
        let repository = try makeRepository()
        let activity = try repository.save(
            route: StoreFixtures.route(), mode: .run,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(495)
        )
        _ = try attach(to: activity, using: repository)
        _ = try attach(to: activity, using: repository)
        #expect(try repository.artworkStore.existingNames().count == 4)

        try repository.delete(activity)

        #expect(try repository.count() == 0)
        #expect(try repository.context.fetch(FetchDescriptor<Artwork>()).isEmpty)
        #expect(try repository.artworkStore.existingNames().isEmpty)
    }

    @Test("Deleting the selected artwork promotes another")
    func deletingSelectedPromotes() throws {
        let repository = try makeRepository()
        let activity = try repository.save(
            route: StoreFixtures.route(), mode: .run,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(495)
        )
        let first = try attach(to: activity, using: repository)
        _ = try attach(to: activity, using: repository)

        try repository.delete(first)
        #expect(activity.artworks.count == 1)
        #expect(activity.artworks[0].isSelected)
    }

    @Test("Notes and trim are editable and stamp updatedAt")
    func edits() throws {
        let repository = try makeRepository()
        let activity = try repository.save(
            route: StoreFixtures.route(), mode: .run,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(495),
            now: StoreFixtures.epoch
        )
        try repository.updateNote("첫 러닝", on: activity, now: StoreFixtures.epoch.addingTimeInterval(60))
        #expect(activity.note == "첫 러닝")
        #expect(activity.updatedAt > StoreFixtures.epoch)

        try repository.updateTrim(500, on: activity)
        #expect(activity.privacyTrimMeters == 500)
    }

    @Test("Tightening the trim marks existing artwork as stale")
    func trimStaleness() throws {
        // DESIGN.md §8.4 — a generated image cannot be re-trimmed retroactively,
        // so the UI has to say so rather than imply the new setting applied.
        let repository = try makeRepository()
        let activity = try repository.save(
            route: StoreFixtures.route(), mode: .run,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(495),
            privacyTrimMeters: 200
        )
        let artwork = try attach(to: activity, using: repository)
        #expect(!artwork.trimIsStale)

        try repository.updateTrim(500, on: activity)
        #expect(artwork.trimIsStale)
    }

    @Test("Delete-all clears rows and files")
    func deleteAll() throws {
        let repository = try makeRepository()
        for index in 0..<3 {
            let activity = try repository.save(
                route: StoreFixtures.route(points: 20), mode: .run,
                startedAt: StoreFixtures.epoch.addingTimeInterval(Double(index) * 3_600),
                endedAt: StoreFixtures.epoch.addingTimeInterval(Double(index) * 3_600 + 600)
            )
            _ = try attach(to: activity, using: repository)
        }

        try repository.deleteAllData()
        #expect(try repository.count() == 0)
        #expect(try repository.artworkStore.existingNames().isEmpty)
    }

    /// `ThumbnailRenderer` existed and nothing outside the tests called it:
    /// the one caller handed the full 1024² image in as the thumbnail, so every
    /// picture was stored twice at full size and the grid decoded all of it.
    @Test("The stored thumbnail is a thumbnail, not a second copy")
    func thumbnailIsScaledDown() throws {
        let repository = try makeRepository()
        let activity = try repository.save(
            route: StoreFixtures.route(), mode: .run,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(600)
        )
        let full = StoreFixtures.pngData(1024)
        let artwork = try repository.attachArtwork(
            to: activity, imageData: full,
            subject: "s", why: "w", stylePreset: "flat-vector", provider: "test",
            modelID: "m", conditionMode: "centreline", controlStrength: 1,
            renderIndex: 0, seed: 1, costCents: 0
        )

        let stored = try repository.artworkStore.data(named: artwork.thumbnailFileName)
        #expect(stored.count < full.count)
        #expect(try repository.artworkStore.data(named: artwork.imageFileName).count == full.count)
    }

    /// Losing the picture over a thumbnail would be the worse trade.
    @Test("Bytes that are not an image still attach")
    func undecodableImageStillAttaches() throws {
        let repository = try makeRepository()
        let activity = try repository.save(
            route: StoreFixtures.route(), mode: .run,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(600)
        )
        let artwork = try repository.attachArtwork(
            to: activity, imageData: Data([0x00, 0x01, 0x02]),
            subject: "s", why: "w", stylePreset: "flat-vector", provider: "test",
            modelID: "m", conditionMode: "centreline", controlStrength: 1,
            renderIndex: 0, seed: 1, costCents: 0
        )

        #expect(try repository.artworkStore.data(named: artwork.thumbnailFileName).count == 3)
    }

    private func attach(to activity: Activity, using repository: ActivityRepository) throws -> Artwork {
        try repository.attachArtwork(
            to: activity,
            imageData: StoreFixtures.pngData(64),
            subject: "웅크린 여우",
            why: "닫힌 곡선에 뾰족한 돌출",
            stylePreset: "flat-vector",
            provider: "test",
            modelID: "test-model",
            conditionMode: "centreline",
            controlStrength: 0.65,
            renderIndex: 5,
            seed: 42,
            costCents: 4
        )
    }
}

@MainActor
@Suite("FileArtworkStore and OrphanCleaner")
struct ArtworkStoreTests {

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("routepic-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Files round-trip")
    func roundTrip() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FileArtworkStore(directory: directory)
        let data = StoreFixtures.pngData()
        try store.write(data, named: "a.png")
        #expect(try store.data(named: "a.png") == data)
        #expect(try store.existingNames() == ["a.png"])

        try store.delete(named: "a.png")
        #expect(try store.existingNames().isEmpty)
    }

    @Test("Overwriting replaces atomically")
    func overwrite() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FileArtworkStore(directory: directory)
        try store.write(StoreFixtures.pngData(16), named: "a.png")
        let bigger = StoreFixtures.pngData(64)
        try store.write(bigger, named: "a.png")

        #expect(try store.data(named: "a.png") == bigger)
        #expect(try store.existingNames() == ["a.png"])
    }

    @Test("Deleting a missing file is not an error")
    func deleteMissing() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileArtworkStore(directory: directory)
        try store.delete(named: "nope.png")
    }

    @Test("Orphan files are swept once they are old enough")
    func sweepsOrphans() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FileArtworkStore(directory: directory)
        let container = try ActivityRepository.inMemoryContainer()
        let context = ModelContext(container)
        let repository = ActivityRepository(context: context, artworkStore: store)

        let activity = try repository.save(
            route: StoreFixtures.route(), mode: .run,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(495)
        )
        _ = try repository.attachArtwork(
            to: activity, imageData: StoreFixtures.pngData(64),
            subject: "s", why: "w", stylePreset: "p", provider: "t", modelID: "m",
            conditionMode: "c", controlStrength: 0.6, renderIndex: 0, seed: 1, costCents: 0
        )
        try store.write(StoreFixtures.pngData(), named: "orphan.png")

        // Zero minimum age: everything is sweepable.
        let report = try OrphanCleaner.sweep(context: context, store: store, minimumAge: 0)
        #expect(report.deletedNames == ["orphan.png"])
        #expect(try store.existingNames().count == 2)
    }

    @Test("A freshly written orphan is not swept")
    func spareRecentFiles() throws {
        // An image being written right now has no row yet; sweeping it would
        // delete the artwork the user is about to see.
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FileArtworkStore(directory: directory)
        let context = ModelContext(try ActivityRepository.inMemoryContainer())
        try store.write(StoreFixtures.pngData(), named: "in-flight.png")

        let report = try OrphanCleaner.sweep(context: context, store: store)
        #expect(report.deletedNames.isEmpty)
        #expect(report.skippedTooRecent == 1)
    }

    @Test("Rows whose files vanished are reported")
    func brokenArtworks() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FileArtworkStore(directory: directory)
        let context = ModelContext(try ActivityRepository.inMemoryContainer())
        let repository = ActivityRepository(context: context, artworkStore: store)
        let activity = try repository.save(
            route: StoreFixtures.route(), mode: .run,
            startedAt: StoreFixtures.epoch, endedAt: StoreFixtures.epoch.addingTimeInterval(495)
        )
        let artwork = try repository.attachArtwork(
            to: activity, imageData: StoreFixtures.pngData(64),
            subject: "s", why: "w", stylePreset: "p", provider: "t", modelID: "m",
            conditionMode: "c", controlStrength: 0.6, renderIndex: 0, seed: 1, costCents: 0
        )
        try store.delete(named: artwork.imageFileName)

        let broken = try OrphanCleaner.brokenArtworks(context: context, store: store)
        #expect(broken.count == 1)
    }
}
