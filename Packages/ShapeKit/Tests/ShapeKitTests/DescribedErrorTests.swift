import Foundation
import Testing
@testable import ShapeKit

/// Fourteen error types wrote a careful sentence and showed "Failure error 2".
/// The fix was applied one type at a time as each was noticed, twice, so what
/// is checked here is the property rather than the instances.
@Suite("Errors say what happened")
struct DescribedErrorTests {

    @Test("A described error reads the same through localizedDescription")
    func localizedMatchesDescription() {
        let errors: [any DescribedError] = [
            PolylineCodec.DecodingError.truncated(field: "latitude"),
            ENUProjection.Failure.polarLatitude(88),
            ShapePipeline.Failure.notEnoughPoints,
        ]
        for error in errors {
            #expect(error.localizedDescription == error.description)
            #expect(!error.localizedDescription.contains("error "))
        }
    }

    /// The trap the protocol exists for: `CustomStringConvertible` alone does
    /// not feed `localizedDescription`, and a generic `catch` reaches for that.
    @Test("Conforming to CustomStringConvertible alone is not enough")
    func plainConvertibleDoesNotCarry() {
        enum Plain: Error, CustomStringConvertible {
            case broken
            var description: String { "A sentence somebody wrote." }
        }
        #expect(Plain.broken.localizedDescription != Plain.broken.description)
    }
}
