import Foundation
import Testing
@testable import ShapeKit

@Suite("PolylineCodec")
struct PolylineCodecTests {

    @Test("Round-trip preserves coordinates to 1e-6 degrees")
    func roundTripCoordinates() throws {
        let original = Fixtures.wanderingWalk(samples: 400).points
        let decoded = try PolylineCodec.decode(PolylineCodec.encode(original))

        #expect(decoded.count == original.count)
        for (a, b) in zip(original, decoded) {
            #expect(abs(a.latitude - b.latitude) < 1e-6)
            #expect(abs(a.longitude - b.longitude) < 1e-6)
        }
    }

    @Test("Round-trip preserves altitude, timestamp and accuracy")
    func roundTripOptionalStreams() throws {
        let original = Fixtures.wanderingWalk(samples: 50).points
        let decoded = try PolylineCodec.decode(PolylineCodec.encode(original))

        for (a, b) in zip(original, decoded) {
            #expect(abs((a.altitude ?? 0) - (b.altitude ?? 0)) < 0.01)
            #expect(abs((a.horizontalAccuracy ?? 0) - (b.horizontalAccuracy ?? 0)) < 0.01)
            let ta = a.timestamp?.timeIntervalSince1970 ?? 0
            let tb = b.timestamp?.timeIntervalSince1970 ?? 0
            #expect(abs(ta - tb) < 0.001)
        }
    }

    @Test("A field missing on any point drops that whole stream")
    func partialOptionalCoverageDropsStream() throws {
        // Rather than inventing a sentinel that would decode as a real altitude.
        var points = Fixtures.wanderingWalk(samples: 10).points
        points[3].altitude = nil

        let decoded = try PolylineCodec.decode(PolylineCodec.encode(points))
        #expect(decoded.allSatisfy { $0.altitude == nil })
        #expect(decoded.allSatisfy { $0.horizontalAccuracy != nil })
    }

    @Test("Encoded size stays within the design's 4-6 bytes per point budget")
    func encodedSize() {
        // DESIGN.md §8.2 — this is the claim that justifies a single blob
        // instead of one SwiftData row per fix.
        let points = Fixtures.wanderingWalk(samples: 3_600).points
        let coordinatesOnly = points.map {
            RoutePoint(latitude: $0.latitude, longitude: $0.longitude)
        }
        let bytesPerPoint = Double(PolylineCodec.encode(coordinatesOnly).count) / 3_600
        #expect(bytesPerPoint < 6)
    }

    @Test("Empty route round-trips")
    func emptyRoute() throws {
        #expect(try PolylineCodec.decode(PolylineCodec.encode([])).isEmpty)
    }

    @Test("Single point round-trips")
    func singlePoint() throws {
        let decoded = try PolylineCodec.decode(PolylineCodec.encode(Fixtures.singlePoint.points))
        #expect(decoded.count == 1)
    }

    @Test("Zigzag encoding round-trips signed values")
    func zigzag() {
        for value in [Int64(0), 1, -1, 63, -64, 1_000_000, -1_000_000, Int64.max, Int64.min] {
            #expect(PolylineCodec.unzigzag(PolylineCodec.zigzag(value)) == value)
        }
    }

    @Test("Foreign data is rejected, not misread")
    func badMagic() {
        #expect(throws: PolylineCodec.DecodingError.badMagic) {
            try PolylineCodec.decode(Data("NOPE????".utf8))
        }
    }

    @Test("Truncated blobs throw instead of returning partial garbage")
    func truncated() {
        let full = PolylineCodec.encode(Fixtures.wanderingWalk(samples: 100).points)
        let cut = full.prefix(full.count / 2)
        #expect(throws: (any Error).self) {
            try PolylineCodec.decode(Data(cut))
        }
    }

    @Test("Dateline coordinates survive the round-trip")
    func datelineRoundTrip() throws {
        let original = Fixtures.datelineCrossing.points
        let decoded = try PolylineCodec.decode(PolylineCodec.encode(original))
        for (a, b) in zip(original, decoded) {
            #expect(abs(a.longitude - b.longitude) < 1e-6)
        }
    }

    /// A damaged blob can claim any count. Converting the claim traps above
    /// `Int.max`, and a merely enormous one fills arrays until the process
    /// dies — and the collection decodes these while somebody scrolls.
    @Test("A count larger than the bytes behind it is refused, not allocated")
    func absurdCountIsRefused() {
        var blob = Data("RPL1".utf8)
        blob.append(0)
        // 0xFF… varint: the largest UInt64 the format can express.
        blob.append(contentsOf: [UInt8](repeating: 0xFF, count: 9) + [0x01])

        #expect(throws: PolylineCodec.DecodingError.truncated(field: "count")) {
            try PolylineCodec.decode(blob)
        }
    }

    @Test("A plausible but unbacked count is refused too")
    func unbackedCountIsRefused() {
        var blob = Data("RPL1".utf8)
        blob.append(0)
        blob.append(100)  // one varint byte, claiming 100 points, nothing behind them

        #expect(throws: PolylineCodec.DecodingError.truncated(field: "count")) {
            try PolylineCodec.decode(blob)
        }
    }

    /// The count guard did not cover this one: accuracy is a plain varint, and
    /// narrowing it traps the same way. The collection decodes these.
    @Test("An accuracy varint beyond Int64 is refused, not converted")
    func absurdAccuracyIsRefused() {
        var blob = Data("RPL1".utf8)
        blob.append(PolylineCodec.Flags.horizontalAccuracy.rawValue)
        blob.append(1)                                  // one point
        blob.append(contentsOf: [0, 0])                 // its latitude and longitude
        blob.append(contentsOf: [UInt8](repeating: 0xFF, count: 9) + [0x01])

        #expect(throws: PolylineCodec.DecodingError.varintOverflow) {
            try PolylineCodec.decode(blob)
        }
    }
}
