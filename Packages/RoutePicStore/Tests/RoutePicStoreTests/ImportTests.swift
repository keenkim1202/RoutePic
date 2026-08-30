import Foundation
import RouteKit
import ShapeKit
import SwiftData
import Testing
@testable import RoutePicStore

@MainActor
@Suite("Import")
struct ImportTests {

    /// Health starts a route after the workout and can stop it early. Taking
    /// the dates from the coordinates puts a run that began at 23:50 under the
    /// next day, and in the wrong month section at a boundary.
    @Test("A source's own start and end beat its first and last fix")
    func givenBoundsWinOverFixTimestamps() throws {
        let repository = try makeRepository()
        let route = StoreFixtures.route(points: 60)
        let firstFix = try #require(route.points.first?.timestamp)
        let lastFix = try #require(route.points.last?.timestamp)

        let activity = try repository.importRoute(
            route.points,
            mode: .run,
            startedAt: firstFix.addingTimeInterval(-600),
            endedAt: lastFix.addingTimeInterval(300)
        )

        #expect(activity.startedAt == firstFix.addingTimeInterval(-600))
        #expect(activity.endedAt == lastFix.addingTimeInterval(300))
    }

    /// Nothing given, nothing invented: a GPX has only its fixes.
    @Test("Without bounds the fixes still decide")
    func fixTimestampsRemainTheDefault() throws {
        let repository = try makeRepository()
        let route = StoreFixtures.route(points: 60)
        let activity = try repository.importRoute(route.points, mode: .walk)

        #expect(activity.startedAt == route.points.first?.timestamp)
        #expect(activity.endedAt == route.points.last?.timestamp)
    }

    /// A GPX row starts at its first fix and a Health row at the workout,
    /// minutes earlier. Matching on the stored start re-imports a route the
    /// collection already holds.
    @Test("The same route is not imported twice because a source dated it differently")
    func differentBoundsAreStillTheSameRoute() throws {
        let repository = try makeRepository()
        let route = StoreFixtures.route(points: 60)
        let firstFix = try #require(route.points.first?.timestamp)

        _ = try repository.importRoute(route.points, mode: .run)

        #expect(throws: ActivityRepository.ImportFailure.alreadyImported) {
            try repository.importRoute(
                route.points,
                mode: .run,
                startedAt: firstFix.addingTimeInterval(-180),
                endedAt: try #require(route.points.last?.timestamp).addingTimeInterval(60)
            )
        }
    }

    /// `Activity.timeZoneID` is what the collection groups months by, so a run
    /// taken abroad must keep the zone it happened in.
    @Test("An imported activity keeps the zone it was recorded in")
    func importedZoneIsKept() throws {
        let repository = try makeRepository()
        let activity = try repository.importRoute(
            StoreFixtures.route(points: 60).points, mode: .run, timeZoneID: "Asia/Seoul"
        )
        #expect(activity.timeZoneID == "Asia/Seoul")

        // Nothing given: a recording made here belongs to here.
        let local = try repository.importRoute(
            StoreFixtures.route(points: 40).points, mode: .walk
        )
        #expect(local.timeZoneID == TimeZone.current.identifier)
    }

    /// `GPXDocument.write` drops fractional seconds, so a re-imported export
    /// has a first fix slightly *before* the stored start. Matching only on an
    /// interval that contains the fix would let the whole backup back in.
    @Test("A re-imported export is not a duplicate despite a truncated timestamp")
    func truncatedTimestampIsStillTheSameRoute() throws {
        let repository = try makeRepository()
        let route = StoreFixtures.route(points: 60)
        // Stored with milliseconds, as a recording is.
        let precise = route.points.map { point -> RoutePoint in
            var moved = point
            moved.timestamp = point.timestamp?.addingTimeInterval(0.7)
            return moved
        }
        _ = try repository.importRoute(precise, mode: .run)

        // Read back with whole seconds, as a GPX round trip gives.
        #expect(throws: ActivityRepository.ImportFailure.alreadyImported) {
            try repository.importRoute(route.points, mode: .run)
        }
    }

    private func makeRepository() throws -> ActivityRepository {
        ActivityRepository(
            context: ModelContext(try ActivityRepository.inMemoryContainer()),
            artworkStore: InMemoryArtworkStore()
        )
    }

    @Test("A GPX file becomes an activity with its gaps intact")
    func importsGPX() throws {
        let repository = try makeRepository()
        let source = StoreFixtures.route(points: 120, gapAfter: 60)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).gpx")
        try GPXDocument.write(source).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let activity = try repository.importGPX(at: url)

        #expect(activity.startedAt == source.points.first?.timestamp)
        #expect(activity.endedAt == source.points.last?.timestamp)
        #expect(activity.gapCount > 0)
        #expect(try repository.count() == 1)
    }

    @Test("Importing the same track twice does not duplicate it")
    func rejectsDuplicates() throws {
        let repository = try makeRepository()
        let points = StoreFixtures.route(points: 120).points

        try repository.importRoute(points)
        #expect(throws: ActivityRepository.ImportFailure.self) {
            try repository.importRoute(points)
        }
        #expect(try repository.count() == 1)
    }

    @Test("Two different routes starting in the same second both import")
    func sameStartDifferentRoutesBothImport() throws {
        let repository = try makeRepository()
        let first = StoreFixtures.route(points: 120).points
        // Same start, different shape — what a recovered journal saved twice
        // looks like, and what the export deliberately keeps as two files.
        let second = first.map {
            RoutePoint(
                latitude: $0.latitude + 0.01,
                longitude: $0.longitude,
                altitude: $0.altitude,
                timestamp: $0.timestamp,
                horizontalAccuracy: $0.horizontalAccuracy,
                verticalAccuracy: $0.verticalAccuracy
            )
        }

        try repository.importRoute(first)
        try repository.importRoute(second)
        #expect(try repository.count() == 2)
    }

    @Test("Re-importing a route's own exported GPX is caught as a duplicate")
    func gpxRoundTripIsADuplicate() throws {
        let repository = try makeRepository()
        let activity = try repository.importRoute(StoreFixtures.route(points: 120).points)

        // The export drops accuracy and sub-second times, so the stored blob and
        // its own GPX never match byte for byte. Restoring a backup must not
        // duplicate everything in it.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).gpx")
        try GPXDocument.write(try activity.route()).write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ActivityRepository.ImportFailure.alreadyImported) {
            try repository.importGPX(at: url)
        }
    }

    @Test("A file with impossible coordinates is refused, not crashed on")
    func rejectsNonFiniteCoordinates() throws {
        let repository = try makeRepository()
        var points = StoreFixtures.route(points: 120).points
        // `Double("NaN")` parses. Every distance downstream goes non-finite and
        // the first `Int(_:)` on one traps.
        points[3] = RoutePoint(
            latitude: .nan, longitude: .infinity, timestamp: points[3].timestamp
        )

        #expect(throws: ActivityRepository.ImportFailure.malformedCoordinates) {
            try repository.importRoute(points)
        }
    }

    @Test("A track too short to have a shape is refused")
    func rejectsShortTracks() throws {
        let repository = try makeRepository()
        // Five points, 10 m apart — under the 100 m floor.
        let points = Array(StoreFixtures.route(points: 5).points)

        #expect(throws: ActivityRepository.ImportFailure.self) {
            try repository.importRoute(points)
        }
    }

    @Test("One untimed point in the middle refuses the whole track")
    func rejectsPartiallyTimedTracks() throws {
        let repository = try makeRepository()
        var points = StoreFixtures.route(points: 120).points
        // Without this refusal the hole on both sides of point 60 is invisible
        // and the route is drawn straight across it.
        points[60].timestamp = nil

        #expect(throws: ActivityRepository.ImportFailure.partiallyTimed) {
            try repository.importRoute(points)
        }
    }

    @Test("Two activities that start in the same second get their own files")
    func exportNamesCollide() throws {
        let repository = try makeRepository()
        let route = StoreFixtures.route(points: 120)
        // Straight through `save`, the way a recovered journal saved twice would
        // arrive — the import path's duplicate guard does not see it.
        try repository.save(
            route: route, mode: .walk,
            startedAt: route.points[0].timestamp!, endedAt: route.points.last!.timestamp!
        )
        try repository.save(
            route: route, mode: .walk,
            startedAt: route.points[0].timestamp!, endedAt: route.points.last!.timestamp!
        )

        let archive = try repository.exportArchive()
        defer { try? FileManager.default.removeItem(at: archive) }
        #expect(try unzipListing(archive).filter { $0.hasSuffix(".gpx") }.count == 2)
    }

    @Test("A track with no clock is refused rather than guessed at")
    func rejectsUntimedTracks() throws {
        let repository = try makeRepository()
        let points = StoreFixtures.route(points: 120).points.map {
            RoutePoint(latitude: $0.latitude, longitude: $0.longitude)
        }

        #expect(throws: ActivityRepository.ImportFailure.self) {
            try repository.importRoute(points)
        }
    }
}

@MainActor
@Suite("Export")
struct ExportTests {

    private func makeRepository() throws -> ActivityRepository {
        ActivityRepository(
            context: ModelContext(try ActivityRepository.inMemoryContainer()),
            artworkStore: InMemoryArtworkStore()
        )
    }

    @Test("Delete-all takes the exported archives with it")
    func deleteAllRemovesArchives() throws {
        let repository = try makeRepository()
        try repository.importRoute(StoreFixtures.route(points: 120).points)

        let archive = try repository.exportArchive()
        #expect(FileManager.default.fileExists(atPath: archive.path))

        // The zip is a full copy — coordinates, notes, pictures. Leaving it in
        // the temporary directory makes the delete-all confirmation a lie.
        try repository.deleteAllData()
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }

    @Test("The archive holds one GPX per activity and an index")
    func exportsEverything() throws {
        let repository = try makeRepository()
        try repository.importRoute(StoreFixtures.route(points: 120).points)
        try repository.importRoute(
            StoreFixtures.route(points: 120).points.map {
                RoutePoint(
                    latitude: $0.latitude + 1,
                    longitude: $0.longitude,
                    altitude: $0.altitude,
                    timestamp: $0.timestamp?.addingTimeInterval(86_400),
                    horizontalAccuracy: $0.horizontalAccuracy,
                    verticalAccuracy: $0.verticalAccuracy
                )
            }
        )

        let archive = try repository.exportArchive()
        defer { try? FileManager.default.removeItem(at: archive) }

        #expect(FileManager.default.fileExists(atPath: archive.path))

        let listing = try unzipListing(archive)
        #expect(listing.filter { $0.hasSuffix(".gpx") }.count == 2)
        #expect(listing.contains { $0.hasSuffix("activities.json") })
    }

}

/// Reads the archive back with the system `unzip`. Tests run on macOS, so this
/// checks the real file rather than the directory it was built from.
private func unzipListing(_ url: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z1", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}
