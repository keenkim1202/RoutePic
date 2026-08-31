import CoreGraphics
import CoreText
import Foundation
import RouteKit
import ShapeKit

/// Renders the shareable card.
///
/// `DESIGN.md` §4.4 — this is the fallback that makes the app work when the AI
/// fails, is offline, or the quota is spent, and §12 makes it permanently free.
/// It is also what M4 ships before any generation exists at all, so it has to
/// stand on its own rather than look like a placeholder.
public struct CardRenderer: Sendable {

    public enum Aspect: String, Sendable, CaseIterable {
        case square          // 1:1
        case portrait        // 4:5
        case story           // 9:16

        public var size: CGSize {
            switch self {
            case .square: CGSize(width: 1080, height: 1080)
            case .portrait: CGSize(width: 1080, height: 1350)
            case .story: CGSize(width: 1080, height: 1920)
            }
        }

        var layout: Layout {
            switch self {
            case .square: .square
            case .portrait: .portrait
            case .story: .story
            }
        }
    }

    /// What the user ticked. `DESIGN.md` §9 — place name and the route line
    /// default to **off**, because both can locate a person.
    public struct Contents: Sendable {
        public var showsDistance: Bool
        public var showsDuration: Bool
        public var showsPlaceName: Bool
        public var showsRouteLine: Bool
        public var showsDate: Bool

        public init(
            showsDistance: Bool = true,
            showsDuration: Bool = true,
            showsPlaceName: Bool = false,
            showsRouteLine: Bool = false,
            showsDate: Bool = true
        ) {
            self.showsDistance = showsDistance
            self.showsDuration = showsDuration
            self.showsPlaceName = showsPlaceName
            self.showsRouteLine = showsRouteLine
            self.showsDate = showsDate
        }

        /// The safe default: nothing that pins the user to a place.
        public static let `default` = Contents()
    }

    public struct Palette: Sendable, Hashable, Identifiable {
        /// Its name is its identity: the colours are tuples, which no synthesised
        /// conformance will compare, and a picker needs something to tag with.
        public var id: String { name }
        public static func == (a: Palette, b: Palette) -> Bool { a.name == b.name }
        public func hash(into hasher: inout Hasher) { hasher.combine(name) }

        public var name: String
        public var background: (CGFloat, CGFloat, CGFloat)
        public var backgroundEnd: (CGFloat, CGFloat, CGFloat)
        public var line: (CGFloat, CGFloat, CGFloat)
        public var text: (CGFloat, CGFloat, CGFloat)
        /// Everything under the reason sentence. Dimmer so the subject and the
        /// route stay the first two things read.
        public var secondaryText: (CGFloat, CGFloat, CGFloat)

        public static let dusk = Palette(
            name: "Dusk",
            background: (0.09, 0.10, 0.16),
            backgroundEnd: (0.18, 0.14, 0.28),
            line: (0.98, 0.87, 0.55),
            text: (0.96, 0.96, 0.98),
            secondaryText: (0.78, 0.78, 0.86)
        )
        public static let mint = Palette(
            name: "Mint",
            background: (0.05, 0.16, 0.14),
            backgroundEnd: (0.08, 0.28, 0.22),
            line: (0.75, 0.98, 0.85),
            text: (0.95, 1.0, 0.97),
            secondaryText: (0.74, 0.90, 0.82)
        )
        /// The route as something fired or drawn rather than lit.
        public static let clay = Palette(
            name: "Clay",
            background: (0.176, 0.071, 0.094),
            backgroundEnd: (0.678, 0.263, 0.176),
            line: (1.0, 0.792, 0.533),
            text: (1.0, 0.961, 0.886),
            secondaryText: (1.0, 0.878, 0.745)
        )
        /// The route as a contour on a specimen card.
        public static let ink = Palette(
            name: "Ink",
            background: (0.047, 0.059, 0.110),
            backgroundEnd: (0.184, 0.118, 0.282),
            line: (1.0, 0.404, 0.443),
            text: (0.976, 0.965, 1.0),
            secondaryText: (0.812, 0.776, 0.886)
        )

        public static let all: [Palette] = [.dusk, .mint, .clay, .ink]
    }

    public enum Failure: DescribedError {
        case contextCreationFailed
        public var description: String { "Could not create the card bitmap context." }
    }


    /// Where everything sits, as fractions of the canvas with a top-left
    /// origin. Split per aspect because a story card that is the square one
    /// stretched reads as a stretched poster: it aligns left, keeps its content
    /// inside the zone story interfaces do not cover, and gives the reason a
    /// fourth line rather than a bigger number.
    struct Layout {
        var art: CGRect
        var subjectTop: CGFloat
        var subjectSize: CGFloat
        var reasonTop: CGFloat
        var reasonSize: CGFloat
        var reasonLines: Int
        var metricsTop: CGFloat
        var metaTop: CGFloat
        var textInset: CGFloat
        var centred: Bool

        static let square = Layout(
            art: CGRect(x: 0.08, y: 0.07, width: 0.84, height: 0.55),
            subjectTop: 0.655, subjectSize: 64,
            reasonTop: 0.735, reasonSize: 31, reasonLines: 3,
            metricsTop: 0.862, metaTop: 0.925,
            textInset: 0.12, centred: true
        )
        static let portrait = Layout(
            art: CGRect(x: 0.08, y: 0.07, width: 0.84, height: 0.51),
            subjectTop: 0.615, subjectSize: 64,
            reasonTop: 0.695, reasonSize: 32, reasonLines: 3,
            metricsTop: 0.840, metaTop: 0.905,
            textInset: 0.11, centred: true
        )
        static let story = Layout(
            art: CGRect(x: 0.07, y: 0.17, width: 0.86, height: 0.42),
            subjectTop: 0.630, subjectSize: 68,
            reasonTop: 0.715, reasonSize: 34, reasonLines: 4,
            metricsTop: 0.845, metaTop: 0.895,
            textInset: 0.09, centred: false
        )
    }

    public var aspect: Aspect
    public var palette: Palette

    public init(aspect: Aspect = .square, palette: Palette = .dusk) {
        self.aspect = aspect
        self.palette = palette
    }

    /// Draws a card from a derived shape.
    ///
    /// `artwork` is the generated image when there is one. Without it the route
    /// line carries the card — which is the whole point of the fallback.
    public func render(
        shape: OrientedShape,
        statistics: ActivityStatistics,
        mode: RecordingMode,
        date: Date,
        placeName: String?,
        contents: Contents = .default,
        artwork: CGImage? = nil,
        subject: String? = nil,
        reason: String? = nil,
        timeZone: TimeZone = .current
    ) throws -> CGImage {
        let size = aspect.size
        guard
            let context = CGContext(
                data: nil,
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw Failure.contextCreationFailed }

        drawBackground(in: context, size: size)

        let layout = aspect.layout
        let artRect = CGRect(
            x: layout.art.minX * size.width,
            // Frames are given top-down; CoreGraphics counts up from the floor.
            y: size.height - (layout.art.minY + layout.art.height) * size.height,
            width: layout.art.width * size.width,
            height: layout.art.height * size.height
        )

        if let artwork {
            context.saveGState()
            context.addPath(CGPath(roundedRect: artRect, cornerWidth: 36, cornerHeight: 36, transform: nil))
            context.clip()
            // Fitted, not stretched. The frame stopped being square when the
            // card started leading with the reading, and a 1024² picture drawn
            // straight into it comes out squashed.
            context.draw(artwork, in: Self.fit(
                CGSize(width: artwork.width, height: artwork.height), in: artRect
            ))
            context.restoreGState()
        }

        // The route line is drawn when there is no artwork (it *is* the card),
        // or when the user explicitly asked to overlay it.
        if artwork == nil || contents.showsRouteLine {
            drawRoute(shape, in: context, rect: artRect, emphasised: artwork == nil)
        }

        drawReading(
            subject: subject, reason: reason, in: context, size: size, layout: layout
        )
        drawStatistics(
            in: context, size: size, layout: layout,
            statistics: statistics, mode: mode, date: date,
            placeName: placeName, contents: contents, timeZone: timeZone
        )

        guard let image = context.makeImage() else { throw Failure.contextCreationFailed }
        return image
    }

    // MARK: - Drawing

    private func drawBackground(in context: CGContext, size: CGSize) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            CGColor(colorSpace: colorSpace, components: [palette.background.0, palette.background.1, palette.background.2, 1])!,
            CGColor(colorSpace: colorSpace, components: [palette.backgroundEnd.0, palette.backgroundEnd.1, palette.backgroundEnd.2, 1])!,
        ]
        guard
            let gradient = CGGradient(
                colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1]
            )
        else { return }

        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size.height),
            end: CGPoint(x: size.width, y: 0),
            options: []
        )
    }

    private func drawRoute(
        _ shape: OrientedShape, in context: CGContext, rect: CGRect, emphasised: Bool
    ) {
        let scale = min(rect.width, rect.height) / shape.canvasSize
        // Centred in the frame. The shape is normalised into a square canvas,
        // so anything but a square frame leaves it in a corner otherwise — and
        // no frame is square once the card leads with the reading.
        let drawn = shape.canvasSize * scale
        context.saveGState()
        context.translateBy(
            x: rect.minX + (rect.width - drawn) / 2,
            y: rect.minY + (rect.height - drawn) / 2
        )
        context.scaleBy(x: scale, y: scale)
        // Canvas space is top-down; CoreGraphics is bottom-up.
        context.translateBy(x: 0, y: shape.canvasSize)
        context.scaleBy(x: 1, y: -1)

        // A run shorter than this renders as a dot or a speck of noise. The
        // gap either side already says the recording stopped; a mark that is
        // not a line adds nothing but grit.
        let shortestDrawnRun = rect.width * 0.006 / scale

        let path = CGMutablePath()
        for curves in shape.curves {
            guard let first = curves.first else { continue }
            guard Self.spans(curves, atLeast: shortestDrawnRun) else { continue }
            path.move(to: CGPoint(x: first.start.x, y: first.start.y))
            for segment in curves {
                path.addCurve(
                    to: CGPoint(x: segment.end.x, y: segment.end.y),
                    control1: CGPoint(x: segment.control1.x, y: segment.control1.y),
                    control2: CGPoint(x: segment.control2.x, y: segment.control2.y)
                )
            }
        }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(
            red: palette.line.0, green: palette.line.1, blue: palette.line.2,
            alpha: emphasised ? 1 : 0.85
        )
        context.setLineWidth(emphasised ? 16 : 10)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// The subject and its reason: the two lines nothing else on a phone says.
    ///
    /// The subject is allowed a second line before it is allowed to shrink — a
    /// long name set small reads as an apology for itself.
    private func drawReading(
        subject: String?, reason: String?, in context: CGContext,
        size: CGSize, layout: Layout
    ) {
        let width = size.width * (1 - layout.textInset * 2)
        let heading = subject ?? Self.unnamedSubject
        let sentence = reason ?? Self.unnamedReason

        let title = Self.wrap(
            heading, size: layout.subjectSize, minimumSize: 44,
            weight: "HelveticaNeue-Medium", color: color(palette.text),
            maxWidth: width, maxLines: 2
        )
        draw(title, in: context, size: size,
             topFraction: layout.subjectTop, inset: layout.textInset, centred: layout.centred)

        let (reasonTop, fits) = Self.reasonBox(
            layout, subjectHeight: title.height, canvasHeight: size.height
        )
        let body = Self.wrap(
            sentence, size: layout.reasonSize, minimumSize: 27,
            weight: "HelveticaNeue", color: color(palette.secondaryText),
            maxWidth: width, maxLines: fits
        )
        draw(body, in: context, size: size,
             topFraction: reasonTop / size.height, inset: layout.textInset, centred: layout.centred)
    }

    /// Where the sentence starts and how many lines it may have.
    ///
    /// Flowed from the subject rather than placed: at a fixed top a two-line
    /// subject pushed the sentence down until its last line sat on the
    /// distance, and the metrics are anchored to the bottom edge.
    static func reasonBox(
        _ layout: Layout, subjectHeight: CGFloat, canvasHeight: CGFloat
    ) -> (top: CGFloat, lines: Int) {
        let gap = (layout.reasonTop - layout.subjectTop) * canvasHeight - layout.subjectSize * 1.2
        let top = layout.subjectTop * canvasHeight + subjectHeight + max(gap, 0)
        let room = layout.metricsTop * canvasHeight - top
        let lineHeight = layout.reasonSize * 1.2
        return (top, max(1, min(layout.reasonLines, Int(room / lineHeight))))
    }

    /// `DESIGN.md` §4.4 — a route that matches nothing is said to match
    /// nothing. Naming it "abstract" would claim a reading the geometry
    /// refused to give.
    public static let unnamedSubject = "A route of its own"
    public static let unnamedReason =
        "This one did not settle into a shape RoutePic knows."

    private func drawStatistics(
        in context: CGContext,
        size: CGSize,
        layout: Layout,
        statistics: ActivityStatistics,
        mode: RecordingMode,
        date: Date,
        placeName: String?,
        contents: Contents,
        timeZone: TimeZone
    ) {
        var primary: [String] = []
        if contents.showsDistance {
            primary.append(CardFormatter.distance(statistics.distanceMeters))
        }
        if contents.showsDuration {
            primary.append(CardFormatter.duration(statistics.movingDuration))
        }
        // Pace goes before duration or distance do: it is the one a driver has
        // no use for and a walker can read off the other two.
        if let pace = statistics.paceSecondsPerKilometre, mode != .drive, contents.showsDistance {
            primary.append(CardFormatter.pace(pace))
        }

        var meta: [String] = [mode.title.uppercased()]
        if contents.showsDate { meta.append(CardFormatter.date(date, timeZone: timeZone)) }
        if contents.showsPlaceName, let placeName { meta.append(placeName) }

        let width = size.width * (1 - layout.textInset * 2)
        if !primary.isEmpty {
            let line = Self.wrap(
                primary.joined(separator: "   ·   "), size: 48, minimumSize: 34,
                weight: "HelveticaNeue-Medium", color: color(palette.text),
                maxWidth: width, maxLines: 1
            )
            draw(line, in: context, size: size, topFraction: layout.metricsTop,
                 inset: layout.textInset, centred: layout.centred)
        }
        let line = Self.wrap(
            meta.joined(separator: "   ·   "), size: 26, minimumSize: 20,
            weight: "HelveticaNeue", color: color(palette.secondaryText),
            maxWidth: width, maxLines: 1
        )
        draw(line, in: context, size: size, topFraction: layout.metaTop,
             inset: layout.textInset, centred: layout.centred)
    }

    /// The largest rect of `size`'s proportions that sits inside `frame`,
    /// centred. Letterboxed rather than cropped: a route picture loses its
    /// subject at the edges.
    static func fit(_ size: CGSize, in frame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return frame }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: frame.midX - drawn.width / 2,
            y: frame.midY - drawn.height / 2,
            width: drawn.width, height: drawn.height
        )
    }

    /// Whether a run covers enough ground to be worth a stroke, measured on its
    /// bounding box rather than its arc length — the box is what decides
    /// whether it reads as a line or a dot.
    static func spans(_ curves: [BezierSegment], atLeast distance: Double) -> Bool {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for segment in curves {
            for point in [segment.start, segment.end] {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
        }
        guard minX.isFinite, minY.isFinite else { return false }
        return hypot(maxX - minX, maxY - minY) >= distance
    }

    /// A string laid out over as many lines as it is allowed.
    ///
    /// The renderer drew one `CTLine` per string, which is why the reason — the
    /// most distinctive sentence the app has — was not on the card at all.
    struct Wrapped {
        var lines: [CTLine]
        var lineHeight: CGFloat
        var height: CGFloat { CGFloat(lines.count) * lineHeight }
    }

    /// Breaks at the preferred size, then steps down to `minimumSize` rather
    /// than spilling past `maxLines`. Past that the last line is truncated:
    /// the reason is product text and is never reworded to fit.
    static func wrap(
        _ text: String, size: CGFloat, minimumSize: CGFloat,
        weight: String, color: CGColor, maxWidth: CGFloat, maxLines: Int
    ) -> Wrapped {
        var size = size
        while true {
            let lines = breakLines(text, size: size, weight: weight, color: color, maxWidth: maxWidth)
            if lines.count <= maxLines || size <= minimumSize {
                return Wrapped(lines: Array(lines.prefix(maxLines)), lineHeight: size * 1.2)
            }
            size = max(minimumSize, size - 4)
        }
    }

    private static func breakLines(
        _ text: String, size: CGFloat, weight: String, color: CGColor, maxWidth: CGFloat
    ) -> [CTLine] {
        let attributed = attributedString(text, size: size, weight: weight, color: color)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var start = 0
        while start < length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(maxWidth))
            // A width too small for even one glyph returns zero, and the loop
            // would never end.
            guard count > 0 else { break }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        return lines
    }

    private static func attributedString(
        _ text: String, size: CGFloat, weight: String, color: CGColor
    ) -> NSAttributedString {
        let font = CTFontCreateWithName(weight as CFString, size, nil)
        return NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
        )
    }

    /// Draws a wrapped block from its top edge downward.
    private func draw(
        _ wrapped: Wrapped, in context: CGContext, size: CGSize,
        topFraction: CGFloat, inset: CGFloat, centred: Bool
    ) {
        var y = size.height - topFraction * size.height - wrapped.lineHeight * 0.8
        for line in wrapped.lines {
            let bounds = CTLineGetBoundsWithOptions(line, [])
            let x = centred ? (size.width - bounds.width) / 2 : inset * size.width
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
            y -= wrapped.lineHeight
        }
    }

    private func color(_ rgb: (CGFloat, CGFloat, CGFloat)) -> CGColor {
        CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [rgb.0, rgb.1, rgb.2, 1]
        )!
    }

}

/// Number formatting for the card.
///
/// Locale-aware because `DESIGN.md` §14.2 lists km/mi and localisation as
/// requirements, and a hard-coded "km" is wrong for most of the App Store.
public enum CardFormatter {

    public static func usesMetric(_ locale: Locale = .current) -> Bool {
        locale.measurementSystem != .us
    }

    public static func distance(_ metres: Double, locale: Locale = .current) -> String {
        if usesMetric(locale) {
            return String(format: "%.2f km", metres / 1000)
        }
        return String(format: "%.2f mi", metres / 1609.344)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    public static func pace(_ secondsPerKilometre: Double, locale: Locale = .current) -> String {
        let perUnit = usesMetric(locale)
            ? secondsPerKilometre
            : secondsPerKilometre * 1.609344
        let total = Int(perUnit.rounded())
        let unit = usesMetric(locale) ? "km" : "mi"
        return String(format: "%d:%02d /%@", total / 60, total % 60, unit)
    }

    public static func date(_ date: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

extension Activity {
    /// What the route line alone is. Used wherever the line is what is drawn,
    /// even when the activity also has a picture — announcing the picture over
    /// a route preview describes something that is not on screen.
    public var routeDescription: String {
        "\(mode.title), \(CardFormatter.distance(distanceMeters)). Route drawing."
    }

    /// What VoiceOver says about an activity's picture: `DESIGN.md` §9 — the
    /// subject and the reason it was chosen, never "image". "This is your
    /// route" is the claim, and a VoiceOver user judges it like anyone else.
    public var accessibilityDescription: String {
        guard let artwork = artworks.first(where: \.isSelected) ?? artworks.first else {
            return routeDescription
        }
        let base = "\(mode.title), \(CardFormatter.distance(distanceMeters))"
        return "\(base). \(artwork.subject). \(artwork.why)"
    }
}
