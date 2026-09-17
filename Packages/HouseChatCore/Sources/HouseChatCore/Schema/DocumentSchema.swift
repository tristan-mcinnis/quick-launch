import Foundation

/// Which House surface wrote a record. An open string, so RTI can add a
/// surface without waiting for this package.
public struct ChatSurface: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(stringLiteral value: String) { self.rawValue = value }

    public static let quickLaunch = ChatSurface("quick-launch")
    public static let rtiCopilot = ChatSurface("rti-copilot")
    public static let rtiMeeting = ChatSurface("rti-meeting")

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Who wrote one turn. An unrecognized stored value decodes to `.unknown`
/// rather than failing the whole conversation.
public enum TurnRole: String, Codable, Sendable, CaseIterable {
    case user
    case assistant
    case system
    case tool
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TurnRole(rawValue: raw) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What an attachment is. An unrecognized stored value decodes to `.other`;
/// the record keeps the original string in `kindRaw`.
public enum AttachmentKind: String, Codable, Sendable, CaseIterable {
    case pdf
    /// docx, doc, rtf, rtfd, odt.
    case word
    case powerpoint
    case excel
    case html
    case text
    case markdown
    /// Source kept exactly, without NFKC.
    case code
    case image
    case screenshot
    case link
    case selection
    /// An unrecognized kind from a newer build; `AttachmentRecord.kindRaw`
    /// has the original string.
    case other

    /// Images are never written into an archive by the app that owns them.
    public var isImage: Bool { self == .image || self == .screenshot }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AttachmentKind(rawValue: raw) ?? .other
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A document unit a section, or a cut, counts.
public enum DocumentUnit: String, Codable, Sendable, CaseIterable {
    case page
    case slide
    case sheet
    case row
    case section
    case paragraph
    case character
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DocumentUnit(rawValue: raw) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The inclusive unit range a section covers, for a page/slide/sheet label.
public struct DocumentRange: Codable, Sendable, Equatable, Hashable {
    public var start: Int?
    public var end: Int?
    public var extra: ExtraFields

    public init(start: Int? = nil, end: Int? = nil, extra: ExtraFields = ExtraFields()) {
        self.start = start
        self.end = end
        self.extra = extra
    }

    private static let knownKeys: Set<String> = ["start", "end"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        start = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("start"))
        end = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("end"))
        extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(start, forKey: AnyCodingKey("start"))
        try c.encodeIfPresent(end, forKey: AnyCodingKey("end"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

/// How much text was kept. An explicit covered set distinguishes a partial
/// read from a contiguous head cut.
public struct TextTruncation: Codable, Sendable, Equatable, Hashable {
    public var keptCharacters: Int?
    public var totalCharacters: Int?
    public var unit: DocumentUnit?
    public var keptUnits: Int?
    public var totalUnits: Int?
    /// Actual one-based units read, when coverage is not necessarily a prefix.
    public var coveredUnits: [Int]?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        keptCharacters: Int? = nil,
        totalCharacters: Int? = nil,
        unit: DocumentUnit? = nil,
        keptUnits: Int? = nil,
        totalUnits: Int? = nil,
        coveredUnits: [Int]? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.keptCharacters = keptCharacters
        self.totalCharacters = totalCharacters
        self.unit = unit
        self.keptUnits = keptUnits
        self.totalUnits = totalUnits
        self.coveredUnits = coveredUnits
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "keptCharacters", "totalCharacters", "unit", "keptUnits", "totalUnits", "coveredUnits",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.keptCharacters = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("keptCharacters"))
        self.totalCharacters = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("totalCharacters"))
        self.unit = try c.decodeIfPresent(DocumentUnit.self, forKey: AnyCodingKey("unit"))
        self.keptUnits = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("keptUnits"))
        self.totalUnits = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("totalUnits"))
        self.coveredUnits = try c.decodeIfPresent([Int].self, forKey: AnyCodingKey("coveredUnits"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(keptCharacters, forKey: AnyCodingKey("keptCharacters"))
        try c.encodeIfPresent(totalCharacters, forKey: AnyCodingKey("totalCharacters"))
        try c.encodeIfPresent(unit, forKey: AnyCodingKey("unit"))
        try c.encodeIfPresent(keptUnits, forKey: AnyCodingKey("keptUnits"))
        try c.encodeIfPresent(totalUnits, forKey: AnyCodingKey("totalUnits"))
        try c.encodeIfPresent(coveredUnits, forKey: AnyCodingKey("coveredUnits"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }

    /// "first 200,000 of 612,000 characters, pages 1-120 of 300".
    public var summary: String {
        var parts: [String] = []
        if let kept = keptCharacters {
            if let total = totalCharacters {
                parts.append("first \(Self.count(kept)) of \(Self.count(total)) characters")
            } else {
                parts.append("first \(Self.count(kept)) characters")
            }
        }
        if let unit, let kept = keptUnits {
            let noun = Self.noun(unit)
            let coverage: String
            if let coveredUnits {
                let sorted = Set(coveredUnits.filter { $0 > 0 }).sorted()
                if let last = sorted.last, sorted.first == 1, sorted.count == last {
                    coverage = last == 1 ? "1" : "1-\(Self.count(last))"
                } else {
                    coverage = sorted.isEmpty ? "none" : sorted.map(Self.count).joined(separator: ", ")
                }
            } else {
                coverage = kept > 0 ? "1-\(Self.count(kept))" : "none"
            }
            if let total = totalUnits {
                parts.append("\(noun) \(coverage) of \(Self.count(total))")
            } else {
                parts.append("\(noun) \(coverage)")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// The line a model reads: "[Truncated: the first 200,000 of 612,000
    /// characters.]"
    public var modelNote: String {
        let facts = summary
        return facts.isEmpty ? "[Truncated.]" : "[Truncated: the \(facts).]"
    }

    public static func noun(_ unit: DocumentUnit) -> String {
        switch unit {
        case .page: "pages"
        case .slide: "slides"
        case .sheet: "sheets"
        case .row: "rows"
        case .section: "sections"
        case .paragraph: "paragraphs"
        case .character: "characters"
        case .unknown: "units"
        }
    }

    /// Grouped digits on every Mac, whatever the system language.
    public static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}

/// A unit cap that stopped a read, and what the document had.
public struct DocumentUnitCut: Codable, Sendable, Equatable, Hashable {
    public var unit: DocumentUnit
    public var kept: Int
    public var total: Int?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(unit: DocumentUnit, kept: Int, total: Int? = nil, extra: ExtraFields = ExtraFields()) {
        self.unit = unit
        self.kept = kept
        self.total = total
        self.extra = extra
    }

    private static let knownKeys: Set<String> = ["unit", "kept", "total"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.unit = try c.decodeIfPresent(DocumentUnit.self, forKey: AnyCodingKey("unit")) ?? .unknown
        self.kept = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("kept")) ?? 0
        self.total = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("total"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(unit, forKey: AnyCodingKey("unit"))
        try c.encode(kept, forKey: AnyCodingKey("kept"))
        try c.encodeIfPresent(total, forKey: AnyCodingKey("total"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

/// One page, slide, sheet, or block of a read document, with a location.
public struct DocumentSection: Codable, Sendable, Equatable, Hashable {
    /// "Page 3", "Slide 2 (notes)", "Sheet \"Costs\"". Nil for a flat text.
    public var label: String?
    public var unit: DocumentUnit?
    /// 1-based number within `unit`, when the section is exactly one unit.
    public var index: Int?
    /// The unit range this section covers.
    public var range: DocumentRange?
    public var text: String
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        label: String? = nil,
        unit: DocumentUnit? = nil,
        index: Int? = nil,
        range: DocumentRange? = nil,
        text: String,
        extra: ExtraFields = ExtraFields()
    ) {
        self.label = label
        self.unit = unit
        self.index = index
        self.range = range
        self.text = text
        self.extra = extra
    }

    private static let knownKeys: Set<String> = ["label", "unit", "index", "range", "text"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.label = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("label"))
        self.unit = try c.decodeIfPresent(DocumentUnit.self, forKey: AnyCodingKey("unit"))
        self.index = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("index"))
        self.range = try c.decodeIfPresent(DocumentRange.self, forKey: AnyCodingKey("range"))
        // A page with no text is legitimate, so an absent body is empty.
        self.text = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("text")) ?? ""
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(label, forKey: AnyCodingKey("label"))
        try c.encodeIfPresent(unit, forKey: AnyCodingKey("unit"))
        try c.encodeIfPresent(index, forKey: AnyCodingKey("index"))
        try c.encodeIfPresent(range, forKey: AnyCodingKey("range"))
        try c.encode(text, forKey: AnyCodingKey("text"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

/// A fact about how a document was read that the model and the UI both see.
public struct DocumentNote: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case ocr
        case spreadsheetSerialDates
        case linkBodyCut
        case partialExtraction
        case unsupportedContent
        case other

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .other
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var kind: Kind
    /// The line inside the model block.
    public var modelLine: String?
    /// The short line a chip or log shows.
    public var detailLine: String?
    /// Pages OCR read, 1-based, when `kind == .ocr`.
    public var pages: [Int]?
    public var totalPages: Int?
    /// Bytes kept when a download or a read was cut.
    public var limitBytes: Int?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        kind: Kind,
        modelLine: String? = nil,
        detailLine: String? = nil,
        pages: [Int]? = nil,
        totalPages: Int? = nil,
        limitBytes: Int? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.kind = kind
        self.modelLine = modelLine
        self.detailLine = detailLine
        self.pages = pages
        self.totalPages = totalPages
        self.limitBytes = limitBytes
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "kind", "modelLine", "detailLine", "pages", "totalPages", "limitBytes",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.kind = try c.decodeIfPresent(Kind.self, forKey: AnyCodingKey("kind")) ?? .other
        self.modelLine = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("modelLine"))
        self.detailLine = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("detailLine"))
        self.pages = try c.decodeIfPresent([Int].self, forKey: AnyCodingKey("pages"))
        self.totalPages = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("totalPages"))
        self.limitBytes = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("limitBytes"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(kind, forKey: AnyCodingKey("kind"))
        try c.encodeIfPresent(modelLine, forKey: AnyCodingKey("modelLine"))
        try c.encodeIfPresent(detailLine, forKey: AnyCodingKey("detailLine"))
        try c.encodeIfPresent(pages, forKey: AnyCodingKey("pages"))
        try c.encodeIfPresent(totalPages, forKey: AnyCodingKey("totalPages"))
        try c.encodeIfPresent(limitBytes, forKey: AnyCodingKey("limitBytes"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }

    /// A scanned PDF read by on-device OCR.
    public static func ocr(pages: [Int], totalPages: Int) -> DocumentNote {
        let phrase = Self.pagesPhrase(pages)
        return DocumentNote(
            kind: .ocr,
            modelLine: "[Scanned PDF: text read by OCR on this Mac, \(phrase) of \(totalPages).]",
            detailLine: "OCR · \(phrase) of \(totalPages)",
            pages: pages,
            totalPages: totalPages
        )
    }

    /// A workbook whose custom date formats stay serial numbers.
    public static let spreadsheetSerialDates = DocumentNote(
        kind: .spreadsheetSerialDates,
        modelLine: "[Dates may appear as spreadsheet serial numbers.]"
    )

    /// A link whose body passed the download cap.
    public static func linkBodyCut(limitBytes: Int) -> DocumentNote {
        let megabytes = limitBytes / (1_024 * 1_024)
        return DocumentNote(
            kind: .linkBodyCut,
            modelLine: "[Only the first \(megabytes) MB of the page was downloaded.]",
            detailLine: "first \(megabytes) MB of the page",
            limitBytes: limitBytes
        )
    }

    /// Text that was read but did not cover the whole document.
    public static func partialExtraction(detailLine: String) -> DocumentNote {
        DocumentNote(kind: .partialExtraction, detailLine: detailLine)
    }

    private static func pagesPhrase(_ pages: [Int]) -> String {
        guard let first = pages.first, let last = pages.last else { return "0 pages" }
        if pages.count == 1 { return "page \(first)" }
        if last - first + 1 == pages.count { return "pages \(first)-\(last)" }
        return "\(pages.count) pages"
    }
}

/// Everything one read produced, in a shape both apps store and search.
///
/// `sections` carry location; `text` is the capped text a model may receive;
/// `characterCount` is the uncapped length; `contentHash` is the SHA-256 of
/// the original bytes, which the archive keys on.
public struct ExtractedDocument: Codable, Sendable, Equatable {
    public var kind: AttachmentKind
    /// "PDF", "Word document", "Swift source".
    public var kindLabel: String
    public var name: String
    public var sections: [DocumentSection]
    /// The unit the sections count, when a document has one.
    public var sectionUnit: DocumentUnit?
    /// Pages, slides, or sheets the document has, read or not.
    public var unitCount: Int?
    public var unitCut: DocumentUnitCut?
    public var notes: [DocumentNote]
    /// SHA-256 of the original bytes, lowercase hex.
    public var contentHash: String?
    public var byteCount: Int?
    /// Characters before any cut.
    public var characterCount: Int?
    /// The text after the cap. Nil for an image.
    public var text: String?
    public var truncation: TextTruncation?
    public var path: String?
    public var url: URL?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// "image/png" or "image/jpeg" for a normalized image.
    public var normalizedImageMimeType: String?
    public var extractorVersion: Int?
    public var extractedAt: Date?
    public var extra: ExtraFields

    public init(
        kind: AttachmentKind,
        kindLabel: String,
        name: String,
        sections: [DocumentSection] = [],
        sectionUnit: DocumentUnit? = nil,
        unitCount: Int? = nil,
        unitCut: DocumentUnitCut? = nil,
        notes: [DocumentNote] = [],
        contentHash: String? = nil,
        byteCount: Int? = nil,
        characterCount: Int? = nil,
        text: String? = nil,
        truncation: TextTruncation? = nil,
        path: String? = nil,
        url: URL? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        normalizedImageMimeType: String? = nil,
        extractorVersion: Int? = nil,
        extractedAt: Date? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.kind = kind
        self.kindLabel = kindLabel
        self.name = name
        self.sections = sections
        self.sectionUnit = sectionUnit
        self.unitCount = unitCount
        self.unitCut = unitCut
        self.notes = notes
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.characterCount = characterCount
        self.text = text
        self.truncation = truncation
        self.path = path
        self.url = url
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.normalizedImageMimeType = normalizedImageMimeType
        self.extractorVersion = extractorVersion
        self.extractedAt = extractedAt
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "kind", "kindLabel", "name", "sections", "sectionUnit", "unitCount",
        "unitCut", "notes", "contentHash", "byteCount", "characterCount",
        "text", "truncation", "path", "url", "pixelWidth", "pixelHeight",
        "normalizedImageMimeType", "extractorVersion", "extractedAt",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.kind = try c.decodeIfPresent(AttachmentKind.self, forKey: AnyCodingKey("kind")) ?? .text
        self.kindLabel = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("kindLabel")) ?? self.kind.rawValue
        self.name = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("name")) ?? ""
        self.sections = try c.decodeIfPresent([DocumentSection].self, forKey: AnyCodingKey("sections")) ?? []
        self.sectionUnit = try c.decodeIfPresent(DocumentUnit.self, forKey: AnyCodingKey("sectionUnit"))
        self.unitCount = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("unitCount"))
        self.unitCut = try c.decodeIfPresent(DocumentUnitCut.self, forKey: AnyCodingKey("unitCut"))
        self.notes = try c.decodeIfPresent([DocumentNote].self, forKey: AnyCodingKey("notes")) ?? []
        self.contentHash = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("contentHash"))
        self.byteCount = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("byteCount"))
        self.characterCount = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("characterCount"))
        self.text = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("text"))
        self.truncation = try c.decodeIfPresent(TextTruncation.self, forKey: AnyCodingKey("truncation"))
        self.path = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("path"))
        self.url = try c.decodeIfPresent(URL.self, forKey: AnyCodingKey("url"))
        self.pixelWidth = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("pixelWidth"))
        self.pixelHeight = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("pixelHeight"))
        self.normalizedImageMimeType = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("normalizedImageMimeType"))
        self.extractorVersion = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("extractorVersion"))
        self.extractedAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("extractedAt"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(kind, forKey: AnyCodingKey("kind"))
        try c.encode(kindLabel, forKey: AnyCodingKey("kindLabel"))
        try c.encode(name, forKey: AnyCodingKey("name"))
        try c.encode(sections, forKey: AnyCodingKey("sections"))
        try c.encodeIfPresent(sectionUnit, forKey: AnyCodingKey("sectionUnit"))
        try c.encodeIfPresent(unitCount, forKey: AnyCodingKey("unitCount"))
        try c.encodeIfPresent(unitCut, forKey: AnyCodingKey("unitCut"))
        try c.encode(notes, forKey: AnyCodingKey("notes"))
        try c.encodeIfPresent(contentHash, forKey: AnyCodingKey("contentHash"))
        try c.encodeIfPresent(byteCount, forKey: AnyCodingKey("byteCount"))
        try c.encodeIfPresent(characterCount, forKey: AnyCodingKey("characterCount"))
        try c.encodeIfPresent(text, forKey: AnyCodingKey("text"))
        try c.encodeIfPresent(truncation, forKey: AnyCodingKey("truncation"))
        try c.encodeIfPresent(path, forKey: AnyCodingKey("path"))
        try c.encodeIfPresent(url, forKey: AnyCodingKey("url"))
        try c.encodeIfPresent(pixelWidth, forKey: AnyCodingKey("pixelWidth"))
        try c.encodeIfPresent(pixelHeight, forKey: AnyCodingKey("pixelHeight"))
        try c.encodeIfPresent(normalizedImageMimeType, forKey: AnyCodingKey("normalizedImageMimeType"))
        try c.encodeIfPresent(extractorVersion, forKey: AnyCodingKey("extractorVersion"))
        try c.encodeIfPresent(extractedAt, forKey: AnyCodingKey("extractedAt"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }

    /// A flat document with no location.
    public static func flat(
        kind: AttachmentKind,
        kindLabel: String,
        name: String,
        text: String
    ) -> ExtractedDocument {
        ExtractedDocument(
            kind: kind,
            kindLabel: kindLabel,
            name: name,
            sections: [DocumentSection(text: text)],
            characterCount: text.count,
            text: text
        )
    }
}
