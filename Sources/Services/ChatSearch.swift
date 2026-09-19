import Foundation
import Observation

// Chat search (spec `docs/attachments-and-search-spec-20260911.md`, section
// 4): one engine for the Chats catalog, Recent Chats, and the AI Chat rail.
// Matches the title, attachment names, questions, and answers (never
// attachment text), folds case, accents, width, and compatibility forms,
// keeps a chat only when every term matches, ranks title hits first and
// recent chats above old ones, and cuts a one-line snippet around the hit.
// Find in Chat uses the same folding (`SearchText.ranges`).

// MARK: - Folding

/// The one text folding for chat search and Find in Chat.
enum SearchText {
    /// Case, accents, and full-width forms, as `range(of:options:)` takes them.
    static let foldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// The folded form of `text`: NFKC (full-width letters and digits,
    /// Kangxi radicals, ligatures), then case, accent, and width folding
    /// with no locale (so a Turkish system folds "I" like every other), and
    /// every run of white space as one space, trimmed.
    static func fold(_ text: String) -> String {
        String(decoding: foldedBytes(text), as: UTF8.self)
    }

    /// `fold(_:)` as UTF-8 bytes: what the index keeps and `firstOffset` searches.
    /// Control characters count as white space, so the index's part
    /// separator (`partSeparator`) never appears inside a part.
    static func foldedBytes(_ text: String) -> [UInt8] {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: foldOptions, locale: nil)
        return collapsedWhitespace(folded)
    }

    /// `text` with every run of white space (and control characters) as
    /// one space, trimmed. Case and accents are kept: what a snippet shows.
    static func collapsingWhitespace(_ text: String) -> String {
        guard text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return text }
        return text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Joins the parts of one indexed field. Never inside a part.
    static let partSeparator: UInt8 = 0x01

    private static func collapsedWhitespace(_ text: String) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for byte in text.utf8 {
            // ASCII white space and control characters. NFKC already turned
            // no-break and ideographic spaces into plain ones.
            if byte <= 0x20 || byte == 0x7F {
                if !output.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace {
                output.append(0x20)
                pendingSpace = false
            }
            output.append(byte)
        }
        return output
    }

    /// An answer's Markdown as a reader sees it, near enough for search
    /// and a snippet: links and images as their text, no emphasis, code,
    /// heading, or quote markers. So "revenue grew" finds "**revenue**
    /// grew", a link's target is not searched, and a snippet never shows
    /// `**`. (Find in Chat matches the fully rendered text instead.)
    static func plainMarkdown(_ markdown: String) -> String {
        guard markdown.contains(where: { markdownMarks.contains($0) }) else { return markdown }
        var text = markdown
        for (pattern, template) in markdownRewrites {
            text = pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template
            )
        }
        return text
    }

    private static let markdownMarks: Set<Character> = ["*", "_", "`", "~", "[", "#", ">"]

    private static let markdownRewrites: [(NSRegularExpression, String)] = [
        // ![alt](url) and [text](url "title"): the text.
        (try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#), "$1"),
        // Heading and quote markers at a line's start.
        (try! NSRegularExpression(pattern: #"(?m)^[ \t]{0,3}(?:#{1,6}[ \t]+|>[ \t]?)"#), ""),
        // Bold, strike-through, and code marks.
        (try! NSRegularExpression(pattern: #"\*\*|__|~~|`+"#), ""),
        // A single * or _ that opens or closes emphasis, never one inside a
        // word (snake_case) or standing alone (2 * 3).
        (try! NSRegularExpression(pattern: #"(?<![\w*])[*_](?=[^\s*_])|(?<=[^\s*_])[*_](?![\w*])"#), ""),
    ]

    /// A Chinese, Japanese, or Korean character: a whole query on its own
    /// even when it is one character long.
    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3040...0x30FF, 0x3130...0x318F,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                true
            default:
                false
            }
        }
    }

    /// Every place `needle` occurs in `text`, folded as the search folds
    /// (case, accents, width), found on the original text so the ranges fit
    /// what is drawn. UTF-16 ranges, in order, never overlapping.
    static func ranges(of needle: String, in text: String) -> [TextRange] {
        guard !needle.isEmpty, !text.isEmpty else { return [] }
        var found: [TextRange] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, options: foldOptions, range: searchStart..<text.endIndex) {
            found.append(TextRange(NSRange(range, in: text)))
            // An empty match cannot happen with a non-empty needle, but a
            // match must always move the search on.
            searchStart = range.upperBound > searchStart ? range.upperBound : text.index(after: searchStart)
        }
        return found
    }

    /// The offset of the first place `needle` occurs in `haystack`, from
    /// `start`. `memchr` runs to each place the needle's rarest byte sits
    /// (a "g" or a "q", not an "e"), then `memcmp` checks the whole needle
    /// there, so a term that misses scans the text instead of stopping at
    /// every common letter.
    static func firstOffset(of needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, start >= 0, haystack.count - start >= needle.count else { return nil }
        let anchor = rarestIndex(in: needle)
        return haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                guard let base = hay.baseAddress, let pinBase = pin.baseAddress else { return nil }
                var cursor = start + anchor
                let lastAnchor = hay.count - needle.count + anchor
                while cursor <= lastAnchor {
                    guard let found = memchr(base + cursor, Int32(needle[anchor]), lastAnchor - cursor + 1) else {
                        return nil
                    }
                    let position = base.distance(to: UnsafeRawPointer(found))
                    let candidate = position - anchor
                    if memcmp(base + candidate, pinBase, pin.count) == 0 { return candidate }
                    cursor = position + 1
                }
                return nil
            }
        }
    }

    /// The needle byte that turns up least in text: English letter
    /// frequency for ASCII, white space as the commonest.
    static func rarestIndex(in needle: [UInt8]) -> Int {
        var best = 0
        var bestCommonness = Int.max
        for (index, byte) in needle.enumerated() {
            let commonness = byteCommonness[Int(byte)]
            if commonness < bestCommonness {
                best = index
                bestCommonness = commonness
            }
        }
        return best
    }

    /// How often a byte turns up in folded text, higher is commoner.
    private static let byteCommonness: [Int] = {
        var table = [Int](repeating: 5, count: 256)
        let letters = Array("etaoinshrdlcumwfgypbvkjxqz".utf8)
        for (rank, letter) in letters.enumerated() { table[Int(letter)] = 90 - rank * 3 }
        for digit in UInt8(ascii: "0")...UInt8(ascii: "9") { table[Int(digit)] = 20 }
        for mark in ".,:;'\"-?!()".utf8 { table[Int(mark)] = 30 }
        table[0x20] = 100
        // UTF-8 continuation bytes fill non-Latin text; lead bytes less so.
        for byte in 0x80...0xBF { table[byte] = 60 }
        for byte in 0xC0...0xFF { table[byte] = 40 }
        return table
    }()
}

/// A UTF-16 range in a drawn string: what a text view's storage and an
/// `AttributedString` take.
struct TextRange: Hashable, Sendable {
    let location: Int
    let length: Int

    init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    init(_ range: NSRange) {
        self.init(location: range.location, length: range.length)
    }

    var nsRange: NSRange { NSRange(location: location, length: length) }
    var upperBound: Int { location + length }

    /// The part of this range inside a string `length` long, or nil.
    func clamped(toLength total: Int) -> TextRange? {
        guard location < total, length > 0 else { return nil }
        return TextRange(location: location, length: min(length, total - location))
    }
}

// MARK: - Query

/// A parsed search: the terms every matching chat must hold.
struct ChatSearchQuery: Equatable, Sendable {
    struct Term: Equatable, Sendable {
        /// The term as typed, compatibility forms mapped, white space as
        /// one space: what `range(of:options:)` looks for in shown text.
        let text: String
        /// The folded term, as the index holds its text.
        let folded: [UInt8]
        let foldedText: String
    }

    let terms: [Term]

    var isEmpty: Bool { terms.isEmpty }

    /// Splits on white space; `"double quotes"` (or curly ones) make one
    /// phrase term. A term shorter than two characters is dropped, unless
    /// it is the whole query and a CJK character: one Chinese character is
    /// a search, one Latin letter is not.
    init(_ raw: String) {
        let tokens = Self.tokens(in: raw.precomposedStringWithCompatibilityMapping)
        var seen = Set<[UInt8]>()
        var terms: [Term] = []
        for token in tokens {
            let text = SearchText.collapsingWhitespace(token)
            let folded = SearchText.foldedBytes(text)
            guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
            terms.append(Term(text: text, folded: folded, foldedText: String(decoding: folded, as: UTF8.self)))
        }
        self.terms = terms.filter { term in
            if term.foldedText.count >= 2 { return true }
            return terms.count == 1 && term.foldedText.first.map(SearchText.isCJK) == true
        }
    }

    private static let quotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]

    private static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if quotes.contains(character) {
                if !current.isEmpty { tokens.append(current) }
                current = ""
                inQuotes.toggle()
            } else if !inQuotes, character.isWhitespace || character.isNewline {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

// MARK: - Fields and weights

/// Where a term matched, best first.
enum ChatSearchField: Int, Sendable, Comparable {
    case title
    case attachment
    case question
    case answer

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The ranking of spec 4.5, in one place.
enum ChatSearchWeight {
    static let titleWordPrefix = 120.0
    static let title = 100.0
    static let attachment = 60.0
    /// A title that holds the term's letters in order ("qrtly" in
    /// "Quarterly plan"), when the term is found nowhere as written.
    static let fuzzyTitle = 50.0
    static let question = 40.0
    static let answer = 20.0
    /// Recency: this much for a chat updated now, decaying over two weeks.
    static let recency = 30.0
    static let recencyDecayDays = 14.0
    /// Pinned chats get a small boost while searching, never the top.
    static let pinned = 10.0
    /// Fuzzy title matching needs a term at least this long.
    static let fuzzyMinimumLength = 3
    /// And a `FuzzyMatcher` score of this much per character: letters that
    /// start words or run together ("qrtly" in "Quarterly"), not letters
    /// strewn across a long title.
    static let fuzzyMinimumScorePerCharacter = 4
}

// MARK: - Sources and documents

/// What the index reads from one chat. Built on the main actor from a
/// `QuickConversation`; folded anywhere.
struct ChatSearchSource: Sendable, Equatable {
    struct Attachment: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case file
            case link
        }
        let kind: Kind
        /// A file's name, or a link's title and host.
        let name: String
    }

    let id: UUID
    let stamp: ChatSearchStamp
    let title: String
    let attachments: [Attachment]
    /// Every user question, as typed.
    let questions: [String]
    /// Every answer.
    let answers: [String]

    init(
        id: UUID,
        stamp: ChatSearchStamp,
        title: String,
        attachments: [Attachment] = [],
        questions: [String],
        answers: [String]
    ) {
        self.id = id
        self.stamp = stamp
        self.title = title
        self.attachments = attachments
        self.questions = questions
        self.answers = answers
    }

    /// One saved chat. Attachment names come from `attachments`; callers
    /// pass `ChatSearchSource.attachments(in:)`, the names on the chat's
    /// message references.
    init(
        _ conversation: QuickConversation,
        title: String,
        attachments: [Attachment] = []
    ) {
        self.init(
            id: conversation.id,
            stamp: ChatSearchStamp(conversation),
            title: title,
            attachments: attachments,
            questions: conversation.messages.filter { $0.role == .user }.map(\.content),
            answers: conversation.messages.filter { $0.role == .assistant }.map { SearchText.plainMarkdown($0.content) }
        )
    }
}

/// What says a chat's folded text is still current: a new turn, a retry,
/// or a rename changes it. A pin does not; the ranking reads the pin live.
/// It holds what the title is made from, not the title, so checking it
/// never cleans a title; the index's `titleContext` covers the rest.
struct ChatSearchStamp: Hashable, Sendable {
    let updatedAt: Date
    let customTitle: String?
    let titleSource: String?
    let messageCount: Int
    let lastMessageID: UUID?
    let lastMessageLength: Int

    init(_ conversation: QuickConversation) {
        updatedAt = conversation.updatedAt
        customTitle = conversation.customTitle
        titleSource = conversation.titleSource
        messageCount = conversation.messages.count
        lastMessageID = conversation.messages.last?.id
        lastMessageLength = conversation.messages.last?.content.utf8.count ?? 0
    }
}

/// One chat's folded text, per field, as UTF-8 bytes for `SearchText.firstOffset`.
struct ChatSearchDocument: Sendable {
    /// The parts of one field (the questions, say) joined by
    /// `SearchText.partSeparator`, with where each part starts.
    struct Field: Sendable {
        let bytes: [UInt8]
        let starts: [Int]

        static let empty = Field(bytes: [], starts: [])

        init(bytes: [UInt8], starts: [Int]) {
            self.bytes = bytes
            self.starts = starts
        }

        init(parts: [String]) {
            var bytes: [UInt8] = []
            var starts: [Int] = []
            for (index, part) in parts.enumerated() {
                if index > 0 { bytes.append(SearchText.partSeparator) }
                starts.append(bytes.count)
                bytes.append(contentsOf: SearchText.foldedBytes(part))
            }
            self.init(bytes: bytes, starts: starts)
        }

        func contains(_ term: [UInt8]) -> Bool {
            SearchText.firstOffset(of: term, in: bytes) != nil
        }

        /// The part that holds the first occurrence of `term`.
        func firstPart(holding term: [UInt8]) -> Int? {
            guard let offset = SearchText.firstOffset(of: term, in: bytes) else { return nil }
            var low = 0
            var high = starts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= offset { low = middle } else { high = middle - 1 }
            }
            return starts.isEmpty ? nil : low
        }

        var byteCount: Int { bytes.count }
    }

    let id: UUID
    let stamp: ChatSearchStamp
    let title: [UInt8]
    let titleText: String
    let attachments: Field
    let questions: Field
    let answers: Field
    /// Only the title is folded yet (the first build is still running).
    let isTitleOnly: Bool

    init(_ source: ChatSearchSource) {
        id = source.id
        stamp = source.stamp
        title = SearchText.foldedBytes(source.title)
        titleText = String(decoding: title, as: UTF8.self)
        attachments = Field(parts: source.attachments.map(\.name))
        questions = Field(parts: source.questions)
        answers = Field(parts: source.answers)
        isTitleOnly = false
    }

    /// The stand-in while the first build runs: the title alone.
    init(titleOnly source: ChatSearchSource) {
        id = source.id
        stamp = source.stamp
        title = SearchText.foldedBytes(source.title)
        titleText = String(decoding: title, as: UTF8.self)
        attachments = .empty
        questions = .empty
        answers = .empty
        isTitleOnly = true
    }

    /// Bytes held, for the build budget.
    var byteCount: Int { title.count + attachments.byteCount + questions.byteCount + answers.byteCount }

    /// The best field that holds `term`, with its weight, or nil.
    func bestHit(for term: ChatSearchQuery.Term, fuzzyTitle: Bool) -> (field: ChatSearchField, weight: Double)? {
        if let weight = titleWeight(for: term.folded) { return (.title, weight) }
        if attachments.contains(term.folded) { return (.attachment, ChatSearchWeight.attachment) }
        if questions.contains(term.folded) { return (.question, ChatSearchWeight.question) }
        if answers.contains(term.folded) { return (.answer, ChatSearchWeight.answer) }
        if fuzzyTitle, term.foldedText.count >= ChatSearchWeight.fuzzyMinimumLength,
           let score = fuzzyTitleScore(term.folded),
           score >= term.folded.count * ChatSearchWeight.fuzzyMinimumScorePerCharacter {
            return (.title, ChatSearchWeight.fuzzyTitle)
        }
        return nil
    }

    /// `FuzzyMatcher`'s score (the term's letters in the title in order:
    /// 10 each, 8 more at a word's start, 5 more when they run together,
    /// less the further in they sit) over the folded bytes, so a query
    /// that matches no chat as written stays fast. Nil when the letters
    /// are not all there in order.
    private func fuzzyTitleScore(_ term: [UInt8]) -> Int? {
        var next = 0
        var score = 0
        var previous: Int?
        for (index, byte) in title.enumerated() where next < term.count && byte == term[next] {
            score += 10
            if index == 0 || Self.isWordBreak(title[index - 1]) { score += 8 }
            if let previous, index == previous + 1 { score += 5 }
            score -= min(index, 12)
            previous = index
            next += 1
        }
        return next == term.count ? score : nil
    }

    /// 120 when the term starts a word of the title, 100 inside one.
    private func titleWeight(for term: [UInt8]) -> Double? {
        var start = 0
        var found = false
        while let offset = SearchText.firstOffset(of: term, in: title, from: start) {
            found = true
            if offset == 0 || Self.isWordBreak(title[offset - 1]) { return ChatSearchWeight.titleWordPrefix }
            start = offset + 1
        }
        return found ? ChatSearchWeight.title : nil
    }

    /// An ASCII space or punctuation byte: what ends a Latin word.
    private static func isWordBreak(_ byte: UInt8) -> Bool {
        guard byte < 0x80 else { return false }
        let scalar = Unicode.Scalar(byte)
        return !(CharacterSet.alphanumerics.contains(scalar))
    }
}

// MARK: - Ranking

/// One chat that matched every term.
struct ChatSearchHit: Sendable, Equatable {
    let id: UUID
    let score: Double
    /// Where the first term matched best: the snippet's source.
    let firstTermField: ChatSearchField
}

enum ChatSearch {
    /// Scores one chat: the best field weight of every term, plus recency
    /// (30 for now, decaying over two weeks) and 10 when pinned. Nil unless
    /// every term matched somewhere.
    static func score(
        _ document: ChatSearchDocument,
        query: ChatSearchQuery,
        isPinned: Bool,
        updatedAt: Date,
        now: Date,
        fuzzyTitle: Bool = true
    ) -> ChatSearchHit? {
        guard !query.isEmpty else { return nil }
        var total = 0.0
        var firstField = ChatSearchField.title
        for (index, term) in query.terms.enumerated() {
            guard let hit = document.bestHit(for: term, fuzzyTitle: fuzzyTitle) else { return nil }
            total += hit.weight
            if index == 0 { firstField = hit.field }
        }
        let ageDays = max(0, now.timeIntervalSince(updatedAt)) / 86_400
        total += ChatSearchWeight.recency * exp(-ageDays / ChatSearchWeight.recencyDecayDays)
        if isPinned { total += ChatSearchWeight.pinned }
        return ChatSearchHit(id: document.id, score: total, firstTermField: firstField)
    }

    /// The chats that match, best first; ties go to the newest.
    static func rank(
        _ conversations: [QuickConversation],
        query: ChatSearchQuery,
        document: (QuickConversation) -> ChatSearchDocument,
        now: Date,
        fuzzyTitle: Bool = true
    ) -> [(conversation: QuickConversation, hit: ChatSearchHit)] {
        conversations
            .compactMap { conversation -> (QuickConversation, ChatSearchHit)? in
                guard let hit = score(
                    document(conversation),
                    query: query,
                    isPinned: conversation.isPinned,
                    updatedAt: conversation.updatedAt,
                    now: now,
                    fuzzyTitle: fuzzyTitle
                ) else { return nil }
                return (conversation, hit)
            }
            .sorted { lhs, rhs in
                if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
                if lhs.0.updatedAt != rhs.0.updatedAt { return lhs.0.updatedAt > rhs.0.updatedAt }
                return lhs.0.id.uuidString < rhs.0.id.uuidString
            }
            .map { (conversation: $0.0, hit: $0.1) }
    }

    /// The snippet for a row: where the first term was found best, when
    /// that is not the title. Nil for a title hit (the title already shows
    /// it) and for a document that has only its title folded.
    static func snippet(
        document: ChatSearchDocument,
        source: ChatSearchSource,
        query: ChatSearchQuery,
        context: Int = ChatSnippet.context
    ) -> ChatSnippet? {
        guard let first = query.terms.first,
              let hit = document.bestHit(for: first, fuzzyTitle: false),
              hit.field != .title
        else { return nil }
        let label: String
        let text: String
        switch hit.field {
        case .title:
            return nil
        case .attachment:
            guard let part = document.attachments.firstPart(holding: first.folded),
                  source.attachments.indices.contains(part) else { return nil }
            label = ChatSnippet.label(for: .attachment, attachment: source.attachments[part].kind)
            text = source.attachments[part].name
        case .question:
            guard let part = document.questions.firstPart(holding: first.folded),
                  source.questions.indices.contains(part) else { return nil }
            label = ChatSnippet.label(for: .question)
            text = source.questions[part]
        case .answer:
            guard let part = document.answers.firstPart(holding: first.folded),
                  source.answers.indices.contains(part) else { return nil }
            label = ChatSnippet.label(for: .answer)
            text = source.answers[part]
        }
        return ChatSnippet.make(label: label, text: text, query: query, context: context)
    }
}

// MARK: - Snippet

/// One line of a chat row: where the first term was found, with every term
/// in it marked. "You: …does the quarterly revenue include the rebate…"
struct ChatSnippet: Equatable, Sendable {
    struct Run: Equatable, Sendable {
        let text: String
        let isMatch: Bool
    }

    /// "You:", "Answer:", "Attachment:", or "Link:".
    let label: String
    let runs: [Run]

    var text: String { runs.map(\.text).joined() }

    /// What VoiceOver and a tooltip read.
    var plainText: String { "\(label) \(text)" }

    /// Characters kept on each side of the hit.
    static let context = 40
    /// How far a cut looks for a word boundary before it cuts a word.
    static let boundarySearch = 16
    static let ellipsis = "\u{2026}"

    static func label(for field: ChatSearchField, attachment: ChatSearchSource.Attachment.Kind? = nil) -> String {
        switch field {
        case .title: ""
        case .attachment: attachment == .link ? "Link:" : "Attachment:"
        case .question: "You:"
        case .answer: "Answer:"
        }
    }

    /// A snippet of `text` around the first place the first term occurs,
    /// with every term marked. Ranges are found on the shown text with
    /// `range(of:options:)`, not on the folded copy, whose lengths differ
    /// ("ß" folds to "ss"). Nil when the first term is not in `text`.
    static func make(
        label: String,
        text original: String,
        query: ChatSearchQuery,
        context: Int = ChatSnippet.context
    ) -> ChatSnippet? {
        guard let first = query.terms.first else { return nil }
        var display = SearchText.collapsingWhitespace(original)
        var anchor = display.range(of: first.text, options: SearchText.foldOptions)
        if anchor == nil {
            // A compatibility form the options do not cover (a Kangxi
            // radical): show the mapped text.
            display = SearchText.collapsingWhitespace(original.precomposedStringWithCompatibilityMapping)
            anchor = display.range(of: first.text, options: SearchText.foldOptions)
        }
        guard let anchor else { return nil }
        let start = cutStart(in: display, before: anchor.lowerBound, context: context)
        let end = cutEnd(in: display, after: anchor.upperBound, context: context)
        let window = String(display[start..<end]).trimmingCharacters(in: .whitespaces)
        var runs: [Run] = []
        if start > display.startIndex { runs.append(Run(text: ellipsis, isMatch: false)) }
        runs.append(contentsOf: markedRuns(window, query: query))
        if end < display.endIndex { runs.append(Run(text: ellipsis, isMatch: false)) }
        return ChatSnippet(label: label, runs: merged(runs))
    }

    /// The same snippet with at most `characters` before the first match,
    /// for a narrow row (the AI Chat rail).
    func keepingLead(_ characters: Int) -> ChatSnippet {
        guard let firstMatch = runs.firstIndex(where: \.isMatch) else { return self }
        let lead = runs[..<firstMatch].map(\.text).joined()
        guard lead.count > characters else { return self }
        let cutAt = lead.index(lead.endIndex, offsetBy: -characters)
        var kept = String(lead[cutAt...])
        // Start at a word, when one starts close by.
        if let space = kept.prefix(Self.boundarySearch).firstIndex(where: \.isWhitespace),
           lead[lead.index(before: cutAt)].isWhitespace == false {
            kept = String(kept[kept.index(after: space)...])
        }
        let head = Run(text: Self.ellipsis + kept, isMatch: false)
        return ChatSnippet(label: label, runs: Self.merged([head] + runs[firstMatch...]))
    }

    private static func cutStart(in text: String, before hit: String.Index, context: Int) -> String.Index {
        guard let start = text.index(hit, offsetBy: -context, limitedBy: text.startIndex),
              start > text.startIndex
        else { return text.startIndex }
        // Mid-word: move on to the next word when one starts close by;
        // CJK text has no spaces and is cut at a character.
        guard !text[text.index(before: start)].isWhitespace, !text[start].isWhitespace else {
            return text[start].isWhitespace ? text.index(after: start) : start
        }
        var cursor = start
        var steps = 0
        while cursor < hit, steps < boundarySearch {
            if text[cursor].isWhitespace { return text.index(after: cursor) }
            cursor = text.index(after: cursor)
            steps += 1
        }
        return start
    }

    private static func cutEnd(in text: String, after hit: String.Index, context: Int) -> String.Index {
        guard let end = text.index(hit, offsetBy: context, limitedBy: text.endIndex),
              end < text.endIndex
        else { return text.endIndex }
        guard !text[end].isWhitespace, !text[text.index(before: end)].isWhitespace else {
            return end
        }
        var cursor = end
        var steps = 0
        while cursor > hit, steps < boundarySearch {
            let previous = text.index(before: cursor)
            if text[previous].isWhitespace { return previous }
            cursor = previous
            steps += 1
        }
        return end
    }

    /// `window` split into runs, every term's occurrences marked.
    private static func markedRuns(_ window: String, query: ChatSearchQuery) -> [Run] {
        var marks: [Range<String.Index>] = []
        for term in query.terms {
            var from = window.startIndex
            while from < window.endIndex,
                  let range = window.range(of: term.text, options: SearchText.foldOptions, range: from..<window.endIndex) {
                marks.append(range)
                from = range.upperBound
            }
        }
        marks.sort { $0.lowerBound < $1.lowerBound }
        var runs: [Run] = []
        var cursor = window.startIndex
        for mark in marks where mark.lowerBound >= cursor {
            if cursor < mark.lowerBound { runs.append(Run(text: String(window[cursor..<mark.lowerBound]), isMatch: false)) }
            runs.append(Run(text: String(window[mark]), isMatch: true))
            cursor = mark.upperBound
        }
        if cursor < window.endIndex { runs.append(Run(text: String(window[cursor...]), isMatch: false)) }
        return runs
    }

    private static func merged(_ runs: [Run]) -> [Run] {
        var output: [Run] = []
        for run in runs where !run.text.isEmpty {
            if let last = output.last, last.isMatch == run.isMatch {
                output[output.count - 1] = Run(text: last.text + run.text, isMatch: run.isMatch)
            } else {
                output.append(run)
            }
        }
        return output
    }
}

// MARK: - Index

/// The folded text of every chat, kept by the view model and rebuilt only
/// for chats whose stamp moved (a new turn rebuilds one chat). A large
/// first build runs off the main actor; until it lands, the chats it has
/// not folded yet match on their titles only, and `revision` moves when it
/// lands so the lists read again.
@Observable @MainActor final class ChatSearchIndex {
    /// Moves when a background build lands. The lists read it, so they
    /// draw again with message text searched.
    private(set) var revision = 0

    @ObservationIgnored private var documents: [UUID: ChatSearchDocument] = [:]
    /// Stamps of the chats the build in flight is folding.
    @ObservationIgnored private var building: [UUID: ChatSearchStamp] = [:]
    /// Stale sources that arrived while a build was in flight. They are folded
    /// by the next background build, never inline on the main actor.
    @ObservationIgnored private var parkedStale: [ChatSearchSource] = []
    @ObservationIgnored private(set) var buildTask: Task<Void, Never>?
    /// Stale text above this many UTF-8 bytes folds off the main actor.
    @ObservationIgnored let backgroundThreshold: Int?
    /// The rows the lists last read, newest last, and what they were read
    /// for. A few, so two lists on one view model (Recent Chats' search and
    /// the unfiltered chat rows) never push each other out.
    @ObservationIgnored private var rowCache: [(key: RowKey, rows: [LauncherCatalogItem])] = []
    private static let rowCacheLimit = 4

    /// A list's rows are current while the query, the history, the titles'
    /// saved-prompt context, and the index revision are the same. Comparing
    /// the history is cheap: an unchanged array shares its buffer.
    struct RowKey: Equatable {
        let query: String
        let history: [QuickConversation]
        let titleContext: String
        let revision: Int
    }

    /// `backgroundThreshold` nil folds everything at once, on the caller's
    /// actor (a one-off search, and tests).
    init(backgroundThreshold: Int? = 256 * 1024) {
        self.backgroundThreshold = backgroundThreshold
    }

    isolated deinit {
        buildTask?.cancel()
    }

    /// Chats folded and current.
    var documentCount: Int { documents.count }
    var isBuilding: Bool { buildTask != nil }

    /// What titles depend on besides the chat (the saved-prompt prefix and
    /// aliases). A change folds every title again.
    @ObservationIgnored var titleContext = "" {
        didSet {
            guard titleContext != oldValue else { return }
            documents.removeAll()
            rowCache.removeAll()
        }
    }

    /// Brings the index up to date with the chats: a chat whose stamp has
    /// not moved costs a stamp; only a stale one is read into a source (and
    /// only then is its title made).
    func update(_ conversations: [QuickConversation], title: (QuickConversation) -> String) {
        var stale: [ChatSearchSource] = []
        for conversation in conversations where !isCurrent(conversation.id, ChatSearchStamp(conversation)) {
            stale.append(ChatSearchSource(
                conversation,
                title: title(conversation),
                attachments: ChatSearchSource.attachments(in: conversation)
            ))
        }
        update(live: Set(conversations.map(\.id)), stale: stale)
    }

    /// Brings the index up to date with `sources`: current documents stay,
    /// stale ones fold again, deleted chats go. Small stale text folds now;
    /// a large first build folds off the main actor.
    func update(_ sources: [ChatSearchSource]) {
        update(live: Set(sources.map(\.id)), stale: sources.filter { !isCurrent($0.id, $0.stamp) })
    }

    private func isCurrent(_ id: UUID, _ stamp: ChatSearchStamp) -> Bool {
        documents[id]?.stamp == stamp || building[id] == stamp
    }

    private func update(live: Set<UUID>, stale: [ChatSearchSource]) {
        if documents.count > live.count || documents.keys.contains(where: { !live.contains($0) }) {
            documents = documents.filter { live.contains($0.key) }
        }
        guard !stale.isEmpty else {
            parkedStale = parkedStale.filter { live.contains($0.id) }
            return
        }
        // A batch that arrives now supersedes whatever was parked for it.
        let staleIDs = Set(stale.map(\.id))
        parkedStale = parkedStale.filter { live.contains($0.id) && !staleIDs.contains($0.id) }
        let size = stale.reduce(0) { total, source in
            total + source.title.utf8.count
                + source.questions.reduce(0) { $0 + $1.utf8.count }
                + source.answers.reduce(0) { $0 + $1.utf8.count }
        }
        guard let backgroundThreshold, size > backgroundThreshold else {
            for source in stale { documents[source.id] = ChatSearchDocument(source) }
            return
        }
        // The size test comes before the in-flight test: a large batch that
        // arrives during a build is parked, never folded on the main actor.
        guard buildTask == nil else {
            // A title-only stand-in keeps a ranking pass from folding the
            // parked body inline; the chained build replaces it.
            for source in stale { documents[source.id] = ChatSearchDocument(titleOnly: source) }
            parkedStale = Self.merged(parkedStale, stale)
            return
        }
        startBuild(stale)
    }

    /// One entry per chat, newest stamp wins, so a repeated update while a
    /// build was in flight parks each chat once.
    private static func merged(
        _ parked: [ChatSearchSource],
        _ incoming: [ChatSearchSource]
    ) -> [ChatSearchSource] {
        var byID: [UUID: ChatSearchSource] = [:]
        var order: [UUID] = []
        for source in parked + incoming {
            if byID[source.id] == nil { order.append(source.id) }
            byID[source.id] = source
        }
        return order.compactMap { byID[$0] }
    }

    private func startBuild(_ stale: [ChatSearchSource]) {
        for source in stale {
            building[source.id] = source.stamp
            // Until the build lands, the title is searched.
            documents[source.id] = ChatSearchDocument(titleOnly: source)
        }
        buildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let folded = stale.map { ChatSearchDocument($0) }
            guard !Task.isCancelled else { return }
            await self?.land(folded)
        }
    }

    private func land(_ folded: [ChatSearchDocument]) {
        for document in folded where building[document.id] == document.stamp {
            // A chat changed since the build started keeps its title stand-in
            // until the next update folds it again.
            if documents[document.id]?.stamp == document.stamp {
                documents[document.id] = document
            }
        }
        building.removeAll()
        buildTask = nil
        rowCache.removeAll()
        revision &+= 1
        // A batch parked during the build folds in the background, not here.
        guard !parkedStale.isEmpty else { return }
        let parked = parkedStale
        parkedStale = []
        startBuild(parked)
    }

    /// Waits for a background build (tests, and a caller that must have
    /// message text searched). A build that parked another one chains, so the
    /// wait drains every build it started.
    func waitForBuild() async {
        while let task = buildTask {
            await task.value
        }
    }

    /// The document for one chat, folding it now when the index has none
    /// (a chat the last update did not see).
    func document(for source: ChatSearchSource) -> ChatSearchDocument {
        if let document = documents[source.id], document.stamp == source.stamp || building[source.id] == source.stamp {
            return document
        }
        let document = ChatSearchDocument(source)
        documents[source.id] = document
        return document
    }

    func document(id: UUID) -> ChatSearchDocument? { documents[id] }

    /// The rows cached for `key`, if they are still current.
    func cachedRows(for key: RowKey) -> [LauncherCatalogItem]? {
        rowCache.last { $0.key == key }?.rows
    }

    func storeRows(_ rows: [LauncherCatalogItem], for key: RowKey) {
        rowCache.removeAll { $0.key.query == key.query }
        rowCache.append((key, rows))
        if rowCache.count > Self.rowCacheLimit { rowCache.removeFirst(rowCache.count - Self.rowCacheLimit) }
    }
}

extension ChatSearchSource {
    /// The names chat search matches for a chat's attachments: files by
    /// name, links by title and host. Pictures and selections have no name
    /// worth finding.
    static func attachments(in conversation: QuickConversation) -> [Attachment] {
        conversation.messages.flatMap(\.attachmentRefs).compactMap { ref in
            switch ref.kind {
            case .link:
                Attachment(kind: .link, name: [ref.name, ref.host].compactMap { $0 }.joined(separator: " "))
            case .image, .screenshot, .selection:
                nil
            default:
                Attachment(kind: .file, name: ref.name)
            }
        }
    }
}
