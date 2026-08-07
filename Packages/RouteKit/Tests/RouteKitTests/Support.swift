import Foundation
import ShapeKit
@testable import RouteKit

/// Builders for synthetic fixes.
///
/// `DESIGN.md` §14.2 T-6 calls for location simulation with outliers and jumps
/// injected. Because the pipeline works on `LocationFix` rather than
/// `CLLocation`, that becomes an ordinary unit test.
enum Sim {

    static let baseLatitude = 37.5665
    static let baseLongitude = 126.9780
    static let epoch = Date(timeIntervalSince1970: 1_780_000_000)

    static func fix(
        east: Double,
        north: Double,
        secondsIn: Double,
        accuracy: Double = 8,
        verticalAccuracy: Double = 5,
        speed: Double = -1,
        altitude: Double = 30
    ) -> LocationFix {
        let metresPerDegreeLatitude = ENUProjection.earthRadius * .pi / 180
        let metresPerDegreeLongitude = metresPerDegreeLatitude * cos(baseLatitude * .pi / 180)
        return LocationFix(
            latitude: baseLatitude + north / metresPerDegreeLatitude,
            longitude: baseLongitude + east / metresPerDegreeLongitude,
            altitude: altitude,
            timestamp: epoch.addingTimeInterval(secondsIn),
            horizontalAccuracy: accuracy,
            verticalAccuracy: verticalAccuracy,
            speed: speed
        )
    }

    /// A straight walk: `count` fixes, `metresPerFix` apart, one per second.
    static func straightWalk(
        count: Int,
        metresPerFix: Double = 10,
        startingAt secondsIn: Double = 0,
        accuracy: Double = 8
    ) -> [LocationFix] {
        (0..<count).map {
            fix(
                east: Double($0) * metresPerFix,
                north: 0,
                secondsIn: secondsIn + Double($0),
                accuracy: accuracy
            )
        }
    }

    /// Feeds fixes into a session, using each fix's own timestamp as "now".
    static func feed(_ fixes: [LocationFix], into session: RecordingSession) async {
        for fix in fixes {
            await session.ingest(fix, now: fix.timestamp)
        }
    }
}

extension Array where Element == LocationFilterChain.Decision {
    /// Total fixes accepted, not the number of accepting decisions — one
    /// decision can carry two fixes when a held outlier is confirmed.
    var acceptedCount: Int { reduce(0) { $0 + $1.fixes.count } }
    var rejections: [LocationFilterChain.Rejection] {
        compactMap { if case .rejected(let reason) = $0 { reason } else { nil } }
    }
}
