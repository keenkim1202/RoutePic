import Foundation

/// One of the 16 ways to present a route's shape: 8 rotations × mirrored or not.
///
/// `DESIGN.md` §4.2 — a map is always north-up, but a person recognising a shape
/// turns it. v0.1 of the design asked the VLM to predict a rotation angle;
/// cross-review pushed back that angle regression is not stable geometry, so
/// v0.2 pre-renders every orientation and asks the model to *pick* one. That is
/// reproducible and measurable (spike SP-2).
public struct Orientation: Sendable, Equatable, Hashable, CustomStringConvertible {

    /// Degrees counter-clockwise, one of 0/45/…/315.
    public let rotationDegrees: Int
    public let mirrored: Bool

    public init(rotationDegrees: Int, mirrored: Bool) {
        self.rotationDegrees = ((rotationDegrees % 360) + 360) % 360
        self.mirrored = mirrored
    }

    /// All 16, in a fixed order. The index into this array is what the VLM
    /// returns and what `Artwork.renderIndex` stores (`DESIGN.md` §8.1), so the
    /// order must never change without a migration.
    public static let all: [Orientation] = {
        var result: [Orientation] = []
        for mirrored in [false, true] {
            for step in 0..<8 {
                result.append(Orientation(rotationDegrees: step * 45, mirrored: mirrored))
            }
        }
        return result
    }()

    /// The eight rotations, without mirroring.
    ///
    /// Mirroring is far less useful than it looks. On an open, asymmetric route
    /// a horizontal flip reads almost the same as some rotation already in the
    /// set, so half a 16-cell sheet is near-duplicates — wasted pixels and
    /// wasted model attention. It also changes the route's chirality: the
    /// silhouette becomes one the person did not actually walk.
    ///
    /// `Orientation.all` keeps all sixteen because the index is persisted
    /// (`Artwork.renderIndex`); this subset is what a contact sheet should
    /// usually show. Spike SP-2 measures whether the mirrored half earns its
    /// place.
    public static let rotationsOnly: [Orientation] = Array(all.prefix(8))

    public static let identity = Orientation(rotationDegrees: 0, mirrored: false)

    public var description: String {
        "\(rotationDegrees)°\(mirrored ? "+mirror" : "")"
    }

    /// Applies the orientation about the origin.
    ///
    /// Mirroring happens first, then rotation — the reverse order gives a
    /// different result and would silently scramble `renderIndex`.
    public func apply(to points: [Point2D]) -> [Point2D] {
        let radians = Double(rotationDegrees) * .pi / 180
        let c = cos(radians)
        let s = sin(radians)
        return points.map { p in
            let x = mirrored ? -p.x : p.x
            return Point2D(x: x * c - p.y * s, y: x * s + p.y * c)
        }
    }

    public func apply(to runs: [[Point2D]]) -> [[Point2D]] {
        runs.map(apply(to:))
    }
}
