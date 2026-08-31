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

    public struct Palette: Sendable {
        public var background: (CGFloat, CGFloat, CGFloat)
        public var backgroundEnd: (CGFloat, CGFloat, CGFloat)
        public var line: (CGFloat, CGFloat, CGFloat)
        public var text: (CGFloat, CGFloat, CGFloat)

        public static let dusk = Palette(
            background: (0.09, 0.10, 0.16),
            backgroundEnd: (0.18, 0.14, 0.28),
            line: (0.98, 0.87, 0.55),
            text: (0.96, 0.96, 0.98)
        )
        public static let mint = Palette(
            background: (0.05, 0.16, 0.14),
            backgroundEnd: (0.08, 0.28, 0.22),
            line: (0.75, 0.98, 0.85),
            text: (0.95, 1.0, 0.97)
        )
    }

    public enum Failure: DescribedError {
        case contextCreationFailed
        public var description: String { "Could not create the card bitmap context." }
    }

    /// Below this a headline is decoration rather than words.
    static let minimumFontSize: CGFloat = 22

    /// The size a line has to drop to so it fits, or `nil` when it already does.
    ///
    /// `drawText` centres on `(width - lineWidth) / 2`, so a line wider than
    /// the card gets a negative origin and loses both ends. Floored, because a
    /// headline shrunk to nothing is worse than one that runs to the edges.
    static func fittedSize(
        _ fontSize: CGFloat, lineWidth: CGFloat, in width: CGFloat
    ) -> CGFloat? {
        let usable = width * 0.86
        guard lineWidth > usable, lineWidth > 0 else { return nil }
        return max(minimumFontSize, fontSize * (usable / lineWidth))
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

        let inset = size.width * 0.09
        let artRect = CGRect(
            x: inset, y: size.height - inset - (size.width - inset * 2),
            width: size.width - inset * 2, height: size.width - inset * 2
        )

        if let artwork {
            context.saveGState()
            context.addPath(CGPath(roundedRect: artRect, cornerWidth: 36, cornerHeight: 36, transform: nil))
            context.clip()
            context.draw(artwork, in: artRect)
            context.restoreGState()
        }

        // The route line is drawn when there is no artwork (it *is* the card),
        // or when the user explicitly asked to overlay it.
        if artwork == nil || contents.showsRouteLine {
            drawRoute(shape, in: context, rect: artRect, emphasised: artwork == nil)
        }

        drawStatistics(
            in: context, size: size, artRect: artRect,
            statistics: statistics, mode: mode, date: date,
            placeName: placeName, contents: contents, subject: subject,
            timeZone: timeZone
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
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        // Canvas space is top-down; CoreGraphics is bottom-up.
        context.translateBy(x: 0, y: shape.canvasSize)
        context.scaleBy(x: 1, y: -1)

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

    private func drawStatistics(
        in context: CGContext,
        size: CGSize,
        artRect: CGRect,
        statistics: ActivityStatistics,
        mode: RecordingMode,
        date: Date,
        placeName: String?,
        contents: Contents,
        subject: String?,
        timeZone: TimeZone
    ) {
        var lines: [(String, CGFloat)] = []

        // The headline. What the route looks like is the thing worth sharing;
        // the distance is what every other tracker already shows.
        if let subject { lines.append((subject, 58)) }

        if contents.showsDistance {
            lines.append((CardFormatter.distance(statistics.distanceMeters), 96))
        }

        var detail: [String] = []
        if contents.showsDuration {
            detail.append(CardFormatter.duration(statistics.movingDuration))
        }
        if let pace = statistics.paceSecondsPerKilometre, mode != .drive, contents.showsDistance {
            detail.append(CardFormatter.pace(pace))
        }
        if !detail.isEmpty { lines.append((detail.joined(separator: "   ·   "), 44)) }

        var footer: [String] = []
        if contents.showsDate { footer.append(CardFormatter.date(date, timeZone: timeZone)) }
        if contents.showsPlaceName, let placeName { footer.append(placeName) }
        if !footer.isEmpty { lines.append((footer.joined(separator: "   ·   "), 34)) }

        var y = artRect.minY - 90
        for (text, fontSize) in lines {
            drawText(text, in: context, centeredIn: size.width, at: y, fontSize: fontSize)
            y -= fontSize * 1.35
        }
    }

    private func drawText(
        _ text: String, in context: CGContext, centeredIn width: CGFloat,
        at y: CGFloat, fontSize: CGFloat
    ) {
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, fontSize, nil)
        let color = CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [palette.text.0, palette.text.1, palette.text.2, 1]
        )!
        // CoreText keys rather than `.font` / `.foregroundColor`, which are
        // declared by UIKit and AppKit — neither of which this package imports.
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
        )
        var line = CTLineCreateWithAttributedString(attributed)
        var bounds = CTLineGetBoundsWithOptions(line, [])

        if let fitted = Self.fittedSize(fontSize, lineWidth: bounds.width, in: width) {
            let shrunk = CTFontCreateCopyWithAttributes(font, fitted, nil, nil)
            let refitted = NSAttributedString(
                string: text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): shrunk,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ]
            )
            line = CTLineCreateWithAttributedString(refitted)
            bounds = CTLineGetBoundsWithOptions(line, [])
        }

        context.textPosition = CGPoint(x: (width - bounds.width) / 2, y: y)
        CTLineDraw(line, context)
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
