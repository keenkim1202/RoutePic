import CoreGraphics
import Foundation
import ImageIO

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Renders a shape as a white line on black — the control image the diffusion
/// model is conditioned on.
///
/// `DESIGN.md` §6 step 7 and §7.1. What the line *means* to the model (outline,
/// centreline, or loose hint) is spike SP-3's job to settle; this renderer just
/// produces the input, with stroke width exposed because that is one of the
/// variables SP-3 and SP-4 sweep.
public struct ControlImageRenderer: Sendable {

    public struct Style: Sendable {
        public var lineWidth: Double
        public var background: CGColor
        public var stroke: CGColor
        /// Gaps are drawn as separate subpaths, never joined. `DESIGN.md` §5.4.
        public var drawsGapsAsBreaks: Bool

        public init(
            lineWidth: Double = 11,
            background: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1),
            stroke: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            drawsGapsAsBreaks: Bool = true
        ) {
            self.lineWidth = lineWidth
            self.background = background
            self.stroke = stroke
            self.drawsGapsAsBreaks = drawsGapsAsBreaks
        }

        /// `DESIGN.md` §6: 8–14 px on a 1024² canvas.
        public static let control = Style()
        public static let thin = Style(lineWidth: 8)
        public static let thick = Style(lineWidth: 14)
    }

    public enum Failure: DescribedError {
        case contextCreationFailed
        case imageCreationFailed
        case encodingFailed

        public var description: String {
            switch self {
            case .contextCreationFailed: return "Could not create a CoreGraphics bitmap context."
            case .imageCreationFailed: return "Could not snapshot the bitmap context."
            case .encodingFailed: return "Could not encode the image as PNG."
            }
        }
    }

    public var style: Style

    public init(style: Style = .control) {
        self.style = style
    }

    public func path(for shape: OrientedShape) -> CGPath {
        let path = CGMutablePath()
        for curves in shape.curves {
            guard let first = curves.first else { continue }
            path.move(to: CGPoint(x: first.start.x, y: first.start.y))
            for segment in curves {
                path.addCurve(
                    to: CGPoint(x: segment.end.x, y: segment.end.y),
                    control1: CGPoint(x: segment.control1.x, y: segment.control1.y),
                    control2: CGPoint(x: segment.control2.x, y: segment.control2.y)
                )
            }
        }
        return path
    }

    public func render(_ shape: OrientedShape) throws -> CGImage {
        let side = Int(shape.canvasSize.rounded())
        guard
            let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw Failure.contextCreationFailed }

        context.setFillColor(style.background)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        context.setStrokeColor(style.stroke)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)
        context.addPath(path(for: shape))
        context.strokePath()

        guard let image = context.makeImage() else { throw Failure.imageCreationFailed }
        return image
    }

    public func renderPNG(_ shape: OrientedShape) throws -> Data {
        try Self.pngData(from: try render(shape))
    }

    public static func pngData(from image: CGImage) throws -> Data {
        let output = NSMutableData()
        let type: CFString
        #if canImport(UniformTypeIdentifiers)
        type = UTType.png.identifier as CFString
        #else
        type = "public.png" as CFString
        #endif

        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            throw Failure.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return output as Data
    }
}
