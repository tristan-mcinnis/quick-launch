import Foundation

enum WebSearchIntentDetector {
    /// Leading words that ask for a web search outright, longest first so
    /// "search web for" is matched before "search web". A chat title drops
    /// them (`QuickConversation.cleanTitle`).
    static let commandPrefixes = [
        "search the web for", "search the web", "search web for", "search web",
        "look up", "find online",
    ]

    /// Whether `input` asks for the live web. `plainQuestion` says the ask
    /// is the user's own typed question: no saved action, no attachment and
    /// no page link. Only then do the recency words below count, so a pasted
    /// text to rewrite or a question about a file is never searched for
    /// saying "latest". Either way the model keeps every tool and can still
    /// search itself; this only decides whether one search runs first.
    static func shouldSearch(_ input: String, plainQuestion: Bool = false) -> Bool {
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
        // work on today", "what's on my schedule") is for memory, not
        // the web. Only an explicit "search web" above sends it
        // there; the model picks the memory tool itself.
        if isAboutTheUser(query) { return false }

        if plainQuestion, isShortQuestion(query), asksForSomethingRecent(query) { return true }

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

    /// Words that ask for the newest state of something. English ones match
    /// as whole words; Chinese ones as text, since Chinese has no spaces.
    /// Left out on purpose: "yesterday" and "this week" (a meeting or a
    /// note, more often than not), and 现在, 目前, 刚刚, 最近, 新闻, which
    /// are common in ordinary prose.
    static let recencyPhrases = ["latest", "newest", "most recent", "who won"]
    static let recencyCJK = ["最新", "今天", "天气", "汇率", "股价", "比分"]
    /// Chinese first-person words: "我最新的笔记" is about the user.
    static let firstPersonCJK = ["我", "咱们"]
    /// A question, not a pasted text: one line, at most this long.
    static let maxQuestionLength = 120

    static func isShortQuestion(_ query: String) -> Bool {
        query.count <= maxQuestionLength && !query.contains(where: \.isNewline)
    }

    /// Words that make a line text to work on, not a question.
    static let instructionMarkers = [
        "翻译", "翻成", "润色", "改写", "总结",
        "translate", "rewrite", "rephrase", "summarize", "summarise", "proofread", "polish",
    ]
    /// How an English question opens. "the latest draft reads well" is not
    /// one; "what is the latest version" and "latest version of Swift?" are.
    static let questionLeads: Set<String> = [
        "what", "whats", "which", "who", "when", "where", "how", "is", "are",
        "was", "were", "does", "do", "did", "has", "have", "any",
    ]

    static func asksForSomethingRecent(_ query: String) -> Bool {
        // A colon payload ("翻译：…") or an instruction word is text to work on.
        if query.contains(":") || query.contains("\u{FF1A}") { return false }
        if instructionMarkers.contains(where: query.contains) { return false }
        if recencyCJK.contains(where: query.contains) {
            return !firstPersonCJK.contains(where: query.contains)
        }
        let words = query.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        let isQuestion = query.hasSuffix("?") || words.first.map(questionLeads.contains) == true
        guard isQuestion else { return false }
        let padded = " " + words.joined(separator: " ") + " "
        return recencyPhrases.contains { padded.contains(" \($0) ") }
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
