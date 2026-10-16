import Foundation

/// The measured facts a Review Changes card shows beside the original and the
/// proposed text: how much of each is drawn, and how many lines differ. Pure
/// and bounded, so a long selection or a CJK paragraph renders the same way
/// the short case does, in both appearances.
enum TransformReview {
    /// Characters drawn per side before the card says the rest is left out.
    static let shownCharacters = 4_000

    struct Bounded: Equatable, Sendable {
        let text: String
        let omittedCharacters: Int

        var isTruncated: Bool { omittedCharacters > 0 }
    }

    /// Trims a source to the shown limit on a Character boundary (never a
    /// byte), counting what is left out so the card can say so.
    static func bounded(_ text: String) -> Bounded {
        guard text.count > shownCharacters else {
            return Bounded(text: text, omittedCharacters: 0)
        }
        return Bounded(
            text: String(text.prefix(shownCharacters)),
            omittedCharacters: text.count - shownCharacters
        )
    }

    /// Lines whose text differs, compared positionally: a simple, honest count
    /// for the card's meta line. It never claims an edit script it did not
    /// compute.
    static func changedLineCount(original: String, proposed: String) -> Int {
        let a = original.split(separator: "\n", omittingEmptySubsequences: false)
        let b = proposed.split(separator: "\n", omittingEmptySubsequences: false)
        let shared = min(a.count, b.count)
        var changed = 0
        for index in 0..<shared where a[index] != b[index] { changed += 1 }
        changed += abs(a.count - b.count)
        return changed
    }

    /// The card's one-line summary: "changed 3 of 12 lines", or "no change"
    /// when the model returned the text unchanged.
    static func summary(original: String, proposed: String) -> String {
        guard original != proposed else { return "No change" }
        let lines = changedLineCount(original: original, proposed: proposed)
        let total = max(
            original.split(separator: "\n", omittingEmptySubsequences: false).count,
            proposed.split(separator: "\n", omittingEmptySubsequences: false).count
        )
        return "Changed \(lines) of \(total) lines"
    }
}
