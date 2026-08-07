import Foundation
import ShapeKit

/// Finds and restores sessions that never finished.
///
/// `DESIGN.md` §5.4. This restores what was *received*; it cannot restore what
/// was never received. The distinction matters enough that `Candidate` reports
/// both, and the UI is expected to say so rather than presenting a route with
/// an invisible hole in it.
public enum SessionRecovery {

    public static let directoryName = "journals"
    public static let fileExtension = "jrn"

    public struct Candidate: Sendable {
        public var url: URL
        public var sessionID: UUID?
        public var mode: RecordingMode
        public var startedAt: Date?
        public var route: Route
        public var statistics: ActivityStatistics

        /// The journal's tail was unreadable — normal after a crash or a kill,
        /// since the last frame was mid-write.
        public var hadDamagedTail: Bool

        /// Dropouts inside the recording. These are stretches the app was not
        /// running or had no signal, and they are **not** recoverable.
        public var gapCount: Int

        public var isUsable: Bool { !route.movingRuns.isEmpty }
    }

    public static func journalDirectory(
        in base: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let root = try base ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func journalURL(for sessionID: UUID, in directory: URL) -> URL {
        directory
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(fileExtension)
    }

    /// Every unfinished journal found, newest first.
    public static func candidates(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [Candidate] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension == fileExtension }
            .compactMap { candidate(at: $0) }
            .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }

    public static func candidate(at url: URL) -> Candidate? {
        guard let recovered = try? JournalReader.read(contentsOf: url) else { return nil }
        return Candidate(
            url: url,
            sessionID: recovered.sessionID,
            // A journal whose header frame was lost still has usable fixes;
            // walking is the safest assumption for filtering already applied.
            mode: recovered.mode ?? .walk,
            startedAt: recovered.startedAt,
            route: recovered.route,
            statistics: ActivityStatistics.compute(for: recovered.route),
            hadDamagedTail: recovered.sawCorruption,
            gapCount: recovered.route.segments.count { $0.kind == .gap }
        )
    }

    /// Deletes a journal once its session has been saved or discarded.
    @discardableResult
    public static func discard(_ candidate: Candidate, fileManager: FileManager = .default) -> Bool {
        (try? fileManager.removeItem(at: candidate.url)) != nil
    }
}
