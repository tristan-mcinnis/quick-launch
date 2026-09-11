import Foundation

enum WebSearchIntentDetector {
    /// Leading words that ask for a web search outright, longest first so
    /// "search web for" is matched before "search web". A chat title drops
    /// them (`QuickConversation.cleanTitle`).
    static let commandPrefixes = [
        "search the web for", "search the web", "search web for", "search web",
        "look up", "find online",
    ]

    static func shouldSearch(_ input: String) -> Bool {
        let query = input
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }

        let directPrefixes = commandPrefixes + [
            "latest ", "latest news", "news about",
            "when is the next", "when are the next", "who is the current",
        ]
        if directPrefixes.contains(where: query.hasPrefix) { return true }

        // A question about the user's own day, work, or plans ("what did I
        // work on today", "what's on my schedule") is for memory and the
        // vault, not the web. Only an explicit "search web" above sends it
        // there; the model picks the memory or vault tool itself.
        if isAboutTheUser(query) { return false }

        let liveTerms = [
            " today", " tonight", " right now", " live score", " latest score",
            " schedule", " weather", " forecast", " stock price", " exchange rate",
        ]
        if liveTerms.contains(where: query.contains) { return true }

        let volatileTerms = [
            "score", "standings", "schedule", "price", "weather", "forecast",
            "president", "prime minister", "ceo", "version", "exchange rate",
        ]
        return query.contains("current") && volatileTerms.contains(where: query.contains)
    }

    /// First-person words, matched as whole words.
    static let firstPersonWords: Set<String> = [
        "i", "i'm", "i've", "i'd", "i'll", "im", "ive", "me", "my", "mine", "myself",
        "we", "our", "ours", "us",
    ]

    static func isAboutTheUser(_ query: String) -> Bool {
        let words = query
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0 == "'") })
            .map(String.init)
        return words.contains(where: firstPersonWords.contains)
    }
}
