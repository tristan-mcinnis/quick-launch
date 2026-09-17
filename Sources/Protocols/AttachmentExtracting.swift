import Foundation
import HouseChatCore
import HouseChatDocuments

/// Where one attachment comes from. Every way to attach (Add Context, `@`,
/// a drop, `⌘V`, a URL in the question, a capture) resolves to one of these
/// and goes through `AttachmentTray.add(_:)`.
enum AttachmentSource: Sendable, Equatable {
    /// A file on this Mac: File…, Finder Selection, a drop, or a paste.
    case file(URL)
    /// A web page, fetched once when it is attached.
    case link(URL)
    /// A picture already in memory: a paste, a drop, or a capture. `kind`
    /// is `.image` or `.screenshot`. It is never written to disk.
    case image(QuickImageAttachment, name: String, kind: ChatAttachmentKind)
    /// Text selected in another app: a "Selection · Safari" chip.
    case selection(String, appName: String?)

    /// The kind the chip shows before the source is read. A file guesses
    /// from its extension; the extractor's reference has the last word.
    var provisionalKind: ChatAttachmentKind {
        switch self {
        case .file(let url): ChatAttachmentKind.guess(forFileAt: url)
        case .link: .link
        case .image(_, _, let kind): kind.isImage ? kind : .image
        case .selection: .selection
        }
    }

    /// The name the chip shows before the source is read.
    var provisionalName: String {
        switch self {
        case .file(let url):
            url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        case .link(let url):
            url.host() ?? url.absoluteString
        case .image(_, let name, _):
            name
        case .selection(_, let appName):
            appName.map { "Selection · \($0)" } ?? "Selection"
        }
    }

    /// The same file or page, for spotting a second attach of it.
    var identity: String? {
        switch self {
        case .file(let url): "file:" + url.standardizedFileURL.path
        case .link(let url): "link:" + url.absoluteString
        case .image, .selection: nil
        }
    }
}

/// What reading one source gave: the reference the history keeps, the text
/// the model reads (nil for an image), and the normalized image bytes.
///
/// The pipeline owns these three payload fields; the archive worker and the
/// UI worker bind to them:
/// - `originalBytes`: the bytes exactly as read (a link keeps its raw body).
/// - `normalizedImage`: the metadata-free image bytes a model may receive.
/// - `extractedDocument`: the shared `HouseChatCore` extraction, which drives
///   passage selection and citations.
struct AttachmentContent: Sendable, Equatable {
    var ref: ChatAttachmentRef
    var text: String?
    /// The bytes exactly as they were read. Handed to the archive so it
    /// never re-reads a path that may have changed underneath it; a
    /// fetched link keeps the raw body here, not only its extracted text.
    var originalBytes: Data?
    /// The normalized, metadata-free image the shared reader produced.
    var normalizedImage: DocumentImageBytes?
    /// The shared extraction, when the shared reader produced it. Drives
    /// passage selection and citations; nil for a link or a selection.
    var extractedDocument: ExtractedDocument?
    /// The kind the model block names ("PDF", "Swift source"); nil falls
    /// back to the kind's own name.
    var kindLabel: String?
    /// How the text was read (OCR pages, serial dates, a cut download),
    /// said to the model inside the block.
    var notes: [AttachmentNote]

    /// The Quick Launch in-memory image, derived from `normalizedImage` so
    /// the two can never disagree.
    var image: QuickImageAttachment? {
        get {
            normalizedImage.map {
                QuickImageAttachment(data: $0.data, mimeType: $0.mimeType, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
            }
        }
        set {
            normalizedImage = newValue.map {
                DocumentImageBytes(data: $0.data, mimeType: $0.mimeType, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
            }
        }
    }

    init(
        ref: ChatAttachmentRef,
        text: String? = nil,
        image: QuickImageAttachment? = nil,
        kindLabel: String? = nil,
        notes: [AttachmentNote] = [],
        originalBytes: Data? = nil,
        normalizedImage: DocumentImageBytes? = nil,
        extractedDocument: ExtractedDocument? = nil
    ) {
        self.ref = ref
        self.text = text
        self.originalBytes = originalBytes
        self.normalizedImage = normalizedImage ?? image.map {
            DocumentImageBytes(data: $0.data, mimeType: $0.mimeType, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
        }
        self.extractedDocument = extractedDocument
        self.kindLabel = kindLabel
        self.notes = notes
    }
}

/// Why a source could not be read, in the chip's words: "The file is
/// damaged", "Larger than 50 MB", "Keynote files cannot be read. Export to
/// PowerPoint or PDF."
struct AttachmentReadFailure: Error, Sendable, Equatable, LocalizedError {
    let line: String

    init(_ line: String) { self.line = line }

    var errorDescription: String? { line }

    static let tookTooLong = AttachmentReadFailure("Reading took too long")
    static let folder = AttachmentReadFailure("Folders cannot be attached; drop the files.")
}

/// Reads one source into text and a reference. The real reader is an actor
/// (WP-A's `AttachmentExtractor`), so the work runs off the main actor;
/// tests use a fake. A thrown `AttachmentReadFailure` is the chip's line;
/// any other error shows its `localizedDescription`. A reader stops when
/// its task is cancelled.
protocol AttachmentExtracting: Sendable {
    func content(for source: AttachmentSource) async throws -> AttachmentContent
}

extension ChatAttachmentKind {
    /// The kind a file most likely is, from its extension alone. Nothing is
    /// read; this only picks the chip's first glyph and counts images
    /// against the limit before the file is read.
    static func guess(forFileAt url: URL) -> ChatAttachmentKind {
        switch url.pathExtension.lowercased() {
        case "pdf": .pdf
        case "docx", "doc", "rtf", "rtfd", "odt": .word
        case "pptx": .powerpoint
        case "xlsx": .excel
        case "html", "htm", "xhtml": .html
        case "md", "markdown": .markdown
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp": .image
        case "swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "c", "h", "m", "mm",
             "cpp", "hpp", "java", "kt", "rb", "sh", "zsh", "css", "scss", "sql", "lua",
             "php", "cs", "r", "pl":
            .code
        default: .text
        }
    }
}
