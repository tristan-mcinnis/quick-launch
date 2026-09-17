import Foundation

/// One passage handed to a model, with the location it came from.
public struct DocumentChunk: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// `<attachmentID>#<index>`, stable for one chunking of one document.
    public var id: String
    public var attachmentID: String
    public var index: Int
    public var text: String
    /// "Page 3", "Slide 2 · part 2 of 5", "Sheet \"Costs\"".
    public var label: String?
    public var unit: DocumentUnit?
    /// Which `DocumentSection` this chunk came from.
    public var sectionIndex: Int?
    /// Character offsets inside the section's text.
    public var startCharacter: Int
    public var endCharacter: Int

    public init(
        id: String,
        attachmentID: String,
        index: Int,
        text: String,
        label: String? = nil,
        unit: DocumentUnit? = nil,
        sectionIndex: Int? = nil,
        startCharacter: Int = 0,
        endCharacter: Int? = nil
    ) {
        self.id = id
        self.attachmentID = attachmentID
        self.index = index
        self.text = text
        self.label = label
        self.unit = unit
        self.sectionIndex = sectionIndex
        self.startCharacter = startCharacter
        self.endCharacter = endCharacter ?? (startCharacter + text.count)
    }
}

/// Why a selection chose what it chose.
public enum SelectionReason: String, Codable, Sendable, CaseIterable {
    /// The document is short enough that everything was kept.
    case wholeDocument
    /// Chunks ranked by lexical match, best first.
    case rankedMatches
    /// A broad question, so coverage was spread across the document.
    case distributedCoverage
    /// Nothing matched the question. Reported honestly, nothing invented.
    case noMatch
    /// The budget was smaller than the passages that were wanted.
    case budgetExhausted
    /// The document had no readable text at all.
    case emptyDocument
}

/// What one attachment contributes to a request.
public struct ChunkSelection: Codable, Sendable, Equatable {
    public var attachmentID: String
    public var name: String?
    public var chunks: [DocumentChunk]
    /// Labels of the included chunks, in order, for coverage reporting.
    public var labels: [String]
    public var isComplete: Bool
    public var matched: Bool
    public var reason: SelectionReason
    public var truncatedByBudget: Bool
    /// A line the caller may show or pass on, e.g. that nothing matched.
    public var note: String?
    public var characterCount: Int

    public init(
        attachmentID: String,
        name: String? = nil,
        chunks: [DocumentChunk] = [],
        labels: [String] = [],
        isComplete: Bool = false,
        matched: Bool = false,
        reason: SelectionReason,
        truncatedByBudget: Bool = false,
        note: String? = nil,
        characterCount: Int = 0
    ) {
        self.attachmentID = attachmentID
        self.name = name
        self.chunks = chunks
        self.labels = labels
        self.isComplete = isComplete
        self.matched = matched
        self.reason = reason
        self.truncatedByBudget = truncatedByBudget
        self.note = note
        self.characterCount = characterCount
    }

    /// The text of the selected chunks, in order.
    public var text: String {
        chunks.map(\.text).joined(separator: "\n\n")
    }
}

/// One attachment to plan for.
public struct AttachmentDocument: Sendable, Equatable {
    public var attachmentID: String
    public var document: ExtractedDocument

    public init(attachmentID: String, document: ExtractedDocument) {
        self.attachmentID = attachmentID
        self.document = document
    }
}

/// A whole document split into chunks, before any query.
public struct ChunkSet: Sendable, Equatable {
    public var attachmentID: String
    public var name: String?
    public var chunks: [DocumentChunk]
    public var characterCount: Int
    /// True when the document was short enough to keep whole.
    public var isWholeDocument: Bool

    public init(
        attachmentID: String,
        name: String? = nil,
        chunks: [DocumentChunk],
        characterCount: Int,
        isWholeDocument: Bool
    ) {
        self.attachmentID = attachmentID
        self.name = name
        self.chunks = chunks
        self.characterCount = characterCount
        self.isWholeDocument = isWholeDocument
    }
}

/// The whole plan for one request: what each attachment contributes, under
/// one total character budget.
public struct SelectionPlan: Sendable, Equatable {
    /// Keyed by attachment ID.
    public var selections: [String: ChunkSelection]
    /// Attachment IDs in plan order.
    public var order: [String]
    public var totalCharacters: Int
    public var budgetCharacters: Int
    public var truncatedByBudget: Bool

    public init(
        selections: [String: ChunkSelection],
        order: [String],
        totalCharacters: Int,
        budgetCharacters: Int,
        truncatedByBudget: Bool
    ) {
        self.selections = selections
        self.order = order
        self.totalCharacters = totalCharacters
        self.budgetCharacters = budgetCharacters
        self.truncatedByBudget = truncatedByBudget
    }

    public var ordered: [ChunkSelection] { order.compactMap { selections[$0] } }

    /// The selections that actually contribute text. An attachment with no
    /// chunks needs no separator and adds nothing to the serialized plan.
    public var contributing: [ChunkSelection] { ordered.filter { !$0.chunks.isEmpty } }

    /// The exact text the plan would send: every contributing chunk in order,
    /// joined by the same separator that `totalCharacters` counts. Joining the
    /// `contributing` selections with "\n\n" gives exactly this string.
    public var text: String {
        contributing
            .map(\.text)
            .joined(separator: "\n\n")
    }
}

/// Splits documents into passages and chooses the passages a question needs.
///
/// Deterministic and local by construction: no model call, no network call,
/// no clock. Ranking is lexical over English words and CJK bigrams.
///
/// The rules:
/// - a document of at most `shortDocumentCharacters` is kept whole;
/// - a longer one is split at `chunkCharacters` with `overlapCharacters` of
///   overlap, so a fact on a boundary lands in one chunk;
/// - a broad question spreads coverage across the document, labelled;
/// - a question with no lexical match returns nothing and says so.
public struct DocumentContext: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Target characters per chunk.
        public var chunkCharacters: Int
        /// Characters shared between neighbouring chunks of one section.
        public var overlapCharacters: Int
        /// Most chunks one attachment may contribute to a request.
        public var maximumChunksPerAttachment: Int
        /// A document at or under this size is kept whole.
        public var shortDocumentCharacters: Int
        /// The total character budget for one request when the caller gives
        /// none.
        public var defaultBudgetCharacters: Int
        /// A partial chunk is kept only if at least this many characters fit.
        public var minimumChunkCharacters: Int

        public init(
            chunkCharacters: Int = 2_000,
            overlapCharacters: Int = 200,
            maximumChunksPerAttachment: Int = 12,
            shortDocumentCharacters: Int = 2_000,
            defaultBudgetCharacters: Int = 400_000,
            minimumChunkCharacters: Int = 200
        ) {
            self.chunkCharacters = chunkCharacters
            self.overlapCharacters = overlapCharacters
            self.maximumChunksPerAttachment = maximumChunksPerAttachment
            self.shortDocumentCharacters = shortDocumentCharacters
            self.defaultBudgetCharacters = defaultBudgetCharacters
            self.minimumChunkCharacters = minimumChunkCharacters
        }

        public static let `default` = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    public static let standard = DocumentContext()

    /// What joins two chunks' text in a selection, and two attachments' text in
    /// a plan. Counted against every budget.
    static let chunkSeparator = "\n\n"

    // MARK: Chunking

    /// Splits one document into chunks. Reuses the document's own section
    /// labels so every chunk can say where it came from.
    public func chunkSet(for document: ExtractedDocument, attachmentID: String) -> ChunkSet {
        let sections = Self.sections(of: document)
        let total = sections.reduce(0) { $0 + $1.text.count }
        guard total > 0 else {
            return ChunkSet(
                attachmentID: attachmentID,
                name: document.name,
                chunks: [],
                characterCount: 0,
                isWholeDocument: false
            )
        }

        if total <= configuration.shortDocumentCharacters {
            let text = sections.map(\.text).joined(separator: "\n\n")
            let chunk = DocumentChunk(
                id: "\(attachmentID)#0",
                attachmentID: attachmentID,
                index: 0,
                text: text,
                label: Self.combinedLabel(sections),
                unit: document.sectionUnit ?? .section,
                sectionIndex: 0,
                startCharacter: 0,
                endCharacter: text.count
            )
            return ChunkSet(
                attachmentID: attachmentID,
                name: document.name,
                chunks: [chunk],
                characterCount: total,
                isWholeDocument: true
            )
        }

        var chunks: [DocumentChunk] = []
        for (sectionIndex, section) in sections.enumerated() {
            let text = section.text
            guard !text.isEmpty else { continue }
            if text.count <= configuration.chunkCharacters {
                chunks.append(DocumentChunk(
                    id: "\(attachmentID)#\(chunks.count)",
                    attachmentID: attachmentID,
                    index: chunks.count,
                    text: text,
                    label: section.label,
                    unit: section.unit,
                    sectionIndex: sectionIndex,
                    startCharacter: 0,
                    endCharacter: text.count
                ))
                continue
            }

            let step = max(1, configuration.chunkCharacters - configuration.overlapCharacters)
            let starts = Array(stride(from: 0, to: text.count, by: step))
            var part = 0
            for start in starts {
                let startIndex = text.index(text.startIndex, offsetBy: start)
                let endIndex = text.index(startIndex, offsetBy: configuration.chunkCharacters, limitedBy: text.endIndex)
                    ?? text.endIndex
                let body = String(text[startIndex..<endIndex])
                part += 1
                chunks.append(DocumentChunk(
                    id: "\(attachmentID)#\(chunks.count)",
                    attachmentID: attachmentID,
                    index: chunks.count,
                    text: body,
                    label: Self.partLabel(section.label, part: part, of: (starts.count)),
                    unit: section.unit,
                    sectionIndex: sectionIndex,
                    startCharacter: start,
                    endCharacter: start + body.count
                ))
                if endIndex == text.endIndex { break }
            }
        }
        return ChunkSet(
            attachmentID: attachmentID,
            name: document.name,
            chunks: chunks,
            characterCount: total,
            isWholeDocument: false
        )
    }

    // MARK: Planning

    /// Chooses passages for every attachment under one total budget, in the
    /// order the attachments are given (the caller puts the current source
    /// first).
    public func select(
        query: String,
        documents: [AttachmentDocument],
        budget: Int? = nil,
        intent: QuestionIntent? = nil
    ) -> SelectionPlan {
        let budgetCharacters = budget ?? configuration.defaultBudgetCharacters
        var remaining = max(0, budgetCharacters)
        var total = 0
        var hasContent = false
        var selections: [String: ChunkSelection] = [:]
        var order: [String] = []
        var truncated = false

        for attachment in documents {
            let set = chunkSet(for: attachment.document, attachmentID: attachment.attachmentID)
            // Reserve the separator that joins this attachment's text to the
            // previous one, so the serialized plan never exceeds the budget.
            let reserve = hasContent ? Self.chunkSeparator.count : 0
            let selection = select(
                query: query,
                in: set,
                budget: max(0, remaining - reserve),
                intent: intent
            )
            selections[set.attachmentID] = selection
            order.append(set.attachmentID)
            if !selection.chunks.isEmpty {
                remaining -= selection.characterCount + reserve
                if remaining < 0 { remaining = 0 }
                total += selection.characterCount + reserve
                hasContent = true
            }
            if selection.truncatedByBudget { truncated = true }
        }

        return SelectionPlan(
            selections: selections,
            order: order,
            totalCharacters: total,
            budgetCharacters: budgetCharacters,
            truncatedByBudget: truncated
        )
    }

    /// Chooses passages from one attachment's chunk set.
    public func select(
        query: String,
        in set: ChunkSet,
        budget: Int? = nil,
        intent: QuestionIntent? = nil
    ) -> ChunkSelection {
        let available = budget ?? configuration.defaultBudgetCharacters
        guard !set.chunks.isEmpty else {
            return ChunkSelection(
                attachmentID: set.attachmentID,
                name: set.name,
                reason: .emptyDocument,
                note: "No readable text in \(set.name ?? "the document")."
            )
        }

        // A short document is kept whole.
        if set.isWholeDocument {
            return fit(
                chunks: set.chunks,
                into: available,
                base: ChunkSelection(
                    attachmentID: set.attachmentID,
                    name: set.name,
                    isComplete: true,
                    matched: true,
                    reason: .wholeDocument
                )
            )
        }

        let queryTokens = Self.tokens(of: query)
        let broad = intent?.asksForBroadSummary ?? false

        if broad {
            let indices = Self.distributedIndices(
                count: set.chunks.count,
                limit: configuration.maximumChunksPerAttachment
            )
            let chosen = indices.map { set.chunks[$0] }
            return fit(
                chunks: chosen,
                into: available,
                base: ChunkSelection(
                    attachmentID: set.attachmentID,
                    name: set.name,
                    matched: true,
                    reason: .distributedCoverage
                )
            )
        }

        guard !queryTokens.isEmpty else {
            return ChunkSelection(
                attachmentID: set.attachmentID,
                name: set.name,
                reason: .noMatch,
                note: "The question has no searchable terms."
            )
        }

        let ranked = Self.rank(chunks: set.chunks, queryTokens: queryTokens)
            .prefix(configuration.maximumChunksPerAttachment)
        guard !ranked.isEmpty else {
            return ChunkSelection(
                attachmentID: set.attachmentID,
                name: set.name,
                reason: .noMatch,
                note: "No passage in \(set.name ?? "the document") matched the question."
            )
        }

        return fit(
            chunks: Array(ranked),
            into: available,
            base: ChunkSelection(
                attachmentID: set.attachmentID,
                name: set.name,
                matched: true,
                reason: .rankedMatches
            )
        )
    }

    // MARK: Fitting to a budget

    /// Keeps the chunks in order while the budget allows; a chunk that does
    /// not fit is cut to the remaining budget when enough room is left, and
    /// the selection says it was cut.
    private func fit(chunks: [DocumentChunk], into budget: Int, base: ChunkSelection) -> ChunkSelection {
        guard budget > 0 else {
            return ChunkSelection(
                attachmentID: base.attachmentID,
                name: base.name,
                isComplete: false,
                matched: base.matched,
                reason: .budgetExhausted,
                truncatedByBudget: true,
                note: "No room left in the request budget."
            )
        }

        var kept: [DocumentChunk] = []
        var used = 0
        var truncated = false
        let separatorCost = Self.chunkSeparator.count

        for chunk in chunks {
            let cost = chunk.text.count + (kept.isEmpty ? 0 : separatorCost)
            if used + cost <= budget {
                kept.append(chunk)
                used += cost
                continue
            }
            let remaining = budget - used - (kept.isEmpty ? 0 : separatorCost)
            if remaining >= configuration.minimumChunkCharacters {
                var cut = chunk
                let text = String(chunk.text.prefix(remaining))
                cut.text = text
                cut.endCharacter = chunk.startCharacter + text.count
                cut.label = (chunk.label.map { "\($0) · truncated" }) ?? "truncated"
                kept.append(cut)
                used += text.count + (kept.count == 1 ? 0 : separatorCost)
                truncated = true
            } else if !kept.isEmpty {
                truncated = true
            }
            break
        }

        guard !kept.isEmpty else {
            return ChunkSelection(
                attachmentID: base.attachmentID,
                name: base.name,
                matched: base.matched,
                reason: .budgetExhausted,
                truncatedByBudget: true,
                note: "No room left in the request budget."
            )
        }

        var selection = base
        selection.chunks = kept
        selection.labels = kept.enumerated().map { index, chunk in
            chunk.label ?? "part \(index + 1)"
        }
        // The character count is the exact length of `text`, separators
        // included, so a budget can be honoured without arithmetic.
        selection.characterCount = used
        selection.truncatedByBudget = truncated
        if truncated { selection.reason = .budgetExhausted }
        return selection
    }

    // MARK: Ranking

    /// Chunks that share at least one query token, best first. Distinct token
    /// matches dominate; total occurrences break ties; chunk order breaks the
    /// rest, so the result is stable.
    static func rank(chunks: [DocumentChunk], queryTokens: [String]) -> [DocumentChunk] {
        var scored: [(chunk: DocumentChunk, distinct: Int, occurrences: Int)] = []
        let unique = Array(Set(queryTokens))
        for chunk in chunks {
            let counts = tokenCounts(of: chunk.text + " " + (chunk.label ?? ""))
            var distinct = 0
            var occurrences = 0
            for token in unique {
                if let count = counts[token] {
                    distinct += 1
                    occurrences += count
                }
            }
            if distinct > 0 {
                scored.append((chunk, distinct, occurrences))
            }
        }
        return scored
            .sorted {
                if $0.distinct != $1.distinct { return $0.distinct > $1.distinct }
                if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
                return $0.chunk.index < $1.chunk.index
            }
            .map(\.chunk)
    }

    static func tokenCounts(of text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tokens(of: text) {
            counts[token, default: 0] += 1
        }
        return counts
    }

    /// The lexical tokens of a text: lowercased words of at least two
    /// characters, plus every CJK bigram (a single CJK character on its own).
    public static func tokens(of text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        var cjkRun: [Character] = []

        func flushWord() {
            if word.count >= 2 { tokens.append(word) }
            word = ""
        }
        func flushCJK() {
            if cjkRun.count == 1 {
                tokens.append(String(cjkRun[0]))
            } else if cjkRun.count > 1 {
                for index in 0..<(cjkRun.count - 1) {
                    tokens.append(String(cjkRun[index...index + 1]))
                }
            }
            cjkRun = []
        }

        for character in text.lowercased() {
            guard let scalar = character.unicodeScalars.first else { continue }
            if UnicodeScript.isCJK(scalar) {
                flushWord()
                cjkRun.append(character)
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushCJK()
                word.append(character)
            } else {
                flushWord()
                flushCJK()
            }
        }
        flushWord()
        flushCJK()
        return tokens
    }

    /// Evenly spaced indices including the first and the last.
    static func distributedIndices(count: Int, limit: Int) -> [Int] {
        guard count > limit, limit > 1 else { return Array(0..<count) }
        var result: [Int] = []
        for step in 0..<limit {
            let position = (Double(step) * Double(count - 1) / Double(limit - 1)).rounded()
            let index = Int(position)
            if result.last != index { result.append(index) }
        }
        return result
    }

    // MARK: Sections

    static func sections(of document: ExtractedDocument) -> [DocumentSection] {
        let nonEmpty = document.sections.filter { !$0.text.isEmpty }
        if !nonEmpty.isEmpty { return nonEmpty }
        if let text = document.text, !text.isEmpty {
            return [DocumentSection(text: text)]
        }
        return []
    }

    static func combinedLabel(_ sections: [DocumentSection]) -> String? {
        let labels = sections.compactMap(\.label)
        guard let first = labels.first else { return nil }
        guard let last = labels.last, labels.count > 1, first != last else { return first }
        return "\(first) – \(last)"
    }

    static func partLabel(_ label: String?, part: Int, of total: Int) -> String {
        guard total > 1 else { return label ?? "part \(part)" }
        let suffix = "part \(part) of \(total)"
        return label.map { "\($0) · \(suffix)" } ?? suffix
    }
}

/// The CJK ranges this package treats as unspaced text.
public enum UnicodeScript {
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            true
        default:
            false
        }
    }
}
