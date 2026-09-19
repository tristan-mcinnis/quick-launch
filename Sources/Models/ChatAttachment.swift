import Foundation
import HouseChatDocuments

/// What an attachment is. Decides the extractor, the chip's glyph and
/// detail, and the `kind` the model block names.
enum ChatAttachmentKind: String, Codable, Sendable, CaseIterable {
    case pdf
    /// docx, and doc, rtf, rtfd, odt.
    case word
    /// pptx.
    case powerpoint
    /// xlsx.
    case excel
    /// An HTML file on this Mac. A fetched page is a `link`.
    case html
    case text
    case markdown
    /// A source file. Its text is kept exactly (no NFKC).
    case code
    /// A picture the user attached or pasted.
    case image
    /// A capture of the screen, a window, or an area.
    case screenshot
    /// A web page fetched once, when it was attached.
    case link
    /// Text selected in another app.
    case selection

    /// Images and screenshots are never written anywhere: their reference
    /// keeps a display name and a pixel size, and nothing else.
    var isImage: Bool { self == .image || self == .screenshot }
}

/// How much of an attachment's text was kept. The head is always kept,
/// never a middle sample, and the cut is said twice: on the chip
/// (`summary`) and to the model inside the block (`modelNote`).
struct AttachmentTruncation: Codable, Sendable, Equatable, Hashable {
    /// The part of a document a unit cap counts.
    enum Unit: String, Codable, Sendable {
        case page
        case slide
        case sheet
        case row

        fileprivate var plural: String {
            switch self {
            case .page: "pages"
            case .slide: "slides"
            case .sheet: "sheets"
            case .row: "rows"
            }
        }
    }

    /// Characters kept, set when the text was cut at a character cap.
    var keptCharacters: Int?
    /// Characters the whole text had, next to `keptCharacters`.
    var totalCharacters: Int?
    /// The unit a page, slide, sheet, or row cap stopped at.
    var unit: Unit?
    /// Units read, from the first, next to `unit`.
    var keptUnits: Int?
    /// Units the document has, next to `unit`.
    var totalUnits: Int?

    init(
        keptCharacters: Int? = nil,
        totalCharacters: Int? = nil,
        unit: Unit? = nil,
        keptUnits: Int? = nil,
        totalUnits: Int? = nil
    ) {
        self.keptCharacters = keptCharacters
        self.totalCharacters = totalCharacters
        self.unit = unit
        self.keptUnits = keptUnits
        self.totalUnits = totalUnits
    }

    /// The facts in one line, for the chip and its tooltip: "first 200,000
    /// of 612,000 characters, pages 1-120 of 300".
    var summary: String {
        var parts: [String] = []
        if let kept = keptCharacters {
            if let total = totalCharacters {
                parts.append("first \(Self.count(kept)) of \(Self.count(total)) characters")
            } else {
                parts.append("first \(Self.count(kept)) characters")
            }
        }
        if let unit, let kept = keptUnits {
            if let total = totalUnits {
                parts.append("\(unit.plural) 1-\(Self.count(kept)) of \(Self.count(total))")
            } else {
                parts.append("\(unit.plural) 1-\(Self.count(kept))")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// The line inside the model block: "[Truncated: the first 200,000 of
    /// 612,000 characters, pages 1-120 of 300.]"
    var modelNote: String {
        let facts = summary
        return facts.isEmpty ? "[Truncated.]" : "[Truncated: the \(facts).]"
    }

    /// A count with thousands separators, the same on every Mac, so the
    /// chip and the model block read one way whatever the system language.
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }
}

/// What the chat history keeps for one attachment: a reference, never the
/// text. The extracted text lives in memory for the app session
/// (`AttachmentSessionStore`), keyed by `contentHash` and
/// `extractorVersion`. An image or screenshot keeps
/// its kind, a display name, and its pixel size only: no path, no hash, no
/// URL, and no pixels. The init and the decoder both hold that rule, and
/// the fields it covers are constants.
struct ChatAttachmentRef: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: UUID
    let kind: ChatAttachmentKind
    /// The file name, or a link's page title (its host when it has none).
    var name: String
    /// Size of the source: the file, or the fetched body of a link.
    var byteCount: Int?
    /// Pages of a PDF, slides of a deck, sheets of a workbook.
    var pageCount: Int?
    /// Characters of extracted text, before any cut.
    var characterCount: Int?
    /// Set when the text was cut to a cap.
    var truncation: AttachmentTruncation?
    /// SHA-256 of the source bytes, lowercase hex. Nil for images.
    let contentHash: String?
    /// The extractor that made the cached text; a newer one reads again.
    var extractorVersion: Int?
    /// The file on this Mac, for reading again, Open, and pi. Files only.
    let path: String?
    /// The final URL after redirects. Links only.
    let url: URL?
    /// Pixel size of an image or screenshot, for the chip's detail.
    var pixelWidth: Int?
    var pixelHeight: Int?
    var addedAt: Date

    /// For an image or screenshot, `contentHash`, `extractorVersion`,
    /// `path`, and `url` are dropped, so no reference can point back to
    /// the pixels.
    init(
        id: UUID = UUID(),
        kind: ChatAttachmentKind,
        name: String,
        byteCount: Int? = nil,
        pageCount: Int? = nil,
        characterCount: Int? = nil,
        truncation: AttachmentTruncation? = nil,
        contentHash: String? = nil,
        extractorVersion: Int? = nil,
        path: String? = nil,
        url: URL? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        addedAt: Date = Date()
    ) {
        let keepsSource = !kind.isImage
        self.id = id
        self.kind = kind
        self.name = name
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.characterCount = characterCount
        self.truncation = truncation
        self.contentHash = keepsSource ? contentHash : nil
        self.extractorVersion = keepsSource ? extractorVersion : nil
        self.path = keepsSource ? path : nil
        self.url = keepsSource ? url : nil
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, byteCount, pageCount, characterCount, truncation
        case contentHash, extractorVersion, path, url, pixelWidth, pixelHeight, addedAt
    }

    /// Goes through `init`, so a stored image reference that names a path
    /// or a hash loads without it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            kind: try c.decode(ChatAttachmentKind.self, forKey: .kind),
            name: try c.decode(String.self, forKey: .name),
            byteCount: try c.decodeIfPresent(Int.self, forKey: .byteCount),
            pageCount: try c.decodeIfPresent(Int.self, forKey: .pageCount),
            characterCount: try c.decodeIfPresent(Int.self, forKey: .characterCount),
            truncation: try c.decodeIfPresent(AttachmentTruncation.self, forKey: .truncation),
            contentHash: try c.decodeIfPresent(String.self, forKey: .contentHash),
            extractorVersion: try c.decodeIfPresent(Int.self, forKey: .extractorVersion),
            path: try c.decodeIfPresent(String.self, forKey: .path),
            url: try c.decodeIfPresent(URL.self, forKey: .url),
            pixelWidth: try c.decodeIfPresent(Int.self, forKey: .pixelWidth),
            pixelHeight: try c.decodeIfPresent(Int.self, forKey: .pixelHeight),
            addedAt: try c.decode(Date.self, forKey: .addedAt)
        )
    }

    /// A link's host, for the chip's detail and chat search.
    var host: String? { url?.host() }
}

/// Every attachment cap in one table, so the extractors, the tray, the
/// request composer, the cache, and the tests read the same numbers.
enum AttachmentLimits {
    // MARK: Count per message

    static let attachmentsPerMessage = 10
    static let imagesPerMessage = 6
    /// Files read from one Finder Selection.
    static let finderSelectionFiles = 20

    // MARK: Source size

    static let documentBytes = 50 * 1_024 * 1_024
    static let imageBytes = ClipboardImageReader.maximumBytes
    static let textFileBytes = 5 * 1_024 * 1_024

    // MARK: Text

    /// Extracted characters retained per file, before the request ceilings.
    /// The shared reader's own cap is the single source of truth
    /// (`docs/chat-harmonization-plan-20260917.md`: retain up to 2 million
    /// characters per file, then trim to the request ceilings below).
    static let charactersPerFile = DocumentExtractionConfiguration.standard.maximumCharacters
    /// Hard cap for one attachment's text *in one request* (about 60 k tokens).
    static let charactersPerAttachment = 200_000
    /// Hard cap across one message's attachments.
    static let charactersPerMessage = 400_000
    /// A NUL byte in this many leading bytes means "not a text file".
    static let binaryCheckBytes = 8 * 1_024

    // MARK: Documents

    static let pdfPages = 300
    /// Pages OCR reads from a scanned PDF, first pages without text first.
    static let ocrPages = 10
    /// A page with fewer characters than this counts as scanned; a PDF is a
    /// scan when at least half its pages do.
    static let scannedPageCharacters = 20
    /// Long side a scanned page is rendered at for OCR.
    static let ocrRenderPixels = 2_000
    static let slides = 300
    static let sheets = 10
    static let rowsPerSheet = 5_000
    static let columnsPerSheet = 100

    // MARK: ZIP (docx, pptx, xlsx)

    static let zipEntries = 5_000
    /// Enforced while inflating; the header's size is never trusted.
    static let zipEntryOutputBytes = 16 * 1_024 * 1_024
    static let zipArchiveOutputBytes = 64 * 1_024 * 1_024
    /// An entry is refused when its declared ratio is over this and its
    /// output is over `zipRatioFloorBytes`.
    static let zipDeclaredRatio = 200
    static let zipRatioFloorBytes = 1 * 1_024 * 1_024

    // MARK: Images

    /// Long side an image is scaled down to before it is sent.
    static let imageLongSidePixels = 2_048
    /// An encoded image over this size is sent as JPEG, not PNG.
    static let imagePNGBytes = 2 * 1_024 * 1_024

    // MARK: Time

    static let extractionTimeout: Duration = .seconds(20)

    // MARK: Links

    static let linkBodyBytes = 5 * 1_024 * 1_024
    static let linkTotalTimeout: Duration = .seconds(15)
    static let linkRequestTimeout: Duration = .seconds(10)
    static let linkRedirects = 5
    static let charactersPerLink = 100_000
    /// A page with less readable text than this takes the one VPS retry.
    static let thinPageCharacters = 200

    // MARK: Context budget

    /// Share of the answering model's character limit attachments may use.
    static let contextShare = 0.6
    /// An older attachment is cut to at least this head before it becomes a
    /// one-line stub.
    static let headExcerptCharacters = 4_000
    /// Longest attachment name in a model block's attributes.
    static let blockNameCharacters = 120

    // MARK: Session store

    /// Characters of extracted text the app keeps in memory for the session,
    /// across every chat; past it the least recently used text goes first.
    /// About ten attachments at their hard cap.
    static let sessionTextCharacters = 2_000_000
    /// Bytes of attached images the app keeps in memory for the session, so
    /// a follow-up can send an image with its own turn again.
    static let sessionImageBytes = 64 * 1_024 * 1_024

    // MARK: Cache (built, off: see `AttachmentSessionStore.attachmentCacheEnabled`)

    /// Cached text expires this long after its last use.
    static let cacheLifetime: Duration = .seconds(7 * 24 * 60 * 60)
    static let cacheBytes = 100 * 1_024 * 1_024
}
