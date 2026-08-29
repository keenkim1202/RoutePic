import Foundation

/// Compact binary encoding for a recorded route.
///
/// `DESIGN.md` §8.2 — an hour of running is ~3,600 fixes. Storing those as
/// SwiftData rows makes feed scrolling collapse, so the whole route lives in one
/// `Data` blob on the `Activity`.
///
/// Layout: delta + zigzag varint, one stream per field rather than interleaved,
/// so a decoder that only needs coordinates never touches the accuracy bytes.
///
/// ```
/// "RPL1"        4 bytes magic + version
/// flags         1 byte   bit0 altitude, bit1 timestamp, bit2 horizontalAccuracy
/// count         varint
/// latitude      count × zigzag varint, deltas of round(lat × 1e6)
/// longitude     count × zigzag varint
/// [altitude]    count × zigzag varint, deltas of round(alt × 100)   — centimetres
/// [timestamp]   count × zigzag varint, deltas of round(t × 1000)    — milliseconds
/// [accuracy]    count × varint,        round(hAcc × 100)            — not delta-coded
/// ```
///
/// An optional stream is present only when **every** point carries that field.
/// Partial coverage drops the stream rather than inventing sentinel values.
public enum PolylineCodec {

    /// 1e6 → ~0.11 m. Enough that a re-decoded route renders identically.
    public static let coordinateScale = 1_000_000.0
    public static let altitudeScale = 100.0
    public static let timestampScale = 1000.0
    public static let accuracyScale = 100.0

    static let magic: [UInt8] = Array("RPL1".utf8)

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let altitude = Flags(rawValue: 1 << 0)
        public static let timestamp = Flags(rawValue: 1 << 1)
        public static let horizontalAccuracy = Flags(rawValue: 1 << 2)
    }

    public enum DecodingError: DescribedError, Equatable {
        case badMagic
        case truncated(field: String)
        case varintOverflow

        public var description: String {
            switch self {
            case .badMagic: return "Not a RoutePic polyline blob."
            case .truncated(let field): return "Blob ended mid-stream while reading \(field)."
            case .varintOverflow: return "Varint exceeded 64 bits; blob is corrupt."
            }
        }
    }

    // MARK: - Encoding

    public static func encode(_ points: [RoutePoint]) -> Data {
        var output = Data(magic)

        var flags = Flags()
        if !points.isEmpty {
            if points.allSatisfy({ $0.altitude != nil }) { flags.insert(.altitude) }
            if points.allSatisfy({ $0.timestamp != nil }) { flags.insert(.timestamp) }
            if points.allSatisfy({ $0.horizontalAccuracy != nil }) {
                flags.insert(.horizontalAccuracy)
            }
        }
        output.append(flags.rawValue)
        appendVarint(UInt64(points.count), to: &output)

        appendDeltaStream(points.map { quantize($0.latitude, coordinateScale) }, to: &output)
        appendDeltaStream(points.map { quantize($0.longitude, coordinateScale) }, to: &output)

        if flags.contains(.altitude) {
            appendDeltaStream(points.map { quantize($0.altitude!, altitudeScale) }, to: &output)
        }
        if flags.contains(.timestamp) {
            appendDeltaStream(
                points.map { quantize($0.timestamp!.timeIntervalSince1970, timestampScale) },
                to: &output
            )
        }
        if flags.contains(.horizontalAccuracy) {
            for point in points {
                appendVarint(UInt64(max(0, quantize(point.horizontalAccuracy!, accuracyScale))), to: &output)
            }
        }

        return output
    }

    // MARK: - Decoding

    public static func decode(_ data: Data) throws -> [RoutePoint] {
        var cursor = Cursor(data)

        guard try cursor.readBytes(4).elementsEqual(magic) else { throw DecodingError.badMagic }
        let flags = Flags(rawValue: try cursor.readByte())
        let count = Int(try cursor.readVarint())
        guard count > 0 else { return [] }

        let latitudes = try cursor.readDeltaStream(count: count, field: "latitude")
        let longitudes = try cursor.readDeltaStream(count: count, field: "longitude")

        var altitudes: [Int64]?
        if flags.contains(.altitude) {
            altitudes = try cursor.readDeltaStream(count: count, field: "altitude")
        }
        var timestamps: [Int64]?
        if flags.contains(.timestamp) {
            timestamps = try cursor.readDeltaStream(count: count, field: "timestamp")
        }
        var accuracies: [Int64]?
        if flags.contains(.horizontalAccuracy) {
            var values: [Int64] = []
            values.reserveCapacity(count)
            for _ in 0..<count {
                values.append(Int64(try cursor.readVarint()))
            }
            accuracies = values
        }

        return (0..<count).map { i in
            RoutePoint(
                latitude: Double(latitudes[i]) / coordinateScale,
                longitude: Double(longitudes[i]) / coordinateScale,
                altitude: altitudes.map { Double($0[i]) / altitudeScale },
                timestamp: timestamps.map {
                    Date(timeIntervalSince1970: Double($0[i]) / timestampScale)
                },
                horizontalAccuracy: accuracies.map { Double($0[i]) / accuracyScale }
            )
        }
    }

    // MARK: - Primitives

    private static func quantize(_ value: Double, _ scale: Double) -> Int64 {
        Int64((value * scale).rounded())
    }

    private static func appendDeltaStream(_ values: [Int64], to output: inout Data) {
        var previous: Int64 = 0
        for value in values {
            appendVarint(zigzag(value &- previous), to: &output)
            previous = value
        }
    }

    static func zigzag(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }

    static func unzigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: (value >> 1)) ^ -(Int64(bitPattern: value & 1))
    }

    static func appendVarint(_ value: UInt64, to output: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            output.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        output.append(UInt8(remaining))
    }

    private struct Cursor {
        let bytes: [UInt8]
        var index = 0

        init(_ data: Data) { self.bytes = Array(data) }

        mutating func readByte() throws -> UInt8 {
            guard index < bytes.count else { throw DecodingError.truncated(field: "header") }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func readBytes(_ n: Int) throws -> ArraySlice<UInt8> {
            guard index + n <= bytes.count else { throw DecodingError.truncated(field: "magic") }
            defer { index += n }
            return bytes[index..<(index + n)]
        }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < bytes.count else { throw DecodingError.truncated(field: "varint") }
                guard shift < 64 else { throw DecodingError.varintOverflow }
                let byte = bytes[index]
                index += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { break }
                shift += 7
            }
            return result
        }

        mutating func readDeltaStream(count: Int, field: String) throws -> [Int64] {
            var values: [Int64] = []
            values.reserveCapacity(count)
            var accumulator: Int64 = 0
            for _ in 0..<count {
                guard index < bytes.count else { throw DecodingError.truncated(field: field) }
                accumulator &+= unzigzag(try readVarint())
                values.append(accumulator)
            }
            return values
        }
    }
}
