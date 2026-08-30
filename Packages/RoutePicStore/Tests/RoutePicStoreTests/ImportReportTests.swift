import Foundation
import Testing
@testable import RoutePicStore

/// This wording has been wrong twice. Both readings were plausible sentences;
/// what was wrong was what they counted.
@Suite("Import summary")
struct ImportReportTests {

    /// Nothing read is not the same as nothing there. Reporting an empty
    /// history over a pile of errors sends somebody to check a permission that
    /// was never the problem.
    @Test("Failures are not reported as an empty history")
    func failuresAreNotSilence() {
        let summary = ImportReport.summary(
            found: 0, imported: 0, skipped: 0, failures: ["the route was removed", "timed out"]
        )
        #expect(summary.contains("2"))
        #expect(summary.contains("the route was removed"))
        #expect(!summary.contains("Health settings"))
    }

    /// A history of treadmill runs has nothing to import and nothing wrong
    /// with it — but it looks identical to a refused permission from inside
    /// the app, so both are named.
    @Test("An empty history points at the permission it might be")
    func emptyHistoryNamesBothCauses() {
        let summary = ImportReport.summary(found: 0, imported: 0, skipped: 0, failures: [])
        #expect(summary.contains("Health settings"))
    }

    @Test("A partial import says what happened to the rest")
    func partialImportIsItemised() {
        let summary = ImportReport.summary(
            found: 10, imported: 7, skipped: 2, failures: ["one was unreadable"]
        )
        #expect(summary.contains("7 of 10"))
        #expect(summary.contains("2 were skipped"))
        #expect(summary.contains("one was unreadable"))
    }

    /// A 47 m walk to the shop was read perfectly well and refused on purpose.
    /// Counting it as unreadable sends somebody hunting a fault that is not
    /// there — 15 of 51 on the first real history came out this way.
    @Test("A deliberate refusal is not a failure")
    func refusalsAreNotFailures() {
        #expect(ActivityRepository.ImportFailure.tooShort(metres: 47).isDeliberate)
        #expect(ActivityRepository.ImportFailure.alreadyImported.isDeliberate)
        #expect(!ActivityRepository.ImportFailure.partiallyTimed.isDeliberate)
        #expect(!ActivityRepository.ImportFailure.malformedCoordinates.isDeliberate)
        #expect(!ActivityRepository.ImportFailure.noTimestamps.isDeliberate)

        let summary = ImportReport.summary(found: 51, imported: 36, skipped: 15, failures: [])
        #expect(summary.contains("36 of 51"))
        #expect(summary.contains("skipped"))
        #expect(!summary.contains("could not be read"))
    }

    @Test("A clean import says only that")
    func cleanImportIsPlain() {
        let summary = ImportReport.summary(found: 5, imported: 5, skipped: 0, failures: [])
        #expect(summary == "Imported 5 of 5.")
    }
}
