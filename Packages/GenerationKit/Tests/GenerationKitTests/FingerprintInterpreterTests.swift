import Foundation
import ShapeKit
import Testing
@testable import GenerationKit

@Suite("Fingerprint interpreter")
struct FingerprintInterpreterTests {

    private func fingerprint(
        closureRatio: Double = 0.5,
        aspectRatio: Double = 1,
        tortuosity: Double = 1.5,
        protrusionCount: Int = 0,
        selfIntersectionCount: Int = 0,
        convexRatio: Double? = 0.5
    ) -> ShapeFingerprint {
        ShapeFingerprint(
            closureRatio: closureRatio,
            aspectRatio: aspectRatio,
            tortuosity: tortuosity,
            meanAbsoluteTurn: 0.4,
            turnVariance: 0.2,
            turnSkewness: 0,
            occupancyFillRatio: 0.3,
            protrusionCount: protrusionCount,
            selfIntersectionCount: selfIntersectionCount,
            convexRatio: convexRatio
        )
    }

    @Test("A commute that is nearly a straight line gets no subject")
    func straightLineIsNotRecognizable() async throws {
        // `DESIGN.md` §4.4 — saying so beats dressing a straight line up as an
        // animal, which is the failure the whole fallback exists for.
        let result = try await FingerprintInterpreter().interpret(
            sheet: Data(), layout: "4x4", fingerprint: fingerprint(tortuosity: 1.05)
        )

        #expect(result.recognizable == false)
        #expect(result.candidates.isEmpty)
        #expect(!result.fallbackAbstract.isEmpty)
    }

    @Test("A closed round route is offered as something curled up")
    func closedRouteSuggestsCurledSubject() async throws {
        let result = try await FingerprintInterpreter().interpret(
            sheet: Data(), layout: "4x4",
            fingerprint: fingerprint(closureRatio: 0.02, convexRatio: 0.9)
        )

        #expect(result.recognizable)
        #expect(result.candidates.contains { $0.subject.contains("cat") })
    }

    @Test("A crossing route is offered as something knotted")
    func crossingRouteSuggestsKnot() async throws {
        let result = try await FingerprintInterpreter().interpret(
            sheet: Data(), layout: "4x4", fingerprint: fingerprint(selfIntersectionCount: 2)
        )

        #expect(result.candidates.contains { $0.subject == "pretzel" })
    }

    @Test("A long thin route is offered as something long and thin")
    func elongatedRouteSuggestsSnake() async throws {
        let result = try await FingerprintInterpreter().interpret(
            sheet: Data(), layout: "4x4", fingerprint: fingerprint(aspectRatio: 6)
        )

        #expect(result.candidates.contains { $0.subject == "snake" })
    }

    @Test("At most three subjects, strongest first")
    func candidatesAreRankedAndCapped() async throws {
        // Everything at once: closed, crossing, elongated, winding, protruding.
        let result = try await FingerprintInterpreter().interpret(
            sheet: Data(), layout: "4x4",
            fingerprint: fingerprint(
                closureRatio: 0.01, aspectRatio: 8, tortuosity: 2.4,
                protrusionCount: 5, selfIntersectionCount: 3, convexRatio: 0.95
            )
        )

        #expect(result.candidates.count == FingerprintInterpreter.candidateLimit)
        #expect(result.candidates == result.candidates.sorted { $0.confidence > $1.confidence })
        #expect(result.candidates.allSatisfy { $0.confidence <= 1 })
        // Every subject carries the sentence shown to the user (§7.2).
        #expect(result.candidates.allSatisfy { !$0.why.isEmpty })
    }
}

@Suite("Control strength window")
struct ControlStrengthTests {

    private func request(strength: Double) -> GenerationRequest {
        GenerationRequest(
            contactSheet: Data(), sheetLayout: "4x4", orientationImages: [Data()],
            fingerprint: ShapeFingerprint(
                closureRatio: 0.5, aspectRatio: 1, tortuosity: 1.5, meanAbsoluteTurn: 0.4,
                turnVariance: 0.2, turnSkewness: 0, occupancyFillRatio: 0.3,
                protrusionCount: 0, selfIntersectionCount: 0, convexRatio: 0.5
            ),
            stylePreset: "flat-vector", conditionMode: "scribble", controlStrength: strength
        )
    }

    @Test("Strength is held inside the window the grid left standing")
    func clampsToMeasuredWindow() {
        // The 42-cell grid: under 1.0 the route is decoration, over 1.8 the
        // subject dissolves. 2.6 scores best on `edgeToRoute` and is a mass with
        // holes in it, which is why the metric's optimum is not the target.
        #expect(request(strength: 0).controlStrength == 1.0)
        #expect(request(strength: 2.6).controlStrength == 1.8)
        #expect(request(strength: 3.4).controlStrength == 1.8)
        #expect(request(strength: 1.4).controlStrength == 1.4)
    }
}
