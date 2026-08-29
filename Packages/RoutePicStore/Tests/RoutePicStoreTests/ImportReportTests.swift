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
        #expect(summary.contains("2 were already"))
        #expect(summary.contains("one was unreadable"))
    }

    @Test("A clean import says only that")
    func cleanImportIsPlain() {
        let summary = ImportReport.summary(found: 5, imported: 5, skipped: 0, failures: [])
        #expect(summary == "Imported 5 of 5.")
    }
}
