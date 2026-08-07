import Foundation

/// A coarse binary raster of the route's shape.
///
/// `DESIGN.md` §6.2 — a low-dimensional summary that travels alongside the
/// control image so the VLM has numbers as well as pixels to reason about.
public struct OccupancyGrid: Sendable, Equatable {
    public let size: Int
    public private(set) var cells: [Bool]

    public init(size: Int) {
        self.size = max(1, size)
        self.cells = [Bool](repeating: false, count: self.size * self.size)
    }

    public subscript(x: Int, y: Int) -> Bool {
        get {
            guard x >= 0, x < size, y >= 0, y < size else { return false }
            return cells[y * size + x]
        }
        set {
            guard x >= 0, x < size, y >= 0, y < size else { return }
            cells[y * size + x] = newValue
        }
    }

    public var filledCount: Int { cells.lazy.filter { $0 }.count }
    public var fillRatio: Double { Double(filledCount) / Double(size * size) }

    /// Rasterises canvas-space polylines onto the grid.
    public static func rasterize(
        _ runs: [[Point2D]],
        canvasSize: Double,
        gridSize: Int = 32
    ) -> OccupancyGrid {
        var grid = OccupancyGrid(size: gridSize)
        let scale = Double(gridSize) / canvasSize

        func cell(_ p: Point2D) -> (Int, Int) {
            (
                min(gridSize - 1, max(0, Int(p.x * scale))),
                min(gridSize - 1, max(0, Int(p.y * scale)))
            )
        }

        for run in runs {
            guard let first = run.first else { continue }
            var previous = cell(first)
            grid[previous.0, previous.1] = true
            for point in run.dropFirst() {
                let current = cell(point)
                grid.drawLine(from: previous, to: current)
                previous = current
            }
        }
        return grid
    }

    /// Bresenham.
    private mutating func drawLine(from a: (Int, Int), to b: (Int, Int)) {
        var (x0, y0) = a
        let (x1, y1) = b
        let dx = abs(x1 - x0)
        let dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1
        let sy = y0 < y1 ? 1 : -1
        var error = dx + dy

        while true {
            self[x0, y0] = true
            if x0 == x1 && y0 == y1 { break }
            let doubled = 2 * error
            if doubled >= dy {
                error += dy
                x0 += sx
            }
            if doubled <= dx {
                error += dx
                y0 += sy
            }
        }
    }

    /// Zhang-Suen thinning.
    ///
    /// Bresenham leaves 2-cell-wide blobs on diagonals; those read as branch
    /// points to `branchPointCount` when they are just rasterisation artefacts.
    public func thinned() -> OccupancyGrid {
        // Thinning inspects a 3×3 neighbourhood, so anything smaller has no
        // interior to walk.
        guard size >= 3 else { return self }

        var current = self
        var changed = true

        while changed {
            changed = false
            for pass in 0..<2 {
                var toClear: [(Int, Int)] = []
                for y in 1..<(size - 1) {
                    for x in 1..<(size - 1) {
                        guard current[x, y] else { continue }
                        let n = current.neighborhood(x, y)
                        let filled = n.lazy.filter { $0 }.count
                        guard (2...6).contains(filled) else { continue }
                        guard current.crossingNumber(x, y) == 1 else { continue }

                        // n = [N, NE, E, SE, S, SW, W, NW]
                        let (north, east, south, west) = (n[0], n[2], n[4], n[6])
                        if pass == 0 {
                            guard !(north && east && south) else { continue }
                            guard !(east && south && west) else { continue }
                        } else {
                            guard !(north && east && west) else { continue }
                            guard !(north && south && west) else { continue }
                        }
                        toClear.append((x, y))
                    }
                }
                if !toClear.isEmpty {
                    changed = true
                    for (x, y) in toClear { current[x, y] = false }
                }
            }
        }
        return current
    }

    /// Cells where three or more skeleton branches meet — visually, where the
    /// route reads as having a limb, a fork, or a crossing.
    public func branchPointCount() -> Int {
        var count = 0
        for y in 0..<size {
            for x in 0..<size where self[x, y] {
                if crossingNumber(x, y) >= 3 { count += 1 }
            }
        }
        return count
    }

    /// Clockwise from north: [N, NE, E, SE, S, SW, W, NW].
    func neighborhood(_ x: Int, _ y: Int) -> [Bool] {
        [
            self[x, y - 1], self[x + 1, y - 1], self[x + 1, y], self[x + 1, y + 1],
            self[x, y + 1], self[x - 1, y + 1], self[x - 1, y], self[x - 1, y - 1],
        ]
    }

    /// Number of 0→1 transitions walking the 8-neighbourhood once around.
    /// 1 = endpoint, 2 = on a line, ≥3 = junction.
    func crossingNumber(_ x: Int, _ y: Int) -> Int {
        let n = neighborhood(x, y)
        var transitions = 0
        for i in 0..<8 where !n[i] && n[(i + 1) % 8] {
            transitions += 1
        }
        return transitions
    }
}
