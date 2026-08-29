import Foundation
import GenerationKit
import RoutePicStore
import ShapeKit
import SwiftUI

/// Drives one generation from the detail screen.
///
/// Nothing here knows the transport is on-device: `GenerationClient` hides
/// which path ran, so swapping in the server one touches only `AppEnvironment`.
@Observable
@MainActor
final class GenerationCoordinator {

    enum Phase: Equatable {
        case idle
        case unavailable(String)
        case ready([SubjectCandidate])
        case running
        case finished([GeneratedCandidate])
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var subject: SubjectCandidate?

    private let client: GenerationClient
    private let interpreter: any ShapeInterpreter
    private let repository: ActivityRepository
    private var task: Task<Void, Never>?

    init(client: GenerationClient, interpreter: any ShapeInterpreter, repository: ActivityRepository) {
        self.client = client
        self.interpreter = interpreter
        self.repository = repository
    }

    /// Works out whether generation can run and what it would draw.
    func prepare(for activity: Activity) async {
        do {
            let prepared = try DerivedRoute.make(from: activity, purpose: .control).shape
            switch await client.availability(
                for: prepared.canonical.fingerprint, lengthMeters: prepared.lengthMeters
            ) {
            case .available:
                break
            case .routeUnsuitable(let reason), .notReady(let reason):
                phase = .unavailable(reason)
                return
            case .quotaExhausted:
                phase = .unavailable("You have used this month's pictures.")
                return
            case .offline:
                phase = .unavailable("Picture generation needs a connection.")
                return
            }

            let interpretation = try await interpreter.interpret(
                sheet: Data(), layout: "", fingerprint: prepared.canonical.fingerprint
            )
            guard interpretation.recognizable, !interpretation.candidates.isEmpty else {
                phase = .unavailable(
                    "This route does not suggest anything to draw, so the card stays as it is."
                )
                return
            }
            subject = interpretation.candidates.first
            phase = .ready(interpretation.candidates)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func select(_ candidate: SubjectCandidate) {
        subject = candidate
    }

    func generate(for activity: Activity) {
        guard let subject else { return }
        phase = .running
        task = Task {
            do {
                let request = try Self.request(for: activity, subject: subject)
                let candidates = try await client.generate(request)
                phase = candidates.isEmpty
                    ? .failed("Nothing came back.")
                    : .finished(candidates)
            } catch is CancellationError {
                phase = .idle
            } catch {
                // A failure here is not a dead end: the local card is always
                // there (`DESIGN.md` §4.4), so the message says what happened
                // rather than offering to retry forever.
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// Keeps the chosen picture against the activity.
    func save(_ candidate: GeneratedCandidate, to activity: Activity) throws {
        let data = try Data(contentsOf: candidate.imageURL)
        try repository.attachArtwork(
            to: activity,
            imageData: data,
            subject: candidate.subject,
            why: candidate.why,
            stylePreset: "flat-vector",
            provider: "on-device",
            modelID: "stable-diffusion-1-5+scribble",
            conditionMode: "scribble",
            controlStrength: candidate.controlStrength,
            renderIndex: candidate.renderIndex,
            seed: candidate.seed,
            costCents: candidate.costCents
        )
    }

    /// Builds the request. **No coordinates go in** (`DESIGN.md` §11) — the
    /// shape was projected onto its own centroid and scaled to a fixed canvas,
    /// so position is gone by construction.
    private static func request(
        for activity: Activity, subject: SubjectCandidate
    ) throws -> GenerationRequest {
        let prepared = try DerivedRoute.make(from: activity, purpose: .control).shape
        let renderer = ControlImageRenderer()
        let orientations = try prepared.allOrientations().map { try renderer.renderPNG($0) }
        let sheet = ContactSheetRenderer(style: .allOrientations)

        return GenerationRequest(
            contactSheet: try sheet.renderPNG(prepared),
            sheetLayout: sheet.layoutDescription(),
            orientationImages: orientations,
            fingerprint: prepared.canonical.fingerprint,
            stylePreset: "flat-vector",
            conditionMode: "scribble",
            // Clamped to the window the strength grid left standing; the
            // on-device generator reports back what it could actually apply.
            controlStrength: 1.4,
            idempotencyKey: "\(activity.id.uuidString)-\(subject.subject)"
        )
    }
}
