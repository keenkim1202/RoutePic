import Foundation
import ShapeKit

/// Reads a journal back, tolerating a damaged tail.
///
/// `DESIGN.md` §5.4 — a crash usually leaves the last frame half-written. That
/// frame is discarded and everything before it is kept; refusing the whole file
/// because of its last 40 bytes would lose the run.
public enum JournalReader {

    public struct Recovered: Sendable {
        public var sessionID: UUID?
        public var mode: RecordingMode?
        public var startedAt: Date?
        public var route: Route
        public var lastCheckpoint: (distanceMeters: Double, movingDuration: TimeInterval)?

        /// Frames after the first corrupt one. Non-zero means the file was
        /// truncated mid-write — expected after a crash, not an error.
        public var discardedTailBytes: Int
        public var sawCorruption: Bool
    }

    public static func read(contentsOf url: URL) throws -> Recovered {
        try read(Data(contentsOf: url))
    }

    public static func read(_ data: Data) -> Recovered {
        let bytes = Array(data)
        var cursor = 0

        var sessionID: UUID?
        var mode: RecordingMode?
        var startedAt: Date?
        var checkpoint: (Double, TimeInterval)?

        var points: [RoutePoint] = []
        var segments: [RouteSegment] = []
        var runStart = 0
        var sawCorruption = false

        /// Closes the current moving run, and records a boundary of `kind`.
        func closeRun(_ kind: SegmentKind) {
            if points.count > runStart {
                segments.append(
                    RouteSegment(startIndex: runStart, endIndex: points.count, kind: .moving)
                )
            }
            segments.append(
                RouteSegment(startIndex: points.count, endIndex: points.count, kind: kind)
            )
            runStart = points.count
        }

        frames: while cursor + 8 <= bytes.count {
            let magic = (UInt16(bytes[cursor]) << 8) | UInt16(bytes[cursor + 1])
            guard magic == SessionJournal.frameMagic else {
                sawCorruption = true
                break frames
            }
            let length = (Int(bytes[cursor + 2]) << 8) | Int(bytes[cursor + 3])
            let payloadStart = cursor + 4
            let payloadEnd = payloadStart + length
            guard payloadEnd + 4 <= bytes.count else {
                sawCorruption = true
                break frames
            }

            let payload = bytes[payloadStart..<payloadEnd]
            var storedCRC: UInt32 = 0
            for i in 0..<4 { storedCRC = (storedCRC << 8) | UInt32(bytes[payloadEnd + i]) }
            guard CRC32.checksum(payload) == storedCRC else {
                sawCorruption = true
                break frames
            }

            switch decode(payload) {
            case .header(let id, let recordedMode, let start):
                sessionID = id
                mode = recordedMode
                startedAt = start
            case .fix(let fix):
                points.append(fix.routePoint)
            case .segmentBoundary(let kind, _):
                closeRun(kind)
            case .checkpoint(let distance, let movingDuration, _):
                checkpoint = (distance, movingDuration)
            case nil:
                sawCorruption = true
                break frames
            }

            cursor = payloadEnd + 4
        }

        if points.count > runStart {
            segments.append(
                RouteSegment(startIndex: runStart, endIndex: points.count, kind: .moving)
            )
        }

        // Bytes left over that are too short to be a frame header are a
        // truncated write, not padding. Without this the loop exits quietly and
        // the caller is told the file was clean — so the UI would not mention
        // that the end of the recording was lost.
        if cursor < bytes.count { sawCorruption = true }

        return Recovered(
            sessionID: sessionID,
            mode: mode,
            startedAt: startedAt,
            route: Route(points: points, segments: segments),
            lastCheckpoint: checkpoint.map { (distanceMeters: $0.0, movingDuration: $0.1) },
            discardedTailBytes: bytes.count - cursor,
            sawCorruption: sawCorruption
        )
    }

    static func decode(_ payload: ArraySlice<UInt8>) -> SessionJournal.Record? {
        var index = payload.startIndex
        guard index < payload.endIndex else { return nil }
        let kind = payload[index]
        index += 1

        func readString() -> String? {
            guard index < payload.endIndex else { return nil }
            let length = Int(payload[index])
            index += 1
            guard index + length <= payload.endIndex else { return nil }
            let slice = payload[index..<(index + length)]
            index += length
            return String(decoding: slice, as: UTF8.self)
        }

        func readDouble() -> Double? {
            guard index + 8 <= payload.endIndex else { return nil }
            let value = Double(bigEndianBytes: payload[index..<(index + 8)])
            index += 8
            return value
        }

        /// A record must consume its payload exactly. Trailing bytes mean the
        /// length field and the schema disagree — a frame written by a different
        /// version, or a corruption the CRC happened not to catch.
        func exactlyConsumed<T>(_ value: T?) -> T? {
            index == payload.endIndex ? value : nil
        }

        switch kind {
        case 0x01:
            guard
                let idString = readString(), let id = UUID(uuidString: idString),
                let modeString = readString(), let mode = RecordingMode(rawValue: modeString),
                let start = readDouble()
            else { return nil }
            return exactlyConsumed(.header(
                sessionID: id, mode: mode, startedAt: Date(timeIntervalSince1970: start)
            ))
        case 0x02:
            var values: [Double] = []
            for _ in 0..<7 {
                guard let value = readDouble() else { return nil }
                values.append(value)
            }
            return exactlyConsumed(.fix(
                LocationFix(
                    latitude: values[0], longitude: values[1], altitude: values[2],
                    timestamp: Date(timeIntervalSince1970: values[3]),
                    horizontalAccuracy: values[4], verticalAccuracy: values[5], speed: values[6]
                )
            ))
        case 0x03:
            guard
                let kindString = readString(), let segmentKind = SegmentKind(rawValue: kindString),
                let at = readDouble()
            else { return nil }
            return exactlyConsumed(
                .segmentBoundary(kind: segmentKind, at: Date(timeIntervalSince1970: at))
            )
        case 0x04:
            guard
                let distance = readDouble(), let movingDuration = readDouble(),
                let at = readDouble()
            else { return nil }
            return exactlyConsumed(.checkpoint(
                distanceMeters: distance, movingDuration: movingDuration,
                at: Date(timeIntervalSince1970: at)
            ))
        default:
            return nil
        }
    }
}
