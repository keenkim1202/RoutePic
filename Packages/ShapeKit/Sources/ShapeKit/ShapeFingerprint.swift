import Foundation

/// Numeric description of a route's shape, sent to the VLM alongside the
/// rendered control image.
///
/// `DESIGN.md` §6.2. Every metric here is defined for an **open** polyline.
/// v0.1 of the design included "convex ratio = polygon area / convex hull area",
/// which cross-review correctly flagged as undefined for an open path: closing
/// it with an arbitrary chord lets that chord dominate the measurement. Polygon
/// metrics are now gated behind `isClosed`.
public struct ShapeFingerprint: Sendable, Equatable, Codable {

    /// Below this, start and end are close enough to treat the route as a loop.
    public static let closureThreshold = 0.05

    /// Straight-line distance between the endpoints ÷ total length. 0 = a loop.
    public let closureRatio: Double

    /// Bounding box width ÷ height. Elongated shapes suggest snakes and trains;
    /// square ones suggest faces and flowers.
    ///
    /// Clamped to `[1/aspectCeiling, aspectCeiling]`: a perfectly straight route
    /// has zero height, and an infinity here would poison the JSON sent to the
    /// VLM.
    public let aspectRatio: Double
    public static let aspectCeiling = 1000.0

    /// Total length ÷ endpoint distance. 1.0 = a straight line.
    /// Capped at `tortuosityCeiling` because a loop divides by ~0.
    public let tortuosity: Double
    public static let tortuosityCeiling = 1000.0

    /// Mean absolute turning angle, radians. High = jagged.
    public let meanAbsoluteTurn: Double

    /// Variance of turning angles. Distinguishes a uniform spiral from a shape
    /// with a few sharp corners and long smooth runs.
    public let turnVariance: Double

    /// Skewness of turning angles. Consistently signed turns mean the route
    /// spirals one way.
    public let turnSkewness: Double

    /// Fraction of the 32×32 grid the route touches.
    public let occupancyFillRatio: Double

    /// How many distinct protrusions stick out from the shape's centre — the
    /// legs, horns and tails a subject would need.
    ///
    /// `DESIGN.md` §6.2 originally specified "skeleton branch count", counted as
    /// junctions in a thinned occupancy grid. That metric cannot work: an X
    /// crossing rasterises to a 2×2 block whose cells each have only two
    /// neighbourhood arms, so no junction pixel exists at any resolution.
    /// Measured directly on the polyline, protrusions answer the same question
    /// ("how many limbs?") and are defined for open paths.
    public let protrusionCount: Int

    /// Genuine self-crossings of the simplified polyline.
    public let selfIntersectionCount: Int

    /// Enclosed area ÷ convex hull area. `nil` unless the route is closed.
    public let convexRatio: Double?

    /// A public memberwise initialiser: the synthesised one is internal, which
    /// left this type constructible only from inside `ShapeKit` — unusable for
    /// the packages that have to build a request or a test fixture.
    public init(
        closureRatio: Double,
        aspectRatio: Double,
        tortuosity: Double,
        meanAbsoluteTurn: Double,
        turnVariance: Double,
        turnSkewness: Double,
        occupancyFillRatio: Double,
        protrusionCount: Int,
        selfIntersectionCount: Int,
        convexRatio: Double?
    ) {
        self.closureRatio = closureRatio
        self.aspectRatio = aspectRatio
        self.tortuosity = tortuosity
        self.meanAbsoluteTurn = meanAbsoluteTurn
        self.turnVariance = turnVariance
        self.turnSkewness = turnSkewness
        self.occupancyFillRatio = occupancyFillRatio
        self.protrusionCount = protrusionCount
        self.selfIntersectionCount = selfIntersectionCount
        self.convexRatio = convexRatio
    }

    public var isClosed: Bool { closureRatio <= Self.closureThreshold }

    /// Almost a straight line — nothing to see, so `DESIGN.md` §4.4 blocks
    /// generation rather than spending money on it.
    public var isDegenerate: Bool { tortuosity < 1.15 }
}

extension ShapeFingerprint {

    /// Computes the fingerprint from canvas-space runs.
    ///
    /// Pass the **smoothed, simplified** runs: that is what the model sees, and
    /// the fingerprint should describe the same thing.
    public static func compute(
        runs: [[Point2D]],
        canvasSize: Double = Normalize.defaultCanvasSize,
        gridSize: Int = 32
    ) -> ShapeFingerprint {
        let all = runs.flatMap { $0 }

        guard let first = all.first, let last = all.last, all.count >= 2 else {
            return ShapeFingerprint(
                closureRatio: 0, aspectRatio: 1, tortuosity: 1,
                meanAbsoluteTurn: 0, turnVariance: 0, turnSkewness: 0,
                occupancyFillRatio: 0, protrusionCount: 0,
                selfIntersectionCount: 0, convexRatio: nil
            )
        }

        let totalLength = runs.reduce(0.0) { $0 + Geometry.polylineLength($1) }
        let endpointDistance = first.distance(to: last)

        let closureRatio = totalLength > 0 ? endpointDistance / totalLength : 0
        let tortuosity = endpointDistance > 1e-9
            ? min(totalLength / endpointDistance, tortuosityCeiling)
            : tortuosityCeiling

        let box = BoundingBox(all)
        let aspectRatio: Double = {
            guard let box else { return 1 }
            guard box.height > 1e-9 else {
                // Zero height: a perfectly horizontal route. Report the ceiling
                // rather than 1, which would read as "square".
                return box.width > 1e-9 ? aspectCeiling : 1
            }
            guard box.width > 1e-9 else { return 1 / aspectCeiling }
            return min(max(box.width / box.height, 1 / aspectCeiling), aspectCeiling)
        }()

        let angles = runs.flatMap { Geometry.turningAngles($0) }
        let (meanAbsoluteTurn, turnVariance, turnSkewness) = angleStatistics(angles)

        let grid = OccupancyGrid.rasterize(runs, canvasSize: canvasSize, gridSize: gridSize)
        let selfIntersections = countSelfIntersections(runs)

        let closed = closureRatio <= closureThreshold
        let convexRatio: Double? = {
            // Shoelace sums signed area, so a self-crossing loop's lobes cancel
            // and the ratio collapses towards zero — a number that looks like a
            // measurement but means nothing. Only simple closed curves qualify.
            guard closed, selfIntersections == 0, all.count >= 3 else { return nil }
            let hullArea = Geometry.shoelaceArea(Geometry.convexHull(all))
            guard hullArea > 1e-9 else { return nil }
            return Geometry.shoelaceArea(all) / hullArea
        }()

        return ShapeFingerprint(
            closureRatio: closureRatio,
            aspectRatio: aspectRatio,
            tortuosity: tortuosity,
            meanAbsoluteTurn: meanAbsoluteTurn,
            turnVariance: turnVariance,
            turnSkewness: turnSkewness,
            occupancyFillRatio: grid.fillRatio,
            protrusionCount: countProtrusions(all, closed: closed),
            selfIntersectionCount: selfIntersections,
            convexRatio: convexRatio
        )
    }

    private static func angleStatistics(_ angles: [Double]) -> (Double, Double, Double) {
        guard !angles.isEmpty else { return (0, 0, 0) }
        let n = Double(angles.count)
        let meanAbsolute = angles.reduce(0) { $0 + abs($1) } / n
        let mean = angles.reduce(0, +) / n
        let variance = angles.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let standardDeviation = variance.squareRoot()
        let skewness: Double = standardDeviation > 1e-9
            ? angles.reduce(0) { $0 + pow(($1 - mean) / standardDeviation, 3) } / n
            : 0
        return (meanAbsolute, variance, skewness)
    }

    /// A peak must stand this far above the shape's radial range to count as a
    /// limb rather than a wobble.
    static let protrusionProminence = 0.30

    /// A shape whose radius varies less than this relative to its mean is round
    /// enough to have no limbs at all.
    static let protrusionMinimumRelativeRange = 0.15

    /// Counts how far the path reaches out from its own centre, and how often.
    ///
    /// Walks radial distance from the centroid and counts local maxima that both
    /// clear `protrusionProminence` of the radial range and are the largest value
    /// within a neighbourhood window. A circle has constant radius and therefore
    /// no protrusions; a lemniscate has two lobes; a starfish has five arms.
    private static func countProtrusions(_ points: [Point2D], closed: Bool) -> Int {
        // A closed route repeats its first vertex; leaving it in creates a
        // duplicate peak at the seam.
        var samples = points
        if closed, samples.count > 2, samples[0].distance(to: samples[samples.count - 1]) < 1 {
            samples.removeLast()
        }
        guard samples.count >= 8 else { return 0 }

        let centroid = Point2D(
            x: samples.reduce(0) { $0 + $1.x } / Double(samples.count),
            y: samples.reduce(0) { $0 + $1.y } / Double(samples.count)
        )
        let radii = samples.map { $0.distance(to: centroid) }
        let count = radii.count

        guard let minimum = radii.min(), let maximum = radii.max() else { return 0 }
        let range = maximum - minimum
        let mean = radii.reduce(0, +) / Double(count)
        guard mean > 1e-9, range / mean >= protrusionMinimumRelativeRange else { return 0 }

        let threshold = minimum + range * protrusionProminence
        // Wide enough that GPS wobble cannot form a peak, narrow enough that two
        // genuine lobes stay distinct.
        let window = max(3, count / 12)

        // A closed shape wraps: a peak sitting on the seam between the last and
        // first vertex is still one peak. Scanning linearly loses it — which is
        // how a five-armed star reported four arms.
        func index(_ i: Int) -> Int { closed ? ((i % count) + count) % count : i }
        func radius(_ i: Int) -> Double? {
            guard closed || (i >= 0 && i < count) else { return nil }
            return radii[index(i)]
        }

        var candidates: [Int] = []
        for i in 0..<count where radii[i] >= threshold {
            guard let previous = radius(i - 1), previous < radii[i] else { continue }
            let isLocalMaximum = (-window...window).allSatisfy { offset in
                guard let value = radius(i + offset) else { return true }
                return value <= radii[i]
            }
            if isLocalMaximum { candidates.append(i) }
        }

        // Merge candidates sitting on the same peak.
        var peaks = 0
        var lastAccepted: Int?
        for candidate in candidates {
            if let last = lastAccepted, candidate - last <= window { continue }
            peaks += 1
            lastAccepted = candidate
        }
        // On a closed shape the first and last accepted peaks may be the same one
        // seen from both sides of the seam.
        if closed, peaks > 1, let first = candidates.first, let last = lastAccepted,
           (count - last) + first <= window {
            peaks -= 1
        }
        return peaks
    }

    /// Counts crossings within each run. Segments sharing a vertex are excluded —
    /// consecutive segments always touch, and counting those would make every
    /// route maximally self-intersecting.
    ///
    /// O(n²), but only ever runs on the simplified polyline (≤200 vertices).
    private static func countSelfIntersections(_ runs: [[Point2D]]) -> Int {
        var count = 0
        for run in runs where run.count >= 4 {
            // Stop at count-4: beyond that there is no later segment left to
            // compare against, and `(i + 2)..<(run.count - 1)` would invert.
            for i in 0...(run.count - 4) {
                for j in (i + 2)..<(run.count - 1) {
                    if Geometry.segmentsIntersect(run[i], run[i + 1], run[j], run[j + 1]) {
                        count += 1
                    }
                }
            }
        }
        return count
    }
}
