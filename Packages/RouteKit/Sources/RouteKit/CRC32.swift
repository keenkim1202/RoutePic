import Foundation

/// Standard CRC-32 (IEEE 802.3), table-driven.
///
/// Written out rather than pulled from zlib so `RouteKit` keeps its only
/// dependency on `ShapeKit`, and so the journal format does not depend on a
/// system library's availability on either platform.
public enum CRC32 {

    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
