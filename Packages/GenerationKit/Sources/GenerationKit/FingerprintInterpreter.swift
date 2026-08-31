import Foundation
import ShapeKit

/// Stage 1 without a model: subjects picked from the shape fingerprint alone.
///
/// §7.2 wanted a VLM, which needs either a provider whose retention policy
/// blocks M6 (§11) or an SDK that does not exist locally yet (§7.9). The
/// fingerprint is already on the device and free, so the VLM becomes an upgrade
/// rather than a prerequisite.
///
/// ponytail: hand-written rules over seven numbers. It cannot see the picture,
/// so it proposes what a shape of these proportions *could* be. Swap in
/// `FoundationModels` when that ships — the `ShapeInterpreter` seam is why that
/// costs nothing above here.
public struct FingerprintInterpreter: ShapeInterpreter {

    /// How many subjects the picker offers (`DESIGN.md` §7.3 — three chips).
    public static let candidateLimit = 3

    public init() {}

    /// The contact sheet is ignored: there is no model here to look at it. The
    /// parameter stays because the server interpreter needs it and both sit
    /// behind the same protocol.
    public func interpret(
        sheet: Data,
        layout: String,
        fingerprint: ShapeFingerprint
    ) async throws -> ShapeInterpretation {
        read(fingerprint)
    }

    /// The reading, from the geometry alone.
    ///
    /// `interpret` never looked at the sheet — this is the whole of it. Kept
    /// separate because the app's most distinctive answer, what a route looks
    /// like and why, was reachable only through the generation path that owns
    /// the sheet: no model, no pack and no network are needed to say it.
    public func read(_ fingerprint: ShapeFingerprint) -> ShapeInterpretation {
        let candidates = Self.candidates(for: fingerprint)

        return ShapeInterpretation(
            // A nearly straight line is not a subject, and `DESIGN.md` §4.4
            // would rather say so than dress a commute up as an animal.
            recognizable: !fingerprint.isDegenerate && !candidates.isEmpty,
            // Which of the sixteen orientations reads best needs something that
            // can see them. Until Stage 1 has that, the unrotated render is used
            // and SP-2 stays an open question rather than a silently wrong pick.
            bestRenderIndex: 0,
            candidates: candidates,
            fallbackAbstract: Self.abstract(for: fingerprint)
        )
    }

    // MARK: - Rules

    static func candidates(for fingerprint: ShapeFingerprint) -> [SubjectCandidate] {
        guard !fingerprint.isDegenerate else { return [] }

        var scored: [SubjectCandidate] = []

        func propose(_ subject: String, _ confidence: Double, _ why: String) {
            guard confidence > 0.2 else { return }
            scored.append(
                SubjectCandidate(
                    subject: subject,
                    confidence: min(1, confidence),
                    renderIndex: 0,
                    prompt: "a \(subject)",
                    why: why
                )
            )
        }

        let elongation = max(fingerprint.aspectRatio, 1 / max(fingerprint.aspectRatio, 0.001))
        // A loop's straight-line distance is ~0, so tortuosity comes back as a
        // sentinel near 1000. Unclamped it reaches the sentence as "you walked
        // 1000.0 times the straight-line distance", which is not a fact.
        let wander = min(fingerprint.tortuosity, Self.maximumSpokenTortuosity)
        let turnsOneWay = fingerprint.turnAgreement

        if fingerprint.selfIntersectionCount > 0 {
            let crossings = fingerprint.selfIntersectionCount
            propose(
                "pretzel", 0.5 + 0.1 * Double(crossings),
                "It crosses itself \(crossings == 1 ? "once" : "\(crossings) times")."
            )
            propose("knotted rope", 0.45, "A route that crosses itself reads as a knot.")
            if crossings == 1 && fingerprint.protrusionCount >= 2 {
                propose(
                    "butterfly", 0.5,
                    "One crossing in the middle with a lobe on either side."
                )
            }
        }

        if fingerprint.isClosed {
            let roundness = fingerprint.convexRatio ?? 0
            propose(
                "curled sleeping cat", 0.4 + 0.4 * roundness,
                "It comes back to where it started, and stays round doing it."
            )
            if fingerprint.protrusionCount >= 4 {
                propose(
                    "starfish", 0.4 + 0.1 * Double(fingerprint.protrusionCount),
                    "A closed route with \(fingerprint.protrusionCount) arms off it."
                )
            }
            // Circularity, not convexity: area over hull area reaches 1 for any
            // convex shape, so an egg scored as high as a circle and was told
            // it was one.
            if let round = fingerprint.circularity, round > 0.85,
               fingerprint.protrusionCount <= 1 {
                propose("full moon", 0.45 + 0.3 * round, "Closed, and almost a circle.")
            }
        }

        // Sign agreement, not skewness: skewness measures how lopsided the turn
        // sizes are and is zero for the clearest spiral of all, one whose turns
        // are identical. Agreement alone is not enough either — a 270° bend of
        // constant radius agrees with itself and winds nowhere.
        // The size of the drift, not its sign: walking the same spiral from the
        // inside out reverses the points and negates it, and the drawing on the
        // card is the same either way. The direction goes in the sentence,
        // where it is a fact about the walk rather than about the shape.
        // Open only: a loop's start is wherever the recording began, and the
        // first and last thirds either side of that seam differ by however the
        // seam fell. The same drawing would gain or lose a spiral with it.
        // And it has to have gone round: a hairpin turns once, agrees with
        // itself perfectly, and can drift if its arms are unequal. A full turn
        // of the compass is the least that counts as winding.
        // One stroke only. Across a dropout the turns and radii of separate
        // arcs are added together, so two disconnected bends at different
        // distances can spend a revolution between them while neither one
        // winds anywhere.
        if fingerprint.strokeCount == 1 && !fingerprint.isClosed
            && turnsOneWay > 0.9 && wander > 1.5
            && abs(fingerprint.radialDrift) > 0.15
            && abs(fingerprint.totalTurning) > 2 * .pi {
            propose(
                "spiral shell", 0.35 + 0.4 * (turnsOneWay - 0.9) / 0.1,
                fingerprint.radialDrift < 0
                    ? "Nearly every turn goes the same way, and it closes in as it goes."
                    : "Nearly every turn goes the same way, and it opens out as it goes."
            )
        }

        if elongation > 2.5 {
            propose(
                "snake", 0.3 + 0.1 * elongation,
                String(format: "It runs %.1f times longer one way than the other.", elongation)
            )
            if !fingerprint.isClosed && wander > 2.5 && turnsOneWay < 0.75 {
                propose(
                    "lightning bolt", 0.35,
                    "Long, and turning first one way then the other."
                )
            }
        }

        // Not for a closed route: its straight-line distance is ~0, so the
        // ratio is a division artefact and the sentence says it out loud.
        // Clamping the sentinel only swapped one false number for another.
        if !fingerprint.isClosed && fingerprint.tortuosity > 1.6 {
            // The real ratio, not the capped one: an open route's tortuosity
            // is below 20 by definition — `closureRatio` above 0.05 — so the
            // number is a measurement and the cap would misreport it.
            propose(
                "climbing vine", 0.3 + 0.2 * (wander - 1.6),
                String(
                    format: "You walked %.1f times the straight-line distance.",
                    fingerprint.tortuosity
                )
            )
        }

        // Flips of direction, not a share of neighbouring samples: the curve is
        // flattened at eight samples each, so one tooth is several same-signed
        // micro-turns and a per-sample ratio measures the sampling rate.
        //
        // ponytail: 0.08 and six flips are read off four fixtures, not measured
        // on real routes. Too low and every city walk is a saw.
        if fingerprint.meanAbsoluteTurn > 0.08 && fingerprint.turnReversals >= 6 {
            propose(
                // Only what was measured: nothing here says the teeth are the
                // same size, so the sentence does not either.
                "saw blade", 0.35,
                "Sharp turns, and each one goes back the other way."
            )
        }

        if fingerprint.protrusionCount >= 2 && !fingerprint.isClosed {
            propose(
                "tree branch", 0.3 + 0.08 * Double(fingerprint.protrusionCount),
                "There are \(fingerprint.protrusionCount) stretches that go out and come back."
            )
        }

        return Array(
            scored.sorted { $0.confidence > $1.confidence }.prefix(candidateLimit)
        )
    }

    /// What to say when the geometry proposed nothing.
    ///
    /// `DESIGN.md` §4.4 — a route that matches nothing is told so. Silence
    /// reads as the app having failed to think of anything, and a straight
    /// commute is the most common route there is.
    public static let unrecognised = (
        subject: "A route of its own",
        why: "This one did not settle into a shape RoutePic knows."
    )

    /// Past this the number is a division-by-almost-zero artefact rather than a
    /// measurement, and it is spoken aloud on the card.
    static let maximumSpokenTortuosity = 12.0

    /// What to draw when nothing is proposed. `DESIGN.md` §4.4 — the shape is
    /// still the subject, just not as a thing with a name.
    static func abstract(for fingerprint: ShapeFingerprint) -> String {
        fingerprint.isClosed
            ? "a closed ribbon of light on a dark ground"
            : "a single flowing brush stroke on a dark ground"
    }
}
