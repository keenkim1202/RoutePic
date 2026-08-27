import Foundation
import RouteKit
import ShapeKit
import SwiftData
import Testing
@testable import RoutePicStore

@Suite("Month sections")
struct ActivityMonthsTests {

    private let fallback = TimeZone(identifier: "UTC")!

    private func activity(_ iso: String, zone: String = "UTC") -> Activity {
        let date = try! Date(iso, strategy: .iso8601)
        return Activity(
            mode: .walk,
            startedAt: date,
            endedAt: date.addingTimeInterval(600),
            timeZoneID: zone,
            statistics: ActivityStatistics(
                distanceMeters: 1000, elapsedDuration: 600, movingDuration: 600,
                pausedDuration: 0, gapDuration: 0, elevationGainMeters: 0
            ),
            route: StoreFixtures.route(points: 10)
        )
    }

    @Test("Each month becomes one section, newest first order kept")
    func splitsOnMonthBoundary() {
        let months = [
            activity("2026-08-20T09:00:00Z"),
            activity("2026-08-01T09:00:00Z"),
            activity("2026-07-30T09:00:00Z"),
        ].groupedByMonth(fallback: fallback)

        #expect(months.count == 2)
        #expect(months[0].activities.count == 2)
        #expect(months[1].activities.count == 1)
        #expect(months[0].id > months[1].id)
    }

    /// `Activity.timeZoneID` exists so a run does not move to another day when
    /// the phone changes zone. A month read in the reader's zone would undo
    /// exactly that.
    @Test("A month is the one the activity was recorded in, not the reader's")
    func monthFollowsTheRecordedZone() {
        // 23:30 on 31 August in Seoul is 14:30 on 31 August UTC — same month
        // either way. 00:30 on 1 September in Seoul is 31 August in UTC, and
        // that is the one a device-zone reading gets wrong.
        let seoul = activity("2026-08-31T15:30:00Z", zone: "Asia/Seoul")

        #expect(seoul.monthKey(fallback: fallback) == MonthKey(year: 2026, month: 9))
        #expect(
            MonthKey(seoul.startedAt, timeZoneID: "UTC", fallback: fallback)
                == MonthKey(year: 2026, month: 8)
        )
    }

    /// Two activities from the same wall-clock month in different zones must
    /// land in one section, or the collection shows August twice.
    @Test("The same month in two zones is one section")
    func sameMonthDifferentZonesMerge() {
        let months = [
            activity("2026-08-20T09:00:00Z", zone: "Asia/Seoul"),
            activity("2026-08-05T09:00:00Z", zone: "America/Los_Angeles"),
        ].groupedByMonth(fallback: fallback)

        #expect(months.count == 1)
        #expect(months[0].id == MonthKey(year: 2026, month: 8))
    }

    /// A Buddhist or Japanese calendar numbers the same August 2569 or 8, and
    /// everything downstream reads the key back as Gregorian.
    @Test("A non-Gregorian reader still gets a Gregorian key")
    func keyIsGregorianWhateverTheReaderKeeps() {
        let august = try! Date("2026-08-20T09:00:00Z", strategy: .iso8601)
        for identifier in [Calendar.Identifier.buddhist, .japanese, .islamicUmmAlQura] {
            var reader = Calendar(identifier: identifier)
            reader.timeZone = fallback
            // The reader's calendar is what `.current` would hand back; the key
            // must not follow it.
            #expect(reader.dateComponents([.year], from: august).year != 2026)
            #expect(
                MonthKey(august, timeZoneID: "UTC", fallback: fallback)
                    == MonthKey(year: 2026, month: 8)
            )
        }
    }

    /// Newest-instant order is not newest-month order near a boundary: 06:30Z
    /// in Los Angeles is still August, 06:00Z in Tokyo is already September.
    @Test("Sections are newest month first even when instants disagree")
    func sectionsSortByMonthNotByInstant() {
        let months = [
            activity("2026-09-01T06:30:00Z", zone: "America/Los_Angeles"),
            activity("2026-09-01T06:00:00Z", zone: "Asia/Tokyo"),
        ].groupedByMonth(fallback: fallback)

        #expect(months.map(\.id) == [MonthKey(year: 2026, month: 9), MonthKey(year: 2026, month: 8)])
    }

    @Test("The label is the right month in any reader's zone")
    func displayDateSurvivesEveryOffset() {
        var calendar = Calendar(identifier: .gregorian)
        for offset in [-12 * 3600, 0, 14 * 3600] {
            calendar.timeZone = TimeZone(secondsFromGMT: offset)!
            let parts = calendar.dateComponents(
                [.year, .month], from: MonthKey(year: 2026, month: 8).displayDate
            )
            #expect(parts.year == 2026)
            #expect(parts.month == 8)
        }
    }

    @Test("The last day of a month does not leak into the next section")
    func boundaryIsTheMonthNotThirtyDays() {
        let months = [
            activity("2026-09-01T00:00:00Z"),
            activity("2026-08-31T23:59:59Z"),
        ].groupedByMonth(fallback: fallback)

        #expect(months.count == 2)
    }

    /// Two sections carrying the same date would collide as `ForEach` identity
    /// and as the scroll target.
    @Test("A month that comes back later merges into its first section")
    func repeatedMonthMergesInsteadOfDuplicating() {
        let months = [
            activity("2026-08-20T09:00:00Z"),
            activity("2026-07-30T09:00:00Z"),
            activity("2026-08-02T09:00:00Z"),
        ].groupedByMonth(fallback: fallback)

        #expect(months.count == 2)
        #expect(Set(months.map(\.id)).count == months.count)
        #expect(months[0].activities.count == 2)
    }

    @Test("An empty collection has no sections")
    func emptyStaysEmpty() {
        #expect([Activity]().groupedByMonth(fallback: fallback).isEmpty)
    }
}


@MainActor
@Suite("Months across the whole collection")
struct ActivityMonthQueryTests {

    private let fallback = TimeZone(identifier: "UTC")!

    private func repository() throws -> ActivityRepository {
        ActivityRepository(
            context: ModelContext(try ActivityRepository.inMemoryContainer()),
            artworkStore: InMemoryArtworkStore()
        )
    }

    @discardableResult
    private func save(
        _ repository: ActivityRepository, _ iso: String,
        mode: RecordingMode = .walk, zone: String = "UTC"
    ) throws -> Activity {
        let date = try Date(iso, strategy: .iso8601)
        let activity = try repository.save(
            route: StoreFixtures.route(points: 10), mode: mode,
            startedAt: date, endedAt: date.addingTimeInterval(600)
        )
        activity.timeZoneID = zone
        try repository.context.save()
        return activity
    }

    /// The page holds 200 rows and a Health import is thousands, so a month
    /// list built from the loaded page cannot reach the months it is for.
    @Test("The month list is not capped by the page the screen loads")
    func monthsReachPastThePageLimit() throws {
        let repository = try repository()
        for day in 1...5 {
            for month in 1...4 {
                try save(repository, String(format: "2026-%02d-%02dT09:00:00Z", month, day))
            }
        }

        let months = try repository.activityMonths(fallbackTimeZone: fallback)
        let loaded = try repository.activities(limit: 5).groupedByMonth(fallback: fallback)

        #expect(months.count == 4)
        #expect(months.allSatisfy { $0.count == 5 })
        #expect(loaded.count < months.count)
    }

    @Test("Picking a month narrows the query to it")
    func filtersToOneMonth() throws {
        let repository = try repository()
        try save(repository, "2026-08-20T09:00:00Z")
        try save(repository, "2026-08-31T23:59:59Z")
        try save(repository, "2026-09-01T00:00:00Z")

        let inAugust = try repository.activities(
            inMonth: MonthKey(year: 2026, month: 8), fallbackTimeZone: fallback, limit: 50
        )

        #expect(inAugust.count == 2)
        #expect(inAugust.allSatisfy { $0.monthKey(fallback: fallback) == MonthKey(year: 2026, month: 8) })
    }

    @Test("The mode filter narrows the month list too")
    func monthsRespectTheModeFilter() throws {
        let repository = try repository()
        try save(repository, "2026-08-20T09:00:00Z", mode: .walk)
        try save(repository, "2026-07-20T09:00:00Z", mode: .drive)

        let walks = try repository.activityMonths(mode: .walk, fallbackTimeZone: fallback)

        #expect(walks.count == 1)
        #expect(walks[0].count == 1)
    }

    /// The predicate can only narrow to a UTC window; the boundary itself is
    /// settled per row, and a row just outside the reader's month must survive.
    @Test("A month picked in one zone still finds a run recorded in another")
    func filterCrossesZoneBoundaries() throws {
        let repository = try repository()
        // September in Seoul, August in UTC.
        try save(repository, "2026-08-31T15:30:00Z", zone: "Asia/Seoul")
        try save(repository, "2026-09-10T09:00:00Z", zone: "Asia/Seoul")

        let september = try repository.activities(
            inMonth: MonthKey(year: 2026, month: 9), fallbackTimeZone: fallback, limit: 50
        )
        let august = try repository.activities(
            inMonth: MonthKey(year: 2026, month: 8), fallbackTimeZone: fallback, limit: 50
        )

        #expect(september.count == 2)
        #expect(august.isEmpty)
    }

    @Test("An empty collection offers no months")
    func noActivitiesNoMonths() throws {
        #expect(try repository().activityMonths(fallbackTimeZone: fallback).isEmpty)
    }
}
