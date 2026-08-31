import CoreGraphics
import Testing
@testable import RoutePicStore

@Suite("Card")
struct CardTests {

    /// The subject's length is not the app's to choose — a longer vocabulary or
    /// a translation makes one that does not fit, and centred it loses both
    /// ends on the one image that gets shared.
    @Test("A headline too wide for the card is shrunk, not cut off")
    func headlineIsFittedToTheCard() {
        let width: CGFloat = 1080

        #expect(CardRenderer.fittedSize(58, lineWidth: 400, in: width) == nil)
        #expect(CardRenderer.fittedSize(58, lineWidth: width * 0.86, in: width) == nil)

        let shrunk = try? #require(CardRenderer.fittedSize(58, lineWidth: 1600, in: width))
        #expect(shrunk != nil)
        if let shrunk { #expect(shrunk < 58) }

        // Floored rather than vanishing.
        let absurd = CardRenderer.fittedSize(58, lineWidth: 40_000, in: width)
        #expect(absurd == CardRenderer.minimumFontSize)

        // A zero-width line is not a line; nothing to fit.
        #expect(CardRenderer.fittedSize(58, lineWidth: 0, in: width) == nil)
    }
}
