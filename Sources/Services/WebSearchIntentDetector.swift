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
}
