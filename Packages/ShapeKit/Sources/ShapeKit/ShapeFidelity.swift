import CoreGraphics
import Foundation

/// Measures how much of a generated image is actually the route.
///
/// `DESIGN.md` §4.3 lists Chamfer / Hausdorff distance as the mechanical proxy
/// for route attribution, and §7.8's preliminary run showed why one is needed:
/// every judgement there was mine, unblinded, against no written criterion.
/// A number does not make the judgement correct, but it makes it repeatable and
/// lets the spike compare conditions without a human in the loop for every cell.
///
/// Two directions, and **they measure different failures**:
///
/// - `routeToEdge` — for each point on the route, distance to the nearest edge
///   in the generated image. High means *the route was not drawn*.
/// - `edgeToRoute` — for each edge pixel in the image, distance to the nearest
///   point on the route. High means *the image is full of things that are not
///   the route* — the confetti, stripes and scattered dots §7.8 kept seeing.
///
/// The second is the one that caught the observed failure mode. An image can
/// trace the route perfectly and still score badly if it buries it in texture,
/// which is exactly what should count against route attribution.
///
/// Both are normalised by the canvas diagonal, so they are comparable across
/// resolutions and routes: 0 means coincident, 1 means as far apart as the
/// canvas allows.
public struct ShapeFidelity: Sendable {

    public struct Score: Sendable, Equatable {
        /// Mean normalised distance from route samples to the nearest edge.
        public let routeToEdge: Double
        /// Mean normalised distance from edge pixels to the nearest route sample.
        public let edgeToRoute: Double
        /// 95th percentile of `routeToEdge` — a robust stand-in for Hausdorff,
        /// which a single stray pixel would otherwise dominate.
        public let routeToEdgeP95: Double
        /// Symmetric Chamfer distance: the mean of the two directions.
        public let chamfer: Double
        /// Fraction of pixels classified as edges. Near 1 means the threshold
        /// failed and every other number here is meaningless.
        public let edgeDensity: Double

        public init(
            routeToEdge: Double, edgeToRoute: Double,
            routeToEdgeP95: Double, chamfer: Double, edgeDensity: Double
        ) {
            self.routeToEdge = routeToEdge
            self.edgeToRoute = edgeToRoute
            self.routeToEdgeP95 = routeToEdgeP95
            self.chamfer = chamfer
            self.edgeDensity = edgeDensity
        }

        /// Whether the numbers can be trusted at all.
        ///
        /// A near-uniform image produces no edges, and a maximally noisy one
        /// produces edges everywhere; in both cases the distances degenerate.
        /// Reporting a confident score there would be worse than reporting none.
        public var isMeaningful: Bool { edgeDensity > 0.001 && edgeDensity < 0.4 }
    }

    public struct Configuration: Sendable {
        /// Gradient magnitude above which a pixel counts as an edge, as a
        /// fraction of the maximum possible gradient.
        public var edgeThreshold: Double
        /// Spacing, in pixels, at which the route polyline is sampled.
        public var routeSampleSpacing: Double

        public init(edgeThreshold: Double = 0.12, routeSampleSpacing: Double = 2) {
            self.edgeThreshold = edgeThreshold
            self.routeSampleSpacing = max(0.5, routeSampleSpacing)
        }

        public static let standard = Configuration()
    }

    public enum Failure: Error, CustomStringConvertible {
        case unreadableImage
        case emptyShape

        public var description: String {
            switch self {
            case .unreadableImage: "Could not read the generated image's pixels."
            case .emptyShape: "The shape has no points to compare against."
            }
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    /// Scores `generated` against the route it was supposed to follow.
    ///
    /// The shape is mapped from its own canvas onto the image's pixel grid, so
    /// the two do not have to be the same size — generated images are commonly
    /// 512² while the pipeline's canvas is 1024².
    public func score(generated: CGImage, against shape: OrientedShape) throws -> Score {
        let width = generated.width
        let height = generated.height
        guard let edges = try edgeMask(generated) else { throw Failure.unreadableImage }

        let samples = routeSamples(shape, width: width, height: height)
        guard !samples.isEmpty else { throw Failure.emptyShape }

        let edgeDistance = distanceTransform(of: edges, width: width, height: height)
        var routeMask = [Bool](repeating: false, count: width * height)
        for point in samples {
            let x = Int(point.x.rounded()), y = Int(point.y.rounded())
            guard x >= 0, x < width, y >= 0, y < height else { continue }
            routeMask[y * width + x] = true
        }
        let routeDistance = distanceTransform(of: routeMask, width: width, height: height)

        let diagonal = (Double(width * width) + Double(height * height)).squareRoot()

        // Route → nearest edge.
        var routeDistances: [Double] = []
        routeDistances.reserveCapacity(samples.count)
        for point in samples {
            let x = min(max(Int(point.x.rounded()), 0), width - 1)
            let y = min(max(Int(point.y.rounded()), 0), height - 1)
            routeDistances.append(edgeDistance[y * width + x] / diagonal)
        }

        // Edge → nearest route sample.
        var edgeSum = 0.0
        var edgeCount = 0
        for index in edges.indices where edges[index] {
            edgeSum += routeDistance[index] / diagonal
            edgeCount += 1
        }

        let routeToEdge = routeDistances.reduce(0, +) / Double(routeDistances.count)
        let edgeToRoute = edgeCount > 0 ? edgeSum / Double(edgeCount) : 1.0
        let sorted = routeDistances.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]

        return Score(
            routeToEdge: routeToEdge,
            edgeToRoute: edgeToRoute,
            routeToEdgeP95: p95,
            chamfer: (routeToEdge + edgeToRoute) / 2,
            edgeDensity: Double(edgeCount) / Double(width * height)
        )
    }

    // MARK: - Edges

    /// Sobel gradient magnitude, thresholded.
    private func edgeMask(_ image: CGImage) throws -> [Bool]? {
        let width = image.width, height = image.height
        guard width > 2, height > 2 else { return nil }

        // Redraw into a known layout rather than trusting the source's format —
        // generated PNGs arrive in whatever the encoder chose.
        var grey = [Double](repeating: 0, count: width * height)
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else { return nil }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: width * height)
        for index in 0..<(width * height) {
            grey[index] = Double(bytes[index]) / 255
        }

        var mask = [Bool](repeating: false, count: width * height)
        // Maximum Sobel magnitude for a 0…1 image is 4√2; normalising by it puts
        // the threshold on the same scale regardless of image contrast.
        let maximum = 4 * 2.0.squareRoot()
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let tl = grey[index - width - 1], t = grey[index - width], tr = grey[index - width + 1]
                let l = grey[index - 1], r = grey[index + 1]
                let bl = grey[index + width - 1], b = grey[index + width], br = grey[index + width + 1]
                let gx = (tr + 2 * r + br) - (tl + 2 * l + bl)
                let gy = (bl + 2 * b + br) - (tl + 2 * t + tr)
                mask[index] = ((gx * gx + gy * gy).squareRoot() / maximum) > configuration.edgeThreshold
            }
        }
        return mask
    }

    // MARK: - Route samples

    /// The route's polyline, resampled and mapped into image pixel coordinates.
    ///
    /// `runs` is used rather than `curves` because the comparison should be
    /// against the path the person actually walked, not its render-time
    /// smoothing (§5.3 — the stored route is never smoothed).
    private func routeSamples(_ shape: OrientedShape, width: Int, height: Int) -> [Point2D] {
        let scale = min(Double(width), Double(height)) / shape.canvasSize
        var samples: [Point2D] = []

        // Canvas space is top-down; the bitmap buffer's row 0 is the bottom of
        // the image in CoreGraphics' coordinates. Skipping this flip still
        // produces plausible-looking numbers — the route lands ~48px from the
        // nearest edge on a self-comparison instead of ~3px — which is exactly
        // the kind of quiet wrongness the self-comparison test exists to catch.
        func project(_ point: Point2D) -> Point2D {
            Point2D(x: point.x * scale, y: Double(height) - point.y * scale)
        }

        for run in shape.runs where run.count >= 2 {
            for index in 0..<(run.count - 1) {
                let a = project(run[index])
                let b = project(run[index + 1])
                let length = a.distance(to: b)
                let steps = max(1, Int((length / configuration.routeSampleSpacing).rounded(.up)))
                for step in 0..<steps {
                    let t = Double(step) / Double(steps)
                    samples.append(
                        Point2D(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    )
                }
            }
            if let last = run.last { samples.append(project(last)) }
        }
        return samples
    }

    // MARK: - Distance transform

    /// Two-pass chamfer distance transform (3-4 kernel), in pixels.
    ///
    /// Exact Euclidean would be better but costs more than the ~2% accuracy it
    /// buys here, and both directions use the same approximation so comparisons
    /// between conditions are unaffected.
    private func distanceTransform(of mask: [Bool], width: Int, height: Int) -> [Double] {
        let far = Double(width + height) * 4
        var distance = mask.map { $0 ? 0.0 : far }
        let near = 3.0, diagonal = 4.0

        func relax(_ index: Int, _ neighbour: Int, _ cost: Double) {
            let candidate = distance[neighbour] + cost
            if candidate < distance[index] { distance[index] = candidate }
        }

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                if y > 0 {
                    relax(index, index - width, near)
                    if x > 0 { relax(index, index - width - 1, diagonal) }
                    if x < width - 1 { relax(index, index - width + 1, diagonal) }
                }
                if x > 0 { relax(index, index - 1, near) }
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) {
                let index = y * width + x
                if y < height - 1 {
                    relax(index, index + width, near)
                    if x > 0 { relax(index, index + width - 1, diagonal) }
                    if x < width - 1 { relax(index, index + width + 1, diagonal) }
                }
                if x < width - 1 { relax(index, index + 1, near) }
            }
        }
        // The kernel counts a straight step as 3, so divide back to pixels.
        return distance.map { $0 / near }
    }
}
