import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ShapeKit

@Suite("ContactSheetRenderer")
struct ContactSheetTests {

    private func prepared(_ route: Route = Fixtures.wanderingWalk()) throws -> PreparedShape {
        try ShapePipeline(configuration: .init(trimMeters: 0)).prepare(route)
    }

    @Test("The default sheet is eight rotations on the squarest grid")
    func defaultLayout() {
        let renderer = ContactSheetRenderer()
        #expect(renderer.orientations().count == 8)
        #expect(renderer.orientations().allSatisfy { !$0.mirrored })
        // 8 cells → 3 columns, which gives 341px cells at 1024² rather than the
        // 256px a 4-wide grid would.
        #expect(renderer.columnCount() == 3)
    }

    @Test("Cell index equals the persisted render index")
    func cellIndexMatchesRenderIndex() {
        // A cell number the model returns is stored directly as
        // Artwork.renderIndex (DESIGN.md §8.1) — if these ever diverge, every
        // stored artwork points at the wrong orientation.
        for style in [ContactSheetRenderer.Style.standard, .allOrientations] {
            let renderer = ContactSheetRenderer(style: style)
            for (cell, orientation) in renderer.orientations().enumerated() {
                #expect(Orientation.all[cell] == orientation)
            }
        }
    }

    @Test("All sixteen orientations still fit a 4-wide grid")
    func sixteenLayout() {
        let renderer = ContactSheetRenderer(style: .allOrientations)
        #expect(renderer.orientations().count == 16)
        #expect(renderer.columnCount() == 4)
    }

    @Test("The sheet is the requested size and actually contains strokes")
    func renderInvariants() throws {
        let image = try ContactSheetRenderer().render(try prepared())
        #expect(image.width == 1024 && image.height == 1024)

        let coverage = try Self.strokeCoverage(image)
        #expect(coverage > 0.002, "sheet rendered almost nothing (\(coverage))")
        #expect(coverage < 0.5, "sheet is nearly solid")
    }

    @Test("Every cell receives a shape")
    func everyCellIsDrawn() throws {
        // A layout bug that piles all eight orientations into one cell would
        // still produce a plausible-looking image and a stable hash, so check
        // the cells individually.
        let renderer = ContactSheetRenderer(style: .bare)
        let image = try renderer.render(try prepared())
        let columns = renderer.columnCount()
        let rows = Int(ceil(Double(renderer.orientations().count) / Double(columns)))

        for index in renderer.orientations().indices {
            let coverage = try Self.strokeCoverage(
                image, column: index % columns, row: index / columns,
                columns: columns, rows: rows
            )
            #expect(coverage > 0.005, "cell \(index) is empty")
        }
    }

    @Test("The unused slot of a 3×3 grid stays empty")
    func trailingSlotIsEmpty() throws {
        let renderer = ContactSheetRenderer(style: .bare)
        let image = try renderer.render(try prepared())
        // Eight orientations in a 3×3 leaves the ninth slot unused.
        let coverage = try Self.strokeCoverage(
            image, column: 2, row: 2, columns: 3, rows: 3
        )
        #expect(coverage < 0.001)
    }

    @Test("Canvas size scales the output")
    func canvasSize() throws {
        var style = ContactSheetRenderer.Style.highResolution
        style.showsLabels = false
        let image = try ContactSheetRenderer(style: style).render(try prepared())
        #expect(image.width == 2048)
    }

    @Test("Rendering is deterministic")
    func deterministic() throws {
        let renderer = ContactSheetRenderer()
        let shape = try prepared()
        #expect(try renderer.renderPNG(shape) == (try renderer.renderPNG(shape)))
    }

    @Test("Labels and separators change the image")
    func chromeMatters() throws {
        let shape = try prepared()
        let bare = try ContactSheetRenderer(style: .bare).renderPNG(shape)
        let labelled = try ContactSheetRenderer(style: .standard).renderPNG(shape)
        #expect(bare != labelled)
    }

    @Test("Degenerate routes render without crashing", arguments: [
        Fixtures.twoPoints, Fixtures.straightLine, Fixtures.closedLoop(),
        Fixtures.multipleGaps, Fixtures.duplicateCoordinates,
    ])
    func degenerateRoutes(route: Route) throws {
        let image = try ContactSheetRenderer().render(try prepared(route))
        #expect(image.width == 1024)
    }

    @Test("The layout description names the grid and every cell")
    func layoutDescription() {
        // The model is told the numbering rather than left to infer it — that
        // inference is where "which one is cell 5?" ambiguity comes from.
        let description = ContactSheetRenderer().layoutDescription()
        #expect(description.contains("3×3"))
        for index in 0..<8 {
            #expect(description.contains("\(index)="))
        }
        #expect(!description.contains("mirror"), "default sheet has no mirrored cells")

        let full = ContactSheetRenderer(style: .allOrientations).layoutDescription()
        #expect(full.contains("4×4"))
        #expect(full.contains("mirror"))
    }

    @Test("Sheet matches its recorded hash")
    func golden() throws {
        // Same regression guard as the control images: a silent change to cell
        // layout, stroke width, or padding changes every generation the app
        // will ever make.
        let actual = Self.hash(try ContactSheetRenderer().renderPNG(try prepared()))
        print("golden-sheet: \"\(actual)\"")

        let expected = "096dde1288511539fbd11636c857331046c3a1069167bb9d7704b7155bd39fc9"
        guard expected != "PENDING" else {
            Issue.record("No baseline recorded. Paste the printed hash in.")
            return
        }
        #expect(actual == expected, "contact sheet rendering changed")
    }

    // MARK: - Helpers

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Fraction of lit pixels, optionally within one grid cell.
    private static func strokeCoverage(
        _ image: CGImage,
        column: Int? = nil, row: Int? = nil, columns: Int = 1, rows: Int = 1
    ) throws -> Double {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        let bytesPerPixel = image.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return 0 }

        let cellWidth = image.width / columns
        let cellHeight = image.height / rows
        let xRange = column.map { ($0 * cellWidth)..<(($0 + 1) * cellWidth) } ?? 0..<image.width
        let yRange = row.map { ($0 * cellHeight)..<(($0 + 1) * cellHeight) } ?? 0..<image.height

        var lit = 0
        var total = 0
        for y in yRange {
            let rowStart = y * image.bytesPerRow
            for x in xRange {
                let offset = rowStart + x * bytesPerPixel
                guard offset + 2 < data.count else { continue }
                total += 1
                let sum = Int(data[offset]) + Int(data[offset + 1]) + Int(data[offset + 2])
                if sum > 384 { lit += 1 }
            }
        }
        guard total > 0 else { return 0 }
        return Double(lit) / Double(total)
    }
}
