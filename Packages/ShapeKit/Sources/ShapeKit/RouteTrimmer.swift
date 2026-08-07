import Foundation

/// Removes the start and end of a route before it is displayed or shared.
///
/// `DESIGN.md` §8.4 and §11 — the single most likely way this app leaks
/// something serious is a shared image whose route line starts at the user's
/// front door. Trimming is on by default and applied to every derived form; the
/// stored route is never trimmed, so the setting stays retroactive.
public enum RouteTrimmer {

    /// `DESIGN.md` §11 — 200 m default, 0/200/500 in settings.
    public static let defaultTrimMeters = 200.0

    /// Trimming more than this fraction of a short route leaves nothing to look at.
    public static let maximumTrimFraction = 0.40

    /// Below this there is no meaningful shape left after trimming, so a map
    /// snapshot is refused outright rather than shared partially blurred.
    public static let minimumShareableLength = 300.0

    public struct Result: Sendable {
        public var points: [RoutePoint]

        /// Which slice of the input survived. Callers holding a `Route` must use
        /// this with `Route.slice(_:)` rather than rebuilding from `points`,
        /// which would flatten the segmentation.
        public var retainedRange: Range<Int>

        /// What was actually removed from each end, after the 40% cap.
        public var trimmedStartMeters: Double
        public var trimmedEndMeters: Double

        /// Start and end are the same place, so trimming both ends still exposes
        /// it. `DESIGN.md` §8.4 — the caller must suppress the map snapshot or
        /// apply a rotation offset instead of trusting the trim.
        public var isLoop: Bool

        /// Too short for a map snapshot to be safe.
        public var isTooShortToShare: Bool

        /// The trim was reduced to stay inside `maximumTrimFraction`.
        public var trimWasCapped: Bool
    }

    public static func trim(
        _ points: [RoutePoint],
        meters requested: Double = defaultTrimMeters
    ) -> Result {
        guard points.count >= 2 else {
            return Result(
                points: points,
                retainedRange: 0..<points.count,
                trimmedStartMeters: 0, trimmedEndMeters: 0,
                isLoop: false, isTooShortToShare: true, trimWasCapped: false
            )
        }

        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(points.count)
        for i in 1..<points.count {
            cumulative.append(
                cumulative[i - 1] + ENUProjection.haversineDistance(points[i - 1], points[i])
            )
        }
        let totalLength = cumulative[cumulative.count - 1]

        let endpointDistance = ENUProjection.haversineDistance(points[0], points[points.count - 1])
        let closureRatio = totalLength > 0 ? endpointDistance / totalLength : 0
        let isLoop = closureRatio <= ShapeFingerprint.closureThreshold

        guard requested > 0, totalLength > 0 else {
            return Result(
                points: points,
                retainedRange: 0..<points.count,
                trimmedStartMeters: 0, trimmedEndMeters: 0,
                isLoop: isLoop,
                isTooShortToShare: totalLength < minimumShareableLength,
                trimWasCapped: false
            )
        }

        // Cap both ends together: two 200 m trims on a 600 m walk would take 67%.
        let budget = totalLength * maximumTrimFraction
        let requestedTotal = requested * 2
        let capped = requestedTotal > budget
        let effective = capped ? budget / 2 : requested

        let startIndex = cumulative.firstIndex { $0 >= effective } ?? 0
        let endIndex = cumulative.lastIndex { $0 <= totalLength - effective } ?? (points.count - 1)

        let usable = startIndex < endIndex
        let retainedRange = usable ? startIndex..<(endIndex + 1) : 0..<points.count

        return Result(
            points: Array(points[retainedRange]),
            retainedRange: retainedRange,
            trimmedStartMeters: usable ? cumulative[startIndex] : 0,
            trimmedEndMeters: usable ? totalLength - cumulative[endIndex] : 0,
            isLoop: isLoop,
            isTooShortToShare: totalLength < minimumShareableLength,
            trimWasCapped: capped
        )
    }

    /// Total geodesic length of a route, in metres.
    public static func length(of points: [RoutePoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += ENUProjection.haversineDistance(points[i - 1], points[i])
        }
        return total
    }
}
