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
        meanAbsoluteTurn: Double = 0.4,
        turnVariance: Double = 0.2,
        turnSkewness: Double = 0,
        turnAgreement: Double = 0.5,
        radialDrift: Double = 0,
        turnReversals: Int = 0,
        totalTurning: Double = 0,
        circularity: Double? = nil,
        strokeCount: Int = 1,
        protrusionCount: Int = 0,
        selfIntersectionCount: Int = 0,
        convexRatio: Double? = 0.5
    ) -> ShapeFingerprint {
        ShapeFingerprint(
            closureRatio: closureRatio,
            aspectRatio: aspectRatio,
            tortuosity: tortuosity,
            meanAbsoluteTurn: meanAbsoluteTurn,
            turnVariance: turnVariance,
            turnSkewness: turnSkewness,
            occupancyFillRatio: 0.3,
            protrusionCount: protrusionCount,
            selfIntersectionCount: selfIntersectionCount,
            convexRatio: convexRatio,
            turnAgreement: turnAgreement,
            radialDrift: radialDrift,
            turnReversals: turnReversals,
            totalTurning: totalTurning,
            circularity: circularity,
            strokeCount: strokeCount
        )
    }

    /// A spiral whose turns are identical has zero variance, so the skewness
    /// the rule used to read is zero — the clearest case could never match.
    @Test("A perfectly even spiral is still read as one")
    func evenSpiralIsRecognised() {
        let spiral = fingerprint(
            closureRatio: 0.4, tortuosity: 4, turnSkewness: 0,
            turnAgreement: 1.0, radialDrift: -0.4, totalTurning: -12
        )
        #expect(FingerprintInterpreter.candidates(for: spiral).map(\.subject).contains("spiral shell"))
    }

    /// Area over hull area reaches 1 for any convex shape, so an egg scored as
    /// high as a circle and was told it was one.
    @Test("A convex egg is not called a circle")
    func convexEggIsNotAFullMoon() {
        let egg = fingerprint(closureRatio: 0.0, circularity: 0.6, convexRatio: 0.98)
        #expect(!FingerprintInterpreter.candidates(for: egg).map(\.subject).contains("full moon"))

        let disc = fingerprint(closureRatio: 0.0, circularity: 0.97, convexRatio: 0.98)
        #expect(FingerprintInterpreter.candidates(for: disc).map(\.subject).contains("full moon"))
    }

    /// Across a dropout the turns and radii of separate arcs are added, so two
    /// disconnected bends at different distances can spend a revolution
    /// between them while neither one winds anywhere.
    @Test("Two disconnected arcs are not one spiral")
    func brokenSpiralIsNotASpiral() {
        let broken = fingerprint(
            closureRatio: 0.4, tortuosity: 4, turnAgreement: 1.0,
            radialDrift: -0.4, totalTurning: -12, strokeCount: 2
        )
        #expect(!FingerprintInterpreter.candidates(for: broken).map(\.subject).contains("spiral shell"))
    }

    /// One turn agrees with itself perfectly, and unequal arms drift. Nothing
    /// about a hairpin has wound around anything.
    @Test("A hairpin is not a spiral")
    func hairpinIsNotASpiral() {
        let hairpin = fingerprint(
            closureRatio: 0.4, tortuosity: 2, turnAgreement: 1.0,
            radialDrift: -0.3, totalTurning: .pi
        )
        #expect(!FingerprintInterpreter.candidates(for: hairpin).map(\.subject).contains("spiral shell"))
    }

    /// A loop starts wherever the recording did. Either side of that seam the
    /// first and last thirds differ by however it fell, so the same drawing
    /// gained or lost a spiral with it.
    @Test("A closed loop is not read as a spiral")
    func closedLoopIsNotASpiral() {
        let loop = fingerprint(
            closureRatio: 0.0, tortuosity: 1000, turnAgreement: 1.0,
            radialDrift: -0.4, convexRatio: 0.9
        )
        #expect(!FingerprintInterpreter.candidates(for: loop).map(\.subject).contains("spiral shell"))
    }

    /// Walked from the inside out, a spiral's points reverse and its drift
    /// changes sign — the same drawing, rejected by half.
    @Test("A spiral is a spiral walked either way")
    func spiralIsDirectionNeutral() {
        for drift in [-0.4, 0.4] {
            let spiral = fingerprint(
                closureRatio: 0.4, tortuosity: 4, turnAgreement: 1.0,
                radialDrift: drift, totalTurning: drift < 0 ? -12 : 12
            )
            let readings = FingerprintInterpreter.candidates(for: spiral)
            #expect(readings.map(\.subject).contains("spiral shell"))
            let why = readings.first { $0.subject == "spiral shell" }?.why ?? ""
            #expect(why.contains(drift < 0 ? "closes in" : "opens out"), "\(why)")
        }
    }

    /// A 270° bend of constant radius agrees with itself perfectly and winds
    /// nowhere. Direction consistency alone would have called it a spiral and
    /// told the person it closed in as it went.
    @Test("An arc that never closes in is not a spiral")
    func constantRadiusArcIsNotASpiral() {
        let arc = fingerprint(
            closureRatio: 0.3, tortuosity: 3.3, turnAgreement: 1.0, radialDrift: 0
        )
        #expect(!FingerprintInterpreter.candidates(for: arc).map(\.subject).contains("spiral shell"))
    }

    /// Signed variance called a smooth same-way arc a saw and stopped calling a
    /// zigzag one as soon as its teeth got sharp: variance of ±θ is θ².
    @Test("A saw is turns that alternate, not turns that agree")
    func sawNeedsAlternatingTurns() {
        let zigzag = fingerprint(
            aspectRatio: 3, tortuosity: 2, meanAbsoluteTurn: 0.4,
            turnVariance: 0.16, turnAgreement: 0.5, turnReversals: 9
        )
        #expect(FingerprintInterpreter.candidates(for: zigzag).map(\.subject).contains("saw blade"))

        let arc = fingerprint(tortuosity: 2, meanAbsoluteTurn: 0.4, turnAgreement: 1.0)
        #expect(!FingerprintInterpreter.candidates(for: arc).map(\.subject).contains("saw blade"))

        // Left for half its length, right for the rest: balanced, and not one
        // reversal in the middle of either half.
        let ess = fingerprint(
            aspectRatio: 3, tortuosity: 2, meanAbsoluteTurn: 0.4,
            turnAgreement: 0.5, turnReversals: 1
        )
        #expect(!FingerprintInterpreter.candidates(for: ess).map(\.subject).contains("saw blade"))
    }

    /// Every axis the rules read, at values taken from the golden fixtures.
    private var everyShape: [ShapeFingerprint] {
        [
            fingerprint(closureRatio: 0.0, tortuosity: 1000, turnAgreement: 1.0, convexRatio: 1),
            fingerprint(closureRatio: 0.0, tortuosity: 6.1, protrusionCount: 2,
                        selfIntersectionCount: 1, convexRatio: nil),
            fingerprint(closureRatio: 0.25, aspectRatio: 2.9, tortuosity: 3.7,
                        meanAbsoluteTurn: 0.106, turnVariance: 0.014,
                        protrusionCount: 5, selfIntersectionCount: 13, convexRatio: nil),
            fingerprint(aspectRatio: 8, tortuosity: 4, turnSkewness: 0.1),
        ]
    }

    /// The reading is shown on the detail screen, the tile and the card, and the
    /// app is written in English. These sentences were Korean for as long as
    /// they only ever reached a generated picture nobody could make.
    @Test("Every reason is written in the language of the app")
    func reasonsAreEnglish() {
        for print in everyShape {
            for candidate in FingerprintInterpreter.candidates(for: print) {
                let hangul = candidate.why.unicodeScalars.contains {
                    (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value)
                }
                #expect(!hangul, "\(candidate.subject): \(candidate.why)")
            }
        }
    }

    /// A loop's straight-line distance is ~0, so tortuosity arrives as a
    /// sentinel near 1000 — and the reason said it out loud on a shared card.
    @Test("A loop is not described as a multiple of a distance it does not have")
    func sentinelTortuosityIsNotSpoken() {
        let loop = fingerprint(closureRatio: 0.0, tortuosity: 1000, turnAgreement: 1.0, convexRatio: 1)
        let readings = FingerprintInterpreter.candidates(for: loop)
        #expect(!readings.isEmpty)
        for candidate in readings {
            // No ratio at all, not a smaller wrong one: a loop's straight-line
            // distance is zero, so every multiple of it is an artefact.
            #expect(!candidate.why.contains("times the straight-line"), "\(candidate.why)")
            #expect(candidate.confidence <= 1)
        }
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
