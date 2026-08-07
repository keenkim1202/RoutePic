import Foundation

/// Fits a projected shape into a square canvas.
///
/// `DESIGN.md` §6 step 5. Everything downstream — the control image, the
/// fingerprint's occupancy grid, the card renderer — works in this space, so a
/// 400 m walk and a 40 km drive become directly comparable.
public enum Normalize {

    public static let defaultCanvasSize = 1024.0

    /// `DESIGN.md` §6: 8% padding, so a stroke at the edge is not clipped and
    /// the diffusion model sees the shape whole rather than bleeding off-frame.
    public static let defaultPaddingFraction = 0.08

    /// Scales and centres `points` inside a `canvasSize` square, preserving
    /// aspect ratio.
    ///
    /// Y is flipped: projected space is north-up (y grows north), image space is
    /// top-down. Skipping this renders every route mirrored about the horizontal.
    public static func toCanvas(
        _ runs: [[Point2D]],
        canvasSize: Double = defaultCanvasSize,
        paddingFraction: Double = defaultPaddingFraction
    ) -> [[Point2D]] {
        let all = runs.flatMap { $0 }
        guard let box = BoundingBox(all) else { return runs }

        let usable = canvasSize * (1 - 2 * paddingFraction)
        let scale: Double
        if box.width <= 0 && box.height <= 0 {
            scale = 1                      // a single point, or many coincident ones
        } else {
            scale = usable / max(box.width, box.height)
        }

        let scaledWidth = box.width * scale
        let scaledHeight = box.height * scale
        let offsetX = (canvasSize - scaledWidth) / 2
        let offsetY = (canvasSize - scaledHeight) / 2

        return runs.map { run in
            run.map { p in
                Point2D(
                    x: (p.x - box.minX) * scale + offsetX,
                    y: canvasSize - ((p.y - box.minY) * scale + offsetY)
                )
            }
        }
    }

    public static func toCanvas(
        _ points: [Point2D],
        canvasSize: Double = defaultCanvasSize,
        paddingFraction: Double = defaultPaddingFraction
    ) -> [Point2D] {
        toCanvas([points], canvasSize: canvasSize, paddingFraction: paddingFraction).first ?? []
    }
}
