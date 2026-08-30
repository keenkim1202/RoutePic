import Foundation

/// What to tell somebody after an import.
///
/// In the store rather than the screen so it can be tested. The wording has
/// been wrong twice — once counting workouts of a supported kind as workouts
/// with a route, once reporting failures as an empty history — and both read
/// as ordinary sentences until somebody checked what they were counting.
public enum ImportReport {

    /// - Parameters:
    ///   - found: tracks that actually had coordinates, not candidates.
    ///   - skipped: tracks refused on purpose — too short, or already held.
    ///   - failures: one message per track that genuinely could not be read.
    public static func summary(
        found: Int, imported: Int, skipped: Int, failures: [String]
    ) -> String {
        guard found > 0 else {
            // Nothing read is not the same as nothing there. Saying "none
            // found" over a pile of errors sends somebody to check a
            // permission that was never the problem.
            if let first = failures.first {
                return """
                    Nothing could be read. \(failures.count) \
                    \(failures.count == 1 ? "track" : "tracks") failed — \(first)
                    """
            }
            return """
                No workouts with a recorded route were found. If you expected \
                some, check that RoutePic is allowed to read Workouts and \
                Workout Routes in Health settings.
                """
        }

        var summary = "Imported \(imported) of \(found)."
        if skipped > 0 {
            summary += " \(skipped) were skipped — already here, or too short to draw."
        }
        if let first = failures.first {
            summary += " \(failures.count) could not be read — \(first)"
        }
        return summary
    }
}
