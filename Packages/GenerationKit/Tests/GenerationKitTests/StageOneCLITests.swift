import Foundation
import RouteKit
import ShapeKit
import Testing
@testable import GenerationKit

/// `genlab` exists so the sweep's subject comes from Stage 1 rather than from
/// whoever ran it (SP-1 #7), and so it refuses exactly what the app refuses.
/// Judging an image the product would never offer proves nothing about it.
@Suite("Stage 1 refuses what the app refuses")
struct StageOneCLITests {

    @Test("A recognisable route yields a prompt")
    func recognisableRouteHasAPrompt() async throws {
        let looped = ShapeFingerprint(
            closureRatio: 0.02, aspectRatio: 1.1, tortuosity: 1.7,
            meanAbsoluteTurn: 0.4, turnVariance: 0.2, turnSkewness: 0,
            occupancyFillRatio: 0.14, protrusionCount: 4,
            selfIntersectionCount: 3, convexRatio: 0.6
        )
        let result = try await FingerprintInterpreter().interpret(
            sheet: Data(), layout: "", fingerprint: looped
        )
        let prompt = result.candidates.first?.prompt ?? ""
        #expect(result.recognizable)
        #expect(!prompt.isEmpty)
    }

    /// `GenerationCoordinator.prepare` stops at `recognizable == false` and
    /// never draws the fallback. An earlier version of this test asserted the
    /// fallback was printed, which would have fed the sweep a prompt the app
    /// does not use.
    @Test("A route the app would refuse yields no subject")
    func refusedRouteYieldsNoSubject() async throws {
        let straight = ShapeFingerprint(
            closureRatio: 0.9, aspectRatio: 900, tortuosity: 1.02,
            meanAbsoluteTurn: 0.001, turnVariance: 0, turnSkewness: 0,
            occupancyFillRatio: 0.01, protrusionCount: 0,
            selfIntersectionCount: 0, convexRatio: nil
        )
        #expect(straight.isDegenerate)
        let result = try await FingerprintInterpreter().interpret(
            sheet: Data(), layout: "", fingerprint: straight
        )
        let wouldDraw = result.recognizable && !result.candidates.isEmpty
        #expect(!wouldDraw)
    }

    /// The refusal a fingerprint cannot express: it carries no length, so a
    /// recognisable short loop looks fine to Stage 1 and is blocked by
    /// `GenerationClient.availability` before Stage 1 is ever consulted. The
    /// length that counts is what survives trimming — a 400 m route can fall
    /// under the bar once its ends go.
    @Test("The length threshold is not visible in a fingerprint")
    func lengthRefusalNeedsTheRoute() {
        #expect(RouteTrimmer.minimumShareableLength == 300)
        let mirror = Mirror(reflecting: ShapeFingerprint(
            closureRatio: 0.02, aspectRatio: 1.1, tortuosity: 1.7,
            meanAbsoluteTurn: 0.4, turnVariance: 0.2, turnSkewness: 0,
            occupancyFillRatio: 0.14, protrusionCount: 4,
            selfIntersectionCount: 3, convexRatio: 0.6
        ))
        #expect(!mirror.children.contains { $0.label?.lowercased().contains("length") == true })
    }
}
