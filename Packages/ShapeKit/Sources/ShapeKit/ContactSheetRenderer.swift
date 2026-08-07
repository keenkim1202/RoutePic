import CoreGraphics
import CoreText
import Foundation

/// Draws every orientation into one labelled grid image.
///
/// The VLM has to compare orientations to pick one (`DESIGN.md` §4.2), and it
/// can do that from a single contact sheet instead of 16 separate attachments.
/// That matters twice over:
///
/// - **Cost.** Sixteen 1024² attachments are ~22,400 image tokens; one 1024²
///   sheet is ~1,400. Same comparison, ~16× less input.
/// - **Feasibility.** Apple's on-device model has a 4K token context that images
///   share with the prompt. Sixteen separate images cannot fit at all, so the
///   sheet is not an optimisation there — it is the only shape that works.
///
/// The trade is resolution: a 4×4 grid on a 1024² canvas gives each orientation
/// ~256². A route is a single stroke on a plain background, so it should survive
/// that — but "should" is a hypothesis, and spike SP-2 measures it against
/// separate full-size renders.
public struct ContactSheetRenderer: Sendable {

    public struct Style: Sendable {
        public var canvasSize: Double
        /// Which orientations to draw. Defaults to `Orientation.rotationsOnly` —
        /// see that property for why the mirrored half is usually dead weight.
        public var orientations: [Orientation]
        /// `nil` lays the grid out as square as possible, which keeps cells as
        /// large as the canvas allows.
        public var columns: Int?
        /// Stroke width in **cell** units, scaled with the cell like the shape.
        public var lineWidth: Double
        public var cellPadding: Double
        /// Numbers each cell so the model can name one. Without them it has to
        /// describe a position ("third from the left"), which is far easier to
        /// misread than an index.
        public var showsLabels: Bool
        public var showsSeparators: Bool

        public var background: CGColor
        public var stroke: CGColor
        public var label: CGColor
        public var separator: CGColor

        public init(
            canvasSize: Double = 1024,
            orientations: [Orientation] = Orientation.rotationsOnly,
            columns: Int? = nil,
            lineWidth: Double = 5,
            cellPadding: Double = 0.10,
            showsLabels: Bool = true,
            showsSeparators: Bool = true,
            background: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            stroke: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            label: CGColor = CGColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1),
            separator: CGColor = CGColor(red: 0.22, green: 0.22, blue: 0.22, alpha: 1)
        ) {
            self.canvasSize = canvasSize
            self.orientations = orientations
            self.columns = columns.map { max(1, $0) }
            self.lineWidth = lineWidth
            self.cellPadding = cellPadding
            self.showsLabels = showsLabels
            self.showsSeparators = showsSeparators
            self.background = background
            self.stroke = stroke
            self.label = label
            self.separator = separator
        }

        /// Eight rotations on a 3×3 grid at 1024² — ~341px cells, ~1,400 image
        /// tokens. The default.
        public static let standard = Style()

        /// All sixteen orientations, 4×4 at 1024² (~256px cells). Same token
        /// cost as `standard`; half the cells are near-duplicates. Kept so SP-2
        /// can measure the mirrored half rather than assume it.
        public static let allOrientations = Style(orientations: Orientation.all)

        /// 2048² canvas. Roughly 4× the tokens of `standard` and still far
        /// below separate per-orientation renders. For when SP-2 shows the
        /// smaller cells lose detail the model needed.
        public static let highResolution = Style(canvasSize: 2048)

        /// No labels or separators — for pixel-comparison tests where the
        /// chrome would dominate the diff.
        public static let bare = Style(showsLabels: false, showsSeparators: false)
    }

    public enum Failure: Error, CustomStringConvertible {
        case contextCreationFailed
        case imageCreationFailed

        public var description: String {
            switch self {
            case .contextCreationFailed: "Could not create the contact sheet bitmap context."
            case .imageCreationFailed: "Could not snapshot the contact sheet context."
            }
        }
    }

    public var style: Style

    public init(style: Style = .standard) {
        self.style = style
    }

    /// Cell index → orientation, in drawing order.
    ///
    /// This is the same order as `Orientation.all`, which is also what
    /// `Artwork.renderIndex` persists (`DESIGN.md` §8.1) — so a cell number the
    /// model returns is directly a stored render index, with no lookup table to
    /// drift out of sync.
    public func orientations() -> [Orientation] { style.orientations }

    /// Columns actually used: the configured value, or the squarest grid that
    /// holds every cell.
    public func columnCount() -> Int {
        style.columns ?? max(1, Int(ceil(Double(style.orientations.count).squareRoot())))
    }

    public func render(_ prepared: PreparedShape) throws -> CGImage {
        let side = Int(style.canvasSize.rounded())
        guard
            let context = CGContext(
                data: nil, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw Failure.contextCreationFailed }

        context.setFillColor(style.background)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let all = orientations()
        guard !all.isEmpty else { throw Failure.imageCreationFailed }
        let columns = columnCount()
        let rows = Int(ceil(Double(all.count) / Double(columns)))
        let cellWidth = style.canvasSize / Double(columns)
        let cellHeight = style.canvasSize / Double(rows)

        if style.showsSeparators {
            drawSeparators(in: context, columns: columns, rows: rows,
                           cellWidth: cellWidth, cellHeight: cellHeight)
        }

        for (index, orientation) in all.enumerated() {
            let column = index % columns
            let row = index / columns
            // CoreGraphics origin is bottom-left; cells are numbered top-left
            // first, which is how a reader scans them.
            let originY = style.canvasSize - Double(row + 1) * cellHeight
            let cell = CGRect(
                x: Double(column) * cellWidth, y: originY,
                width: cellWidth, height: cellHeight
            )
            draw(prepared.oriented(orientation), in: context, cell: cell)
            if style.showsLabels { drawLabel(index, in: context, cell: cell) }
        }

        guard let image = context.makeImage() else { throw Failure.imageCreationFailed }
        return image
    }

    public func renderPNG(_ prepared: PreparedShape) throws -> Data {
        try ControlImageRenderer.pngData(from: try render(prepared))
    }

    // MARK: - Drawing

    private func draw(_ shape: OrientedShape, in context: CGContext, cell: CGRect) {
        let inset = min(cell.width, cell.height) * style.cellPadding
        let content = cell.insetBy(dx: inset, dy: inset)
        let scale = min(content.width, content.height) / shape.canvasSize

        context.saveGState()
        context.translateBy(x: content.minX, y: content.minY)
        context.scaleBy(x: scale, y: scale)
        // Canvas space is top-down; CoreGraphics is bottom-up.
        context.translateBy(x: 0, y: shape.canvasSize)
        context.scaleBy(x: 1, y: -1)

        context.setStrokeColor(style.stroke)
        // Divided by the scale so the stroke lands at the requested cell-space
        // width rather than being shrunk along with the shape.
        context.setLineWidth(style.lineWidth / scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)
        context.addPath(ControlImageRenderer(style: .control).path(for: shape))
        context.strokePath()
        context.restoreGState()
    }

    private func drawSeparators(
        in context: CGContext, columns: Int, rows: Int,
        cellWidth: Double, cellHeight: Double
    ) {
        context.saveGState()
        context.setStrokeColor(style.separator)
        context.setLineWidth(max(1, style.canvasSize / 512))

        for column in 1..<max(columns, 1) {
            let x = Double(column) * cellWidth
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: style.canvasSize))
        }
        for row in 1..<max(rows, 1) {
            let y = Double(row) * cellHeight
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: style.canvasSize, y: y))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawLabel(_ index: Int, in context: CGContext, cell: CGRect) {
        let size = min(cell.width, cell.height) * 0.11
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(
            string: "\(index)",
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.label,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)

        context.saveGState()
        // Bottom-left of the cell: the shape is centred, so a corner keeps the
        // label from overlapping the stroke.
        context.textPosition = CGPoint(x: cell.minX + size * 0.5, y: cell.minY + size * 0.4)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

extension ContactSheetRenderer {

    /// A description of the sheet's layout, to send alongside the image.
    ///
    /// The model is told what the grid is and how the cells are numbered rather
    /// than being left to infer it, which is where "which one is cell 5?"
    /// ambiguity comes from.
    public func layoutDescription() -> String {
        let all = orientations()
        let rows = Int(ceil(Double(all.count) / Double(columnCount())))
        let entries = all.enumerated()
            .map { "\($0.offset)=\($0.element.description)" }
            .joined(separator: ", ")

        // The mirror clause is included only when a mirrored cell exists.
        // Explaining a transform the sheet does not contain is noise in a prompt
        // whose budget the image already dominates.
        let mirrorNote = all.contains(where: \.mirrored)
            ? " \"mirror\" means the shape was flipped horizontally before rotating."
            : ""

        return """
        A \(columnCount())×\(rows) grid of the same route, each cell a different \
        orientation. Cells are numbered from 0, left to right then top to bottom, \
        matching the small digit in each cell's lower-left corner. \
        Rotations are counter-clockwise.\(mirrorNote) Cell index → orientation: \(entries).
        """
    }
}
