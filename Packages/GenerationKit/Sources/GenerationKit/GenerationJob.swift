import Foundation
import ShapeKit

/// A generation request and where it has got to.
///
/// `DESIGN.md` §8.3. The states are explicit because each terminal one has a
/// different consequence for the user's quota, and "it failed" without saying
/// which kind of failure is how people get charged for nothing.
public struct GenerationJob: Sendable, Equatable, Codable {

    public enum Status: String, Sendable, Codable {
        case queued
        case running
        case succeeded
        case failed
        case cancelled
        case expired

        public var isTerminal: Bool {
            self != .queued && self != .running
        }

        /// Every terminal state except success returns the reservation.
        /// The user should not pay for a picture they never received.
        public var refundsQuota: Bool {
            switch self {
            case .failed, .cancelled, .expired: true
            case .queued, .running, .succeeded: false
            }
        }
    }

    public var id: String
    /// Deduplicates retries. `DESIGN.md` §8.3 — without it a resend after a
    /// dropped response charges twice for one picture.
    public var idempotencyKey: String
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date
    public var candidates: [GeneratedCandidate]
    public var failureReason: String?

    public init(
        id: String,
        idempotencyKey: String,
        status: Status = .queued,
        createdAt: Date,
        updatedAt: Date,
        candidates: [GeneratedCandidate] = [],
        failureReason: String? = nil
    ) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.candidates = candidates
        self.failureReason = failureReason
    }

    /// `DESIGN.md` §8.3 — a job still running after this is abandoned and refunded.
    public static let expiry: TimeInterval = 600

    public func expired(at now: Date) -> Bool {
        !status.isTerminal && now.timeIntervalSince(createdAt) >= Self.expiry
    }
}

/// The VLM's reading of a shape, before any image exists.
public struct ShapeInterpretation: Sendable, Equatable, Codable {
    public var recognizable: Bool
    /// Index into `Orientation.all`.
    public var bestRenderIndex: Int
    public var candidates: [SubjectCandidate]
    public var fallbackAbstract: String

    public init(
        recognizable: Bool,
        bestRenderIndex: Int,
        candidates: [SubjectCandidate],
        fallbackAbstract: String
    ) {
        self.recognizable = recognizable
        self.bestRenderIndex = bestRenderIndex
        self.candidates = candidates
        self.fallbackAbstract = fallbackAbstract
    }
}

public struct SubjectCandidate: Sendable, Equatable, Codable {
    public var subject: String
    public var confidence: Double
    public var renderIndex: Int
    public var prompt: String
    /// Shown to the user verbatim (`DESIGN.md` §7.2).
    public var why: String

    public init(
        subject: String, confidence: Double, renderIndex: Int, prompt: String, why: String
    ) {
        self.subject = subject
        self.confidence = confidence
        self.renderIndex = renderIndex
        self.prompt = prompt
        self.why = why
    }
}

public struct GeneratedCandidate: Sendable, Equatable, Codable {
    public var imageURL: URL
    public var subject: String
    public var why: String
    public var seed: Int64
    public var controlStrength: Double
    public var renderIndex: Int
    public var costCents: Int

    public init(
        imageURL: URL, subject: String, why: String, seed: Int64,
        controlStrength: Double, renderIndex: Int, costCents: Int
    ) {
        self.imageURL = imageURL
        self.subject = subject
        self.why = why
        self.seed = seed
        self.controlStrength = controlStrength
        self.renderIndex = renderIndex
        self.costCents = costCents
    }
}

/// What the app sends. **Never coordinates** (`DESIGN.md` §11).
public struct GenerationRequest: Sendable, Equatable {
    /// Normalised control images, one per orientation. Position information is
    /// gone by construction: the shape was projected onto its own centroid and
    /// scaled to a fixed canvas.
    public var orientationImages: [Data]
    public var fingerprint: ShapeFingerprint
    public var stylePreset: String
    public var conditionMode: String
    public var controlStrength: Double
    public var idempotencyKey: String

    public init(
        orientationImages: [Data],
        fingerprint: ShapeFingerprint,
        stylePreset: String,
        conditionMode: String,
        controlStrength: Double,
        idempotencyKey: String = UUID().uuidString
    ) {
        self.orientationImages = orientationImages
        self.fingerprint = fingerprint
        self.stylePreset = stylePreset
        self.conditionMode = conditionMode
        self.controlStrength = controlStrength
        self.idempotencyKey = idempotencyKey
    }
}
