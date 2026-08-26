import Foundation
import RouteKit
import ShapeKit

extension ActivityRepository {

    static let archivePrefix = "RoutePic-export-"

    static let exportDay = Date.ISO8601FormatStyle(dateSeparator: .dash)
        .year().month().day()

    /// Colons are legal in a file name and then break on every other system the
    /// person might open the zip on, so the time separator goes.
    static let exportFile = Date.ISO8601FormatStyle(
        dateSeparator: .dash, timeSeparator: .omitted
    ).year().month().day().time(includingFractionalSeconds: false)

    /// Writes everything the app holds into one zip — the counterpart to
    /// delete-all (`DESIGN.md` §11). Routes go out untrimmed: trimming the
    /// owner's own copy would be losing data rather than protecting it.
    ///
    /// ponytail: built on the main actor, where the SwiftData models live. Move
    /// the file writing off it if someone with thousands of activities complains.
    public func exportArchive(now: Date = Date()) throws -> URL {
        let stamp = now.formatted(Self.exportDay)
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.archivePrefix)\(stamp)", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let all = try activities(limit: .max)
        var index: [[String: String]] = []

        for activity in all {
            // The id is in the name because start time and mode do not make one:
            // a recovered journal can be saved twice, and the second file would
            // overwrite the first while the index still pointed both at it.
            let name = "\(activity.startedAt.formatted(Self.exportFile))-\(activity.mode.rawValue)"
                + "-\(activity.id.uuidString.prefix(8))"
            let route = try activity.route()
            try GPXDocument.write(route)
                .write(
                    to: staging.appendingPathComponent("\(name).gpx"),
                    atomically: true,
                    encoding: .utf8
                )

            for artwork in activity.artworks {
                // A missing image file is not a reason to abandon the export —
                // the person still wants the other several hundred activities.
                guard let data = try? artworkStore.data(named: artwork.imageFileName) else { continue }
                try data.write(
                    to: staging.appendingPathComponent("\(name)-\(artwork.id.uuidString).png")
                )
            }

            index.append([
                "file": "\(name).gpx",
                "mode": activity.modeRaw,
                "startedAt": activity.startedAt.formatted(.iso8601),
                "distanceMeters": String(Int(activity.distanceMeters)),
                "note": activity.note ?? "",
                "placeName": activity.placeName ?? "",
            ])
        }

        try JSONSerialization
            .data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("activities.json"))

        return try zip(staging, named: "\(Self.archivePrefix)\(stamp).zip")
    }

    /// Removes every archive this device has written.
    ///
    /// An export is a full copy — coordinates, notes, pictures — sitting in the
    /// temporary directory until the system decides to reclaim it. Delete-all
    /// promises the data is gone from the device, and leaving these behind makes
    /// that promise false (`DESIGN.md` §11).
    func discardExportArchives() {
        let temporary = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix(Self.archivePrefix) {
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }

    /// Zips a directory without a zip library: `NSFileCoordinator` builds one
    /// for `.forUploading`, and the coordinated read is the only place that
    /// archive exists, so it is copied out before the block returns.
    private func zip(_ directory: URL, named name: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)

        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator().coordinate(
            readingItemAt: directory, options: [.forUploading], error: &coordinationError
        ) { archive in
            do { try FileManager.default.copyItem(at: archive, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return destination
    }
}
