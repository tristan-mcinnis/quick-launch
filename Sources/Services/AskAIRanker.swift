import Foundation

/// Decides where the "Ask AI" row sits among launcher results.
///
/// The rule: a single word is a launcher query first (`weather` opens
/// Weather), so Ask AI stays last unless the user pinned it or uses it a lot.
/// Two or more words, a question mark, or a leading verb read as a prompt, so
/// Ask AI outranks every weak (subsequence-only) match but never an exact
/// name, an exact alias, a title prefix, or a learned abbreviation.
enum AskAIRanker {
    /// Just under the title-prefix bonus in `matchScore` (2 000).
    static let promptScore = 1_900
    /// Below every text match; pin (1 500) or use count (up to 1 200) lift it
    /// above subsequence-only matches, never above a prefix or exact match.
    static let wordScore = 0

    static let leadingWords: Set<String> = [
        "what", "how", "why", "who", "when", "where", "which", "whats", "hows",
        "write", "draft", "explain", "summarize", "summarise", "translate", "fix",
        "rewrite", "make", "tell", "define", "describe", "list", "give", "compare",
        "convert", "calculate", "suggest", "help", "can", "could", "should", "would",
        "is", "are", "does", "do", "did", "will", "please", "generate", "create",
        "improve", "shorten", "expand", "proofread", "check", "reply", "respond",
    ]

    static func looksLikePrompt(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count >= 2 { return true }
        if trimmed.count >= 25 { return true }
        let first = String(words[0]).lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return leadingWords.contains(first)
    }

    static func baseScore(for query: String) -> Int {
        looksLikePrompt(query) ? promptScore : wordScore
    }
}
