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

        if fingerprint.selfIntersectionCount > 0 {
            propose(
                "pretzel", 0.5 + 0.1 * Double(fingerprint.selfIntersectionCount),
                "이 경로는 자기 자신을 \(fingerprint.selfIntersectionCount)번 가로지릅니다."
            )
            propose("knotted rope", 0.45, "교차가 있는 경로는 매듭처럼 읽힙니다.")
        }

        if fingerprint.isClosed {
            let roundness = fingerprint.convexRatio ?? 0
            propose(
                "curled sleeping cat", 0.4 + 0.4 * roundness,
                "출발점으로 돌아온 둥근 경로입니다."
            )
            if fingerprint.protrusionCount >= 4 {
                propose(
                    "starfish", 0.4 + 0.1 * Double(fingerprint.protrusionCount),
                    "돌출부가 \(fingerprint.protrusionCount)개인 폐합 경로입니다."
                )
            }
        }

        if elongation > 2.5 {
            propose(
                "snake", 0.3 + 0.1 * elongation,
                "한쪽으로 \(String(format: "%.1f", elongation))배 긴 경로입니다."
            )
        }

        if fingerprint.tortuosity > 1.6 {
            propose(
                "climbing vine", 0.3 + 0.2 * (fingerprint.tortuosity - 1.6),
                "직선 거리의 \(String(format: "%.1f", fingerprint.tortuosity))배를 걸은 굽은 경로입니다."
            )
        }

        if fingerprint.protrusionCount >= 2 && !fingerprint.isClosed {
            propose(
                "tree branch", 0.3 + 0.08 * Double(fingerprint.protrusionCount),
                "갈라져 나온 부분이 \(fingerprint.protrusionCount)개 있습니다."
            )
        }

        return Array(
            scored.sorted { $0.confidence > $1.confidence }.prefix(candidateLimit)
        )
    }

    /// What to draw when nothing is proposed. `DESIGN.md` §4.4 — the shape is
    /// still the subject, just not as a thing with a name.
    static func abstract(for fingerprint: ShapeFingerprint) -> String {
        fingerprint.isClosed
            ? "a closed ribbon of light on a dark ground"
            : "a single flowing brush stroke on a dark ground"
    }
}
