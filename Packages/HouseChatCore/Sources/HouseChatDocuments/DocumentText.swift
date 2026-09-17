import Foundation
import HouseChatCore

/// Text read from one document, before the character cap and NFKC.
///
/// Each section carries the location the shared schema stores: a label
/// ("Page 3", "Slide 2 (notes)", "Sheet \"Costs\""), the unit, its 1-based
/// index, and the range it covers.
struct DocumentText: Sendable {
    struct Section: Sendable, Equatable {
        var label: String?
        var unit: DocumentUnit?
        var index: Int?
        var range: DocumentRange?
        var body: String
    }

    /// A page, slide, sheet, or row cap that stopped the read.
    struct UnitCut: Sendable, Equatable {
        var unit: DocumentUnit
        var kept: Int
        var total: Int?
    }

    /// What one read finished with.
    struct Finished: Sendable, Equatable {
        var sections: [DocumentSection]
        var text: String
        var characterCount: Int
        var truncation: TextTruncation?
    }

    var sections: [Section]
    /// What one section is, for a paged document.
    var sectionUnit: DocumentUnit?
    /// Pages, slides, or sheets the document has, read or not.
    var unitCount: Int?
    var unitCut: UnitCut?
    /// A partial read that is not a head cut: pages an OCR cap skipped, or
    /// another bounded read that left units unread. Reported as the record's
    /// truncation so a caller never sees it as complete.
    var partialTruncation: TextTruncation?
    var notes: [DocumentNote] = []
    /// False for code, whose text is kept exactly.
    var normalizes = true

    init(
        sections: [Section],
        sectionUnit: DocumentUnit? = nil,
        unitCount: Int? = nil,
        unitCut: UnitCut? = nil,
        partialTruncation: TextTruncation? = nil,
        notes: [DocumentNote] = [],
        normalizes: Bool = true
    ) {
        self.sections = sections
        self.sectionUnit = sectionUnit
        self.unitCount = unitCount
        self.unitCut = unitCut
        self.partialTruncation = partialTruncation
        self.notes = notes
        self.normalizes = normalizes
    }

    /// A document with no units: one flat section.
    init(text: String, normalizes: Bool = true, notes: [DocumentNote] = []) {
        self.init(sections: [Section(body: text)], notes: notes, normalizes: normalizes)
    }

    /// The final text: NFKC (unless code), line endings unified, sections
    /// joined, then the head kept up to `characterCap`. Whole sections stay
    /// whole; the section that crosses the cap keeps its head. Throws
    /// `.empty` when no section has readable text.
    func finished(characterCap: Int) throws -> Finished {
        var cleaned: [DocumentSection] = []
        for section in sections {
            let body = DocumentTextCleaner.clean(section.body, normalizes: normalizes)
            guard !body.isEmpty else { continue }
            cleaned.append(DocumentSection(
                label: section.label,
                unit: section.unit,
                index: section.index,
                range: section.range,
                text: body
            ))
        }
        guard !cleaned.isEmpty else { throw DocumentExtractionError.empty }

        let total = Self.joinedLength(cleaned)
        var kept: [DocumentSection] = []
        var used = 0
        for section in cleaned {
            let separator = kept.isEmpty ? 0 : 2
            let remaining = characterCap - used - separator
            if remaining <= 0 { break }
            if section.text.count <= remaining {
                used += section.text.count + separator
                kept.append(section)
            } else {
                var cut = section
                cut.text = String(section.text.prefix(remaining))
                used += cut.text.count + separator
                kept.append(cut)
                break
            }
        }
        guard !kept.isEmpty else { throw DocumentExtractionError.empty }
        let text = kept.map(\.text).joined(separator: "\n\n")

        guard text.count < total else {
            let truncation = unitCut.map {
                TextTruncation(unit: $0.unit, keptUnits: $0.kept, totalUnits: $0.total)
            } ?? partialTruncation
            return Finished(sections: kept, text: text, characterCount: total, truncation: truncation)
        }

        var truncation = TextTruncation(keptCharacters: text.count, totalCharacters: total)
        if let sectionUnit {
            truncation.unit = sectionUnit
            truncation.keptUnits = kept.count
            truncation.totalUnits = unitCount ?? cleaned.count
        } else if let unitCut {
            truncation.unit = unitCut.unit
            truncation.keptUnits = unitCut.kept
            truncation.totalUnits = unitCut.total
        }
        return Finished(sections: kept, text: text, characterCount: total, truncation: truncation)
    }

    /// The length the joined sections would have, separators included.
    private static func joinedLength(_ sections: [DocumentSection]) -> Int {
        sections.reduce(0) { partial, section in
            partial + section.text.count + (partial == 0 ? 0 : 2)
        }
    }
}

/// Normalization every extracted text gets before it is cached, sent, or
/// searched.
enum DocumentTextCleaner {
    /// NFKC (so a PDF's Kangxi radical U+2F42 reads as 文 and full-width
    /// letters as ASCII), `\r\n` and `\r` to `\n`, NUL bytes out, trailing
    /// white space trimmed. Code skips NFKC and keeps its text exactly apart
    /// from line endings.
    static func clean(_ text: String, normalizes: Bool) -> String {
        var result = normalizes ? text.precomposedStringWithCompatibilityMapping : text
        if result.contains("\r") {
            result = result.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        if result.contains("\u{0}") {
            result = result.replacingOccurrences(of: "\u{0}", with: "")
        }
        while let last = result.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            result.unicodeScalars.removeLast()
        }
        while let first = result.unicodeScalars.first, first == "\n" {
            result.unicodeScalars.removeFirst()
        }
        return result
    }
}
