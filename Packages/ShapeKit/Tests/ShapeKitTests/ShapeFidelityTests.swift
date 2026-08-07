import CoreGraphics
import Foundation
import Testing
@testable import ShapeKit

@Suite("ShapeFidelity")
struct ShapeFidelityTests {

    private func shape(_ route: Route = Fixtures.wanderingWalk()) throws -> OrientedShape {
        try ShapePipeline(configuration: .init(trimMeters: 0)).prepare(route).canonical
    }

    /// A solid-colour image of the given size.
    private func flat(_ level: Double, size: Int = 256) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    @Test("The control image scores near-perfectly against its own route")
    func selfComparison() throws {
        // The strongest available ground truth: an image that IS the route.
        // If this does not score well, nothing else the metric says is usable.
        let oriented = try shape()
        let image = try ControlImageRenderer().render(oriented)
        let score = try ShapeFidelity().score(generated: image, against: oriented)

        #expect(score.isMeaningful)
        #expect(score.routeToEdge < 0.02, "route not found in its own render (\(score.routeToEdge))")
        #expect(score.edgeToRoute < 0.02, "render contains much that is not the route")
    }

    @Test("A different route scores worse than the matching one")
    func mismatchScoresWorse() throws {
        // The metric has to *discriminate*; a number that is low for everything
        // would pass the test above and still be useless.
        let walk = try shape()
        let star = try shape(Fixtures.closedLoop())
        let renderer = ControlImageRenderer()
        let fidelity = ShapeFidelity()

        let matched = try fidelity.score(generated: renderer.render(walk), against: walk)
        let mismatched = try fidelity.score(generated: renderer.render(star), against: walk)

        #expect(mismatched.chamfer > matched.chamfer * 3)
    }

    @Test("Texture everywhere is penalised even when the route is drawn")
    func textureIsPenalised() throws {
        // This is the failure §7.8 actually observed: the route is traced, then
        // buried in confetti. routeToEdge stays low; edgeToRoute must catch it.
        let oriented = try shape()
        let size = 512
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // Stripes across the whole canvas.
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(3)
        for x in stride(from: 0, to: size, by: 16) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: size))
        }
        context.strokePath()

        // …plus the route itself, drawn correctly.
        context.saveGState()
        let scale = Double(size) / oriented.canvasSize
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: oriented.canvasSize)
        context.scaleBy(x: 1, y: -1)
        context.setLineWidth(11 / scale)
        context.addPath(ControlImageRenderer(style: .control).path(for: oriented))
        context.strokePath()
        context.restoreGState()

        let noisy = try ShapeFidelity().score(
            generated: context.makeImage()!, against: oriented
        )
        let clean = try ShapeFidelity().score(
            generated: try ControlImageRenderer().render(oriented), against: oriented
        )

        // The route is present in both, so this direction should stay comparable…
        #expect(noisy.routeToEdge < 0.05)
        // …and the penalty must land on the other one.
        #expect(noisy.edgeToRoute > clean.edgeToRoute * 3)
    }

    @Test("A blank image is reported as unmeasurable rather than perfect")
    func blankIsNotPerfect() throws {
        // A uniform image has no edges, so every distance degenerates. Returning
        // a confident score here would let an empty generation win the spike.
        let score = try ShapeFidelity().score(generated: flat(0.5), against: try shape())
        #expect(!score.isMeaningful)
    }

    @Test("Scores do not depend on the generated image's resolution")
    func resolutionIndependent() throws {
        // Generations come back at 512² while the pipeline canvas is 1024².
        let oriented = try shape()
        let small = try ControlImageRenderer().render(oriented)
        let fidelity = ShapeFidelity()

        let context = CGContext(
            data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(small, in: CGRect(x: 0, y: 0, width: 512, height: 512))

        let full = try fidelity.score(generated: small, against: oriented)
        let half = try fidelity.score(generated: context.makeImage()!, against: oriented)
        #expect(abs(full.chamfer - half.chamfer) < 0.01)
    }

    @Test("Degenerate routes are scored or refused, never crash", arguments: [
        Fixtures.twoPoints, Fixtures.straightLine, Fixtures.multipleGaps,
        Fixtures.duplicateCoordinates,
    ])
    func degenerateRoutes(route: Route) throws {
        let oriented = try shape(route)
        let score = try ShapeFidelity().score(
            generated: try ControlImageRenderer().render(oriented), against: oriented
        )
        #expect(score.chamfer >= 0)
    }
}
