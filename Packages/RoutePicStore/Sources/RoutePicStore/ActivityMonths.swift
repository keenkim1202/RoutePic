import Foundation

/// A calendar month, independent of who is reading it.
///
/// `Activity.timeZoneID` exists so a run does not move to another day when the
/// phone changes zone (`Schema.swift`). An instant cannot carry that: the same
/// wall-clock month begins at a different instant in every zone, so keying by
/// one would open two sections both named August. A year and a month cannot.
public struct MonthKey: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    /// The month `date` fell in, read in the zone it was recorded in.
    ///
    /// Always Gregorian, whatever the reader keeps: a Buddhist calendar numbers
    /// the same August 2569, and `displayDate` and the fetch window read the key
    /// back as Gregorian — wrong label, and a query that finds nothing.
    public init(_ date: Date, timeZoneID: String, fallback: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? fallback
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 1)
    }

    /// Midday on the 15th, UTC. No zone offset reaches a neighbouring month
    /// from there, so this formats as the right month wherever it is read.
    public var displayDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(
            from: DateComponents(year: year, month: month, day: 15, hour: 12)
        ) ?? .distantPast
    }

    public static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

extension Activity {
    /// Which month this belongs to, in its own zone rather than the reader's.
    public func monthKey(fallback: TimeZone = .current) -> MonthKey {
        MonthKey(startedAt, timeZoneID: timeZoneID, fallback: fallback)
    }
}

/// One month's worth of activities.
///
/// `PLAN.md` §구멍 9 — the collection filters by mode and favourite, so a
/// Health import of a thousand routes has no way back to last spring.
public struct ActivityMonth: Identifiable {
    public let id: MonthKey
    public let activities: [Activity]

    public init(id: MonthKey, activities: [Activity]) {
        self.id = id
        self.activities = activities
    }
}

/// A month the collection has something in, and how much.
///
/// Built from a query that reads only the two columns a month needs, so the
/// list covers the whole collection rather than whichever page is loaded.
public struct MonthSummary: Identifiable, Hashable, Sendable {
    public let id: MonthKey
    public let count: Int

    public init(id: MonthKey, count: Int) {
        self.id = id
        self.count = count
    }
}

extension Array where Element == Activity {

    /// Splits the collection into month sections, newest month first.
    ///
    /// Sorted by key rather than by first appearance: near a boundary an
    /// instant order can meet August before an older September — 06:30Z in Los
    /// Angeles is still August, 06:00Z in Tokyo is already September. Within a
    /// month the caller's order is kept.
    public func groupedByMonth(fallback: TimeZone = .current) -> [ActivityMonth] {
        var buckets: [MonthKey: [Activity]] = [:]
        for activity in self {
            buckets[activity.monthKey(fallback: fallback), default: []].append(activity)
        }
        return buckets.keys.sorted(by: >).map {
            ActivityMonth(id: $0, activities: buckets[$0] ?? [])
        }
    }
}
