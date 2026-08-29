import Foundation
import ShapeKit

/// Append-only, crash-tolerant record of a session in progress.
///
/// `DESIGN.md` §5.4. What this guarantees and what it does not:
///
/// - **Recovery** — fixes already received survive a crash, a jetsam kill, a
///   force quit or a reboot. Guaranteed, up to the last flush.
/// - **Continuity** — fixes that would have arrived while the app was dead.
///   **Not** guaranteed, and nothing at this layer can make it so.
///
/// v0.1 of the design called for a synchronous write per fix. That costs power
/// and I/O without buying durability: a half-written record is still a corrupt
/// record. Framing with a CRC and flushing in small batches gives a file whose
/// damaged tail can be discarded and whose good prefix is always readable.
public final class SessionJournal: @unchecked Sendable {

    /// `[magic 2][length 2][payload][crc32 4]`
    static let frameMagic: UInt16 = 0x5250        // "RP"

    public struct Policy: Sendable {
        public var framesPerFlush: Int
        public var maximumFlushInterval: TimeInterval
        /// Cumulative statistics are snapshotted this often so recovering a long
        /// session does not mean replaying every fix.
        public var checkpointInterval: TimeInterval

        public init(
            framesPerFlush: Int = 5,
            maximumFlushInterval: TimeInterval = 10,
            checkpointInterval: TimeInterval = 300
        ) {
            self.framesPerFlush = framesPerFlush
            self.maximumFlushInterval = maximumFlushInterval
            self.checkpointInterval = checkpointInterval
        }
    }

    public enum Failure: DescribedError {
        case cannotCreate(URL, underlying: String)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .cannotCreate(let url, let underlying):
                return "Could not create journal at \(url.path): \(underlying)"
            case .writeFailed(let detail):
                return "Journal write failed: \(detail)"
            }
        }
    }

    public enum Record: Sendable, Equatable {
        case header(sessionID: UUID, mode: RecordingMode, startedAt: Date)
        case fix(LocationFix)
        case segmentBoundary(kind: SegmentKind, at: Date)
        case checkpoint(distanceMeters: Double, movingDuration: TimeInterval, at: Date)
    }

    public let url: URL
    public let policy: Policy

    private let handle: FileHandle
    private var buffer = Data()
    private var framesSinceFlush = 0
    private var lastFlush: Date
    private let lock = NSLock()

    private var _writeFailure: String?
    private var isClosed = false

    /// Set when a write fails. The session keeps recording in memory and the UI
    /// warns, rather than the recording dying silently (`DESIGN.md` §14.1).
    ///
    /// Read under the lock: this object is `@unchecked Sendable` and the writer
    /// runs on whichever thread delivered the fix.
    public var writeFailure: String? {
        lock.withLock { _writeFailure }
    }

    /// Records still held in memory because a write failed. Non-zero means the
    /// session is at risk.
    public var unflushedByteCount: Int {
        lock.withLock { buffer.count }
    }

    public init(url: URL, policy: Policy = Policy(), now: Date = Date()) throws {
        self.url = url
        self.policy = policy
        self.lastFlush = now

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw Failure.cannotCreate(url, underlying: "createFile returned false")
                }
            }
            #if os(iOS)
            // The screen is locked for most of a run, so the journal must stay
            // writable after first unlock.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
            #endif
            self.handle = try FileHandle(forWritingTo: url)
            try self.handle.seekToEnd()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.cannotCreate(url, underlying: error.localizedDescription)
        }
    }

    deinit {
        try? handle.close()
    }

    public func append(_ record: Record, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }

        buffer.append(Self.frame(record))
        framesSinceFlush += 1

        let dueByCount = framesSinceFlush >= policy.framesPerFlush
        let dueByTime = now.timeIntervalSince(lastFlush) >= policy.maximumFlushInterval
        if dueByCount || dueByTime {
            flushLocked(now: now)
        }
    }

    /// Forces everything buffered to disk.
    ///
    /// Call on background transition: that is the moment before the app is most
    /// likely to be killed.
    public func flush(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        flushLocked(now: now)
    }

    private func flushLocked(now: Date) {
        guard !buffer.isEmpty else {
            lastFlush = now
            return
        }
        do {
            try handle.write(contentsOf: buffer)
        } catch {
            // Keep the buffer: a full disk may free up, and losing the session
            // is worse than holding a few kilobytes in memory.
            _writeFailure = error.localizedDescription
            return
        }

        // The bytes are with the OS now, so the buffer is cleared *before*
        // syncing. Keeping it across a failed `synchronize()` would append the
        // same frames again on the next flush, duplicating coordinates and
        // segment boundaries in the recovered route.
        buffer.removeAll(keepingCapacity: true)
        framesSinceFlush = 0
        lastFlush = now

        do {
            try handle.synchronize()
            _writeFailure = nil
        } catch {
            // Written but not durable. Worth surfacing, not worth rewriting.
            _writeFailure = "Not yet written to disk: \(error.localizedDescription)"
        }
    }

    /// Flushes and closes. Returns whether everything reached the file.
    ///
    /// A failed flush leaves the handle **open** and the journal usable: closing
    /// it would strand the buffered records in memory with no way to retry, and
    /// those records are the part of the session not yet on disk.
    @discardableResult
    public func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return true }

        flushLocked(now: Date())
        guard buffer.isEmpty else { return false }

        isClosed = true
        try? handle.close()
        return true
    }

    // MARK: - Framing

    /// The length field is 16 bits, so a payload cannot exceed this. No record
    /// comes close today; the guard exists because silently truncating the high
    /// bits would misplace every frame boundary after it.
    static let maximumPayloadSize = 0xFFFF

    static func frame(_ record: Record) -> Data {
        let payload = encode(record)
        precondition(
            payload.count <= maximumPayloadSize,
            "Journal payload of \(payload.count) bytes exceeds the 16-bit length field."
        )
        var frame = Data()
        frame.append(UInt8(frameMagic >> 8))
        frame.append(UInt8(frameMagic & 0xFF))
        frame.append(UInt8(payload.count >> 8))
        frame.append(UInt8(payload.count & 0xFF))
        frame.append(payload)

        let crc = CRC32.checksum(payload)
        frame.append(UInt8((crc >> 24) & 0xFF))
        frame.append(UInt8((crc >> 16) & 0xFF))
        frame.append(UInt8((crc >> 8) & 0xFF))
        frame.append(UInt8(crc & 0xFF))
        return frame
    }

    static func encode(_ record: Record) -> Data {
        var payload = Data()
        switch record {
        case .header(let sessionID, let mode, let startedAt):
            payload.append(0x01)
            payload.append(contentsOf: sessionID.uuidString.utf8Prefixed())
            payload.append(contentsOf: mode.rawValue.utf8Prefixed())
            payload.append(contentsOf: startedAt.timeIntervalSince1970.bytes)
        case .fix(let fix):
            payload.append(0x02)
            for value in [
                fix.latitude, fix.longitude, fix.altitude,
                fix.timestamp.timeIntervalSince1970,
                fix.horizontalAccuracy, fix.verticalAccuracy, fix.speed,
            ] {
                payload.append(contentsOf: value.bytes)
            }
        case .segmentBoundary(let kind, let at):
            payload.append(0x03)
            payload.append(contentsOf: kind.rawValue.utf8Prefixed())
            payload.append(contentsOf: at.timeIntervalSince1970.bytes)
        case .checkpoint(let distance, let movingDuration, let at):
            payload.append(0x04)
            for value in [distance, movingDuration, at.timeIntervalSince1970] {
                payload.append(contentsOf: value.bytes)
            }
        }
        return payload
    }
}

extension Double {
    var bytes: [UInt8] {
        withUnsafeBytes(of: bitPattern.bigEndian) { Array($0) }
    }

    init?(bigEndianBytes: ArraySlice<UInt8>) {
        guard bigEndianBytes.count == 8 else { return nil }
        var pattern: UInt64 = 0
        for byte in bigEndianBytes { pattern = (pattern << 8) | UInt64(byte) }
        self = Double(bitPattern: pattern)
    }
}

extension String {
    /// Length-prefixed UTF-8, so a decoder never has to guess where a field ends.
    func utf8Prefixed() -> [UInt8] {
        let bytes = Array(utf8)
        return [UInt8(min(bytes.count, 255))] + bytes.prefix(255)
    }
}
