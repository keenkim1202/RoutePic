import Foundation

/// Ramer–Douglas–Peucker simplification.
///
/// `DESIGN.md` §6 step 3. Two jobs: strip GPS jitter that would otherwise read
/// as texture in the control image, and get the vertex count into a range the
/// VLM and the fingerprint can both work with.
public enum Simplify {

    /// The design targets 60–200 vertices (`DESIGN.md` §6).
    public static let defaultTargetRange = 60...200

    public static func rdp(_ points: [Point2D], epsilon: Double) -> [Point2D] {
        guard points.count > 2, epsilon > 0 else { return points }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        // Explicit stack: a recursive version blows up on the ~10k-point routes
        // a long drive produces.
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }

            var maxDistance = 0.0
            var maxIndex = first
            for i in (first + 1)..<last {
                let d = Geometry.perpendicularDistance(points[i], a: points[first], b: points[last])
                if d > maxDistance {
                    maxDistance = d
                    maxIndex = i
                }
            }

            if maxDistance > epsilon {
                keep[maxIndex] = true
                stack.append((first, maxIndex))
                stack.append((maxIndex, last))
            }
        }

        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    /// Binary-searches epsilon until the vertex count lands in `targetRange`.
    ///
    /// A fixed epsilon cannot work across modes: 5 m of jitter is noise on a
    /// 40 km drive and the entire shape on a 400 m walk.
    public static func adaptive(
        _ points: [Point2D],
        targetRange: ClosedRange<Int> = defaultTargetRange,
        maxIterations: Int = 24
    ) -> [Point2D] {
        guard points.count > targetRange.upperBound else { return points }

        guard let box = BoundingBox(points) else { return points }
        let diagonal = Point2D(x: box.width, y: box.height).length
        guard diagonal > 0 else { return [points[0], points[points.count - 1]] }

        var low = 0.0
        var high = diagonal
        var best = points

        for _ in 0..<maxIterations {
            let mid = (low + high) / 2
            let candidate = rdp(points, epsilon: mid)

            if candidate.count > targetRange.upperBound {
                low = mid              // too detailed, simplify harder
            } else if candidate.count < targetRange.lowerBound {
                high = mid             // too coarse, back off
                best = candidate       // keep it as a floor in case we never land inside
            } else {
                return candidate
            }

            if candidate.count <= targetRange.upperBound {
                best = candidate
            }
        }

        return best
    }
}
