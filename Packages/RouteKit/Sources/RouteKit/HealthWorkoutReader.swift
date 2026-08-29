import CoreLocation
import Foundation
import ShapeKit

#if canImport(HealthKit)
import HealthKit
#endif

/// One recorded workout, without its coordinates.
///
/// Separate from the route on purpose: a history is hundreds of these at a few
/// bytes each, while the routes are the whole import. Asking for one route at a
/// time is what bounds the memory — a buffered stream fills up whenever Health
/// outruns the store.
public struct HealthWorkout: Equatable, Sendable {
    public let id: UUID
    /// Health's own bounds. A route can start recording after the workout did
    /// and stop before it ended, so the first and last fix are not the same
    /// thing as when the person set out.
    public let startedAt: Date
    public let endedAt: Date
    public let mode: RecordingMode
    /// The zone the workout happened in, when Health recorded one. A run taken
    /// abroad is grouped and dated by this, not by where the phone is now.
    public let timeZoneID: String?

    public init(
        id: UUID, startedAt: Date, endedAt: Date, mode: RecordingMode, timeZoneID: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.mode = mode
        self.timeZoneID = timeZoneID
    }
}

/// Reads workout routes out of the Health app.
///
/// `PLAN.md` P0.1 — the app is empty the day it is installed and somebody has
/// to walk half an hour before anything appears, while Health already holds
/// years of it. Health stores routes as `CLLocation`, which is what the
/// recorder already receives, so nothing below `importRoute` learns anything.
public struct HealthWorkoutReader: Sendable {

    public enum Failure: DescribedError, Equatable {
        case unavailable
        case denied

        public var description: String {
            switch self {
            case .unavailable:
                "Health data is not available on this device."
            case .denied:
                """
                RoutePic was not given permission to read workouts. Health \
                settings can grant it.
                """
            }
        }
    }

    public init() {}

    public static var isAvailable: Bool {
        #if canImport(HealthKit)
        HKHealthStore.isHealthDataAvailable()
        #else
        false
        #endif
    }

    #if canImport(HealthKit)
    private let store = HKHealthStore()

    /// Health never says "denied" — a refused read looks exactly like a person
    /// with no workouts, by design, so that an app cannot probe what it was
    /// not given. The empty result is reported as it is rather than guessed at.
    public func requestAuthorization() async throws {
        guard Self.isAvailable else { throw Failure.unavailable }
        try await store.requestAuthorization(
            toShare: [],
            read: [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        )
    }

    /// Every workout this app has a shape for, newest first.
    ///
    /// Metadata only — no coordinates are read here, so asking for all of them
    /// costs a list. A cap applied before this filter would hide older routes
    /// behind a history of swims, permanently: re-running asks for the same
    /// newest ones again.
    public func workouts() async throws -> [HealthWorkout] {
        guard Self.isAvailable else { throw Failure.unavailable }
        return try await workoutSamples().compactMap { workout in
            RecordingMode(workoutActivityType: workout.workoutActivityType).map {
                HealthWorkout(
                    id: workout.uuid,
                    startedAt: workout.startDate,
                    endedAt: workout.endDate,
                    mode: $0,
                    timeZoneID: workout.metadata?[HKMetadataKeyTimeZone] as? String
                )
            }
        }
    }

    /// The coordinates for one workout, or none if Health kept no route for it.
    ///
    /// One workout at a time, so a failure here is that workout's problem. A
    /// route deleted mid-import used to end the whole history read and leave
    /// everything older unexamined.
    public func points(for workout: HealthWorkout) async throws -> [RoutePoint] {
        guard Self.isAvailable else { throw Failure.unavailable }
        guard let sample = try await workoutSample(id: workout.id) else { return [] }
        return try await locations(for: sample).map(\.routePoint)
    }

    /// Every workout, unfiltered. This is metadata — no routes are read here.
    private func workoutSamples() async throws -> [HKWorkout] {
        try await samples(
            of: HKObjectType.workoutType(),
            predicate: nil,
            sortedNewestFirst: true
        ) as? [HKWorkout] ?? []
    }

    private func workoutSample(id: UUID) async throws -> HKWorkout? {
        try await samples(
            of: HKObjectType.workoutType(),
            predicate: HKQuery.predicateForObject(with: id),
            sortedNewestFirst: false
        ).first as? HKWorkout
    }

    private func samples(
        of type: HKSampleType, predicate: NSPredicate?, sortedNewestFirst: Bool
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: sortedNewestFirst
                    ? [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
                    : nil
            ) { _, samples, error in
                if let error { return continuation.resume(throwing: error) }
                continuation.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }

    private func locations(for workout: HKWorkout) async throws -> [CLLocation] {
        let routes: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error { return continuation.resume(throwing: error) }
                continuation.resume(returning: samples as? [HKWorkoutRoute] ?? [])
            }
            store.execute(query)
        }

        var all: [CLLocation] = []
        for route in routes {
            all.append(contentsOf: try await locations(in: route))
        }
        // Health hands each route back in its own query, and a workout can hold
        // more than one. Ordering them is the caller's job, not Health's.
        return all.sorted { $0.timestamp < $1.timestamp }
    }

    private func locations(in route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            // The route arrives in batches; `done` marks the last one, and the
            // handler is called again after an error only if it is ignored.
            let collected = LocationBatch()
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error { return continuation.resume(throwing: error) }
                collected.append(locations ?? [])
                if done { continuation.resume(returning: collected.all) }
            }
            store.execute(query)
        }
    }

    /// The batch handler is called from Health's own queue, more than once.
    private final class LocationBatch: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CLLocation] = []
        var all: [CLLocation] { lock.withLock { storage } }
        func append(_ locations: [CLLocation]) {
            lock.withLock { storage.append(contentsOf: locations) }
        }
    }
    #else
    public func requestAuthorization() async throws { throw Failure.unavailable }
    public func workouts() async throws -> [HealthWorkout] { throw Failure.unavailable }
    public func points(for workout: HealthWorkout) async throws -> [RoutePoint] {
        throw Failure.unavailable
    }
    #endif
}

extension CLLocation {
    /// What the recorder would have stored for this fix.
    public var routePoint: RoutePoint {
        RoutePoint(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            altitude: verticalAccuracy >= 0 ? altitude : nil,
            timestamp: timestamp,
            horizontalAccuracy: horizontalAccuracy >= 0 ? horizontalAccuracy : nil,
            verticalAccuracy: verticalAccuracy >= 0 ? verticalAccuracy : nil
        )
    }
}
