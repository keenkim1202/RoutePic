import CoreLocation
import Foundation
import ShapeKit
import Testing
@testable import RouteKit

#if canImport(HealthKit)
import HealthKit
#endif

/// The querying needs a device with Health data on it. Checked here is the
/// mapping either side: whether a workout becomes the right row, or any row.
@Suite("Health workouts")
struct HealthWorkoutTests {

    #if canImport(HealthKit)
    /// Health knows what the activity was. Guessing from speed reads a slow
    /// cycle as a run, which is why the source's own answer wins.
    @Test("A workout's own type beats the speed heuristic")
    func activityTypeMapsToMode() {
        #expect(RecordingMode(workoutActivityType: .walking) == .walk)
        #expect(RecordingMode(workoutActivityType: .hiking) == .walk)
        #expect(RecordingMode(workoutActivityType: .running) == .run)
        #expect(RecordingMode(workoutActivityType: .cycling) == .drive)
    }

    /// A swim or a treadmill run is a real workout with no route worth drawing.
    /// Importing them would fill the collection with rows that render nothing.
    @Test("Workouts with no shape to draw are refused")
    func shapelessWorkoutsAreRefused() {
        #expect(RecordingMode(workoutActivityType: .swimming) == nil)
        #expect(RecordingMode(workoutActivityType: .yoga) == nil)
        #expect(RecordingMode(workoutActivityType: .traditionalStrengthTraining) == nil)
    }
    #endif

    @Test("A fix keeps its accuracy, and loses it when Health had none")
    func locationBecomesARoutePoint() {
        let measured = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
            altitude: 42,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            timestamp: Date(timeIntervalSince1970: 1_780_000_000)
        ).routePoint

        #expect(measured.altitude == 42)
        #expect(measured.horizontalAccuracy == 8)

        // CoreLocation writes a negative accuracy when it could not measure
        // one. Carrying that through as a number would make the filter chain
        // trust a reading nobody took.
        let unmeasured = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
            altitude: 42,
            horizontalAccuracy: -1,
            verticalAccuracy: -1,
            timestamp: Date(timeIntervalSince1970: 1_780_000_000)
        ).routePoint

        #expect(unmeasured.altitude == nil)
        #expect(unmeasured.horizontalAccuracy == nil)
        #expect(unmeasured.verticalAccuracy == nil)
    }

    /// A workout Health kept but never recorded a route for — a treadmill run,
    /// or one where location was off — has no shape and must not become a row.
    @Test("A workout with no route is not a route")
    func routelessWorkoutMakesNoPoints() async throws {
        // The reader hands back metadata; the caller asks for the route and
        // skips the workout when there is none.
        let workout = HealthWorkout(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_003_600),
            mode: .run
        )
        // On a device Health is there and simply holds no such workout, which
        // is an empty route, not a failure. Asserting the error unconditionally
        // fails on the one environment this code is written for.
        if HealthWorkoutReader.isAvailable {
            #expect(try await HealthWorkoutReader().points(for: workout).isEmpty)
        } else {
            await #expect(throws: HealthWorkoutReader.Failure.unavailable) {
                _ = try await HealthWorkoutReader().points(for: workout)
            }
        }
    }

    @Test("Health being unavailable is reported, not treated as an empty history")
    func unavailableIsAnError() async {
        guard !HealthWorkoutReader.isAvailable else { return }
        await #expect(throws: HealthWorkoutReader.Failure.unavailable) {
            _ = try await HealthWorkoutReader().workouts()
        }
    }
}
