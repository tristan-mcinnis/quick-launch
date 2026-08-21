import Foundation

enum WebSearchIntentDetector {
    static func shouldSearch(_ input: String) -> Bool {
        let query = input
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }

        let directPrefixes = [
            "search the web", "search web", "look up", "find online",
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
