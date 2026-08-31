import CoreLocation
import Testing
@testable import RouteKit

@Suite("Classic location source")
struct ClassicLocationSourceTests {

    /// Low Power Mode is a signal to the app, not a change Core Location makes.
    /// Without this the most expensive setting keeps running on the emptiest
    /// battery, and the banner in `DESIGN.md` §14.1 announces nothing.
    @Test("Low Power Mode costs one step of accuracy, per mode", arguments: [
        (RecordingMode.walk, kCLLocationAccuracyBest, kCLLocationAccuracyNearestTenMeters),
        (RecordingMode.run, kCLLocationAccuracyBestForNavigation, kCLLocationAccuracyBest),
        (RecordingMode.drive, kCLLocationAccuracyBestForNavigation, kCLLocationAccuracyBest),
    ])
    func lowPowerLowersAccuracy(
        mode: RecordingMode, normal: CLLocationAccuracy, saving: CLLocationAccuracy
    ) {
        #expect(ClassicLocationSource.desiredAccuracy(for: mode) == normal)
        #expect(ClassicLocationSource.desiredAccuracy(for: mode, lowPower: true) == saving)
        // `Best` and `BestForNavigation` are negative sentinels, not metres, and
        // both orderings run the same way: coarser is the larger value.
        #expect(saving > normal)
    }
}
