import Foundation

/// Turns a recorded route into the artefacts the rest of the app needs:
/// a canvas-space path to draw, a control image for the diffusion model, and a
/// numeric fingerprint for the VLM.
///
/// `DESIGN.md` §6. One deviation from the design's step list, which numbered
/// projection *after* resampling and simplification: both of those measure
/// distances and perpendicular offsets, which need a metric plane. Projection
/// has to come first. (Design doc corrected accordingly.)
public struct ShapePipeline: Sendable {

    public struct Configuration: Sendable {
        public var canvasSize: Double
        public var paddingFraction: Double
        /// Metres between resampled vertices. `DESIGN.md` §5.2, per mode.
        public var resampleSpacing: Double
        public var targetVertexRange: ClosedRange<Int>
        public var trimMeters: Double

        public init(
            canvasSize: Double = Normalize.defaultCanvasSize,
            paddingFraction: Double = Normalize.defaultPaddingFraction,
            resampleSpacing: Double = 8,
            targetVertexRange: ClosedRange<Int> = Simplify.defaultTargetRange,
            trimMeters: Double = RouteTrimmer.defaultTrimMeters
        ) {
            self.canvasSize = canvasSize
            self.paddingFraction = paddingFraction
            self.resampleSpacing = resampleSpacing
            self.targetVertexRange = targetVertexRange
            self.trimMeters = trimMeters
        }

        public static let walking = Configuration(resampleSpacing: 5)
        public static let running = Configuration(resampleSpacing: 8)
        public static let driving = Configuration(resampleSpacing: 25)
    }

    public enum Failure: DescribedError, Equatable {
        case notEnoughPoints
        case projection(ENUProjection.Failure)

        public var description: String {
            switch self {
            case .notEnoughPoints:
                return "Route has fewer than two usable points after filtering."
            case .projection(let failure):
                return failure.description
            }
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func prepare(_ route: Route) throws -> PreparedShape {
        let trim = RouteTrimmer.trim(route.points, meters: configuration.trimMeters)

        // Slice, never rebuild: `Route(points:)` collapses the segmentation, and
        // a lost gap boundary means the render joins two stretches with a
        // straight line the person never walked (`DESIGN.md` §5.4).
        let source = trim.points.count >= 2 ? route.slice(trim.retainedRange) : route
        guard source.points.count >= 2 else { throw Failure.notEnoughPoints }

        let projection: ENUProjection
        do {
            projection = try ENUProjection(centeredOn: source.points)
        } catch let failure as ENUProjection.Failure {
            throw Failure.projection(failure)
        }

        let runs: [[Point2D]] = source.movingRuns.compactMap { run in
            let projected = projection.project(run)
            let resampled = Resample.evenly(projected, spacing: configuration.resampleSpacing)
            let simplified = Simplify.adaptive(resampled, targetRange: configuration.targetVertexRange)
            return simplified.count >= 2 ? simplified : nil
        }

        guard !runs.isEmpty else { throw Failure.notEnoughPoints }

        return PreparedShape(
            configuration: configuration,
            projection: projection,
            projectedRuns: runs,
            trim: trim,
            lengthMeters: RouteTrimmer.length(of: source.points)
        )
    }
}

/// A route projected, resampled and simplified — but not yet oriented.
///
/// This is the shared root of all 16 orientations, computed once.
public struct PreparedShape: Sendable {
    public let configuration: ShapePipeline.Configuration
    public let projection: ENUProjection
    /// Metres, origin at the route centroid.
    public let projectedRuns: [[Point2D]]
    public let trim: RouteTrimmer.Result
    public let lengthMeters: Double

    public var vertexCount: Int { projectedRuns.reduce(0) { $0 + $1.count } }

    /// The canonical (unrotated, unmirrored) view. Its fingerprint is the one
    /// stored and sent to the VLM.
    public var canonical: OrientedShape { oriented(.identity) }

    public func oriented(_ orientation: Orientation) -> OrientedShape {
        let rotated = orientation.apply(to: projectedRuns)
        let canvas = Normalize.toCanvas(
            rotated,
            canvasSize: configuration.canvasSize,
            paddingFraction: configuration.paddingFraction
        )
        let curves = canvas.map { Smoothing.catmullRom($0) }
        let flattened = curves.map { Smoothing.flatten($0) }

        return OrientedShape(
            orientation: orientation,
            canvasSize: configuration.canvasSize,
            runs: canvas,
            curves: curves,
            fingerprint: ShapeFingerprint.compute(
                runs: flattened,
                canvasSize: configuration.canvasSize
            )
        )
    }

    /// All 16 orientations, in `Orientation.all` order.
    /// The index here is what `Artwork.renderIndex` stores (`DESIGN.md` §8.1).
    public func allOrientations() -> [OrientedShape] {
        Orientation.all.map(oriented)
    }
}

/// A shape placed on the canvas at one specific orientation.
public struct OrientedShape: Sendable {
    public let orientation: Orientation
    public let canvasSize: Double
    /// Canvas-space polylines, one per moving run.
    public let runs: [[Point2D]]
    /// Smoothed form of `runs` — what actually gets stroked.
    public let curves: [[BezierSegment]]
    public let fingerprint: ShapeFingerprint
}
