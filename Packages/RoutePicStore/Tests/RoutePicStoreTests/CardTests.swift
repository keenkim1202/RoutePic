import CoreGraphics
import CoreText
import Testing
@testable import RoutePicStore

@Suite("Card")
struct CardTests {

    private let ink = CGColor(
        colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 1, 1, 1]
    )!

    private func wrap(_ text: String, size: CGFloat = 31, maxWidth: CGFloat = 820, maxLines: Int = 3)
        -> CardRenderer.Wrapped
    {
        CardRenderer.wrap(
            text, size: size, minimumSize: 27, weight: "HelveticaNeue",
            color: ink, maxWidth: maxWidth, maxLines: maxLines
        )
    }

    /// The reason is the app's most distinctive sentence and could not go on the
    /// card at all while the renderer drew one `CTLine` per string.
    @Test("A sentence too long for one line is broken, not dropped")
    func reasonWrapsOverLines() {
        let short = wrap("It crosses itself 3 times.")
        #expect(short.lines.count == 1)

        let long = wrap("Nearly every turn goes the same way, winding inward without once doubling back on itself.")
        #expect(long.lines.count > 1)
        #expect(long.lines.count <= 3)
        #expect(long.height == long.lineHeight * CGFloat(long.lines.count))
    }

    /// Product text is never reworded to fit, so past the smallest size the
    /// block is cut to its line budget rather than spilling down the card.
    @Test("A sentence that cannot fit its budget is cut to it")
    func overlongReasonIsCutToBudget() {
        let wall = String(repeating: "winding inward and back again ", count: 40)
        #expect(wrap(wall, maxLines: 3).lines.count == 3)
        #expect(wrap(wall, maxLines: 1).lines.count == 1)
    }

    /// A width narrower than a glyph makes CoreText break after every character
    /// rather than refusing, so the guard against a zero-length break never
    /// fires — what has to hold is that it still ends, inside its budget.
    @Test("An impossible width terminates inside the line budget")
    func impossibleWidthTerminates() {
        let squeezed = wrap("anything at all", maxWidth: 1, maxLines: 3)
        #expect(squeezed.lines.count == 3)
    }
}

extension CardTests {
    /// A two-line subject pushed the sentence down at a fixed top until its
    /// last line sat on the distance. The metrics are anchored to the bottom,
    /// so the sentence is what has to give.
    @Test("The reason never runs into the metrics", arguments: [
        (CardRenderer.Aspect.square, 1080.0),
        (CardRenderer.Aspect.portrait, 1350.0),
        (CardRenderer.Aspect.story, 1920.0),
    ])
    func reasonStaysAboveTheMetrics(aspect: CardRenderer.Aspect, height: CGFloat) {
        let layout = aspect.layout
        for subjectLines in 1...2 {
            let subjectHeight = CGFloat(subjectLines) * layout.subjectSize * 1.2
            let box = CardRenderer.reasonBox(
                layout, subjectHeight: subjectHeight, canvasHeight: height
            )
            let bottom = box.top + CGFloat(box.lines) * layout.reasonSize * 1.2
            #expect(bottom <= layout.metricsTop * height)
            #expect(box.lines >= 1)
            #expect(box.lines <= layout.reasonLines)
        }
    }
}

extension CardTests {
    /// The art frame stopped being square when the card started leading with
    /// the reading, and a 1024² picture drawn straight into it comes out
    /// squashed on every format.
    @Test("A square picture keeps its proportions in an oblong frame")
    func artworkIsFittedNotStretched() {
        let frame = CGRect(x: 86, y: 410, width: 907, height: 594)
        let fitted = CardRenderer.fit(CGSize(width: 1024, height: 1024), in: frame)

        #expect(fitted.width == fitted.height)
        #expect(fitted.height == frame.height)
        #expect(fitted.midX == frame.midX)
        #expect(fitted.midY == frame.midY)
        #expect(frame.contains(fitted))

        // A wide picture is bounded by the frame's width instead.
        let wide = CardRenderer.fit(CGSize(width: 2000, height: 500), in: frame)
        #expect(wide.width == frame.width)
        #expect(frame.contains(wide))
    }
}
