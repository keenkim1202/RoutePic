import Foundation

extension String {
    /// Sentence case. Subjects are written as fragments — "curled sleeping cat"
    /// — because Stage 2 wanted them inside a prompt, and a headline is where
    /// they are read now.
    var headline: String { prefix(1).uppercased() + dropFirst() }
}
