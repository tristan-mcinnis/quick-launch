import CoreGraphics
import Foundation
import HouseChatCore

// MARK: - Failure

/// Why a document could not be read. Each case carries the one line a caller
/// can show; the extractor never throws a bare `NSError` for a known
/// condition.
public enum DocumentExtractionError: Error, Equatable, Sendable, LocalizedError {
    /// The file needs a password to open.
    case passwordProtected
    /// The file's structure is cut or broken.
    case damaged
    /// A scanned PDF where OCR found no text either.
    case scannedNoText
    /// Over the size cap for its kind; carries the cap in bytes.
    case tooLarge(limit: Int)
    /// An Office file that would unpack past the ZIP caps.
    case tooLargeUnpacked
    /// An iCloud file that did not arrive within the wait.
    case notDownloaded
    /// macOS privacy protection, or file permissions, refused the read.
    case accessDenied
    /// No such file.
    case missing
    /// The bytes are not what the name says ("Not a Word document").
    case wrongContent(AttachmentKind)
    /// Text was read, but none of it is readable.
    case empty
    /// A directory, not a file.
    case folder
    /// A socket, device, or other thing that is not a plain file.
    case notRegularFile
    /// A kind the reader does not support, with the caller's way out.
    case unsupported(String)
    /// The read passed the time limit.
    case timedOut
    /// Any other read error.
    case unreadable

    /// The one line a chip, a log, or an error alert shows.
    public var message: String {
        switch self {
        case .passwordProtected: "Password-protected; not read"
        case .damaged: "The file is damaged"
        case .scannedNoText: "No text found (scanned, OCR empty)"
        case .tooLarge(let limit): "Larger than \(limit / (1_024 * 1_024)) MB"
        case .tooLargeUnpacked: "Too large once unpacked; not read"
        case .notDownloaded: "Not downloaded"
        case .accessDenied: "macOS blocked access. Drop the file or use Files…"
        case .missing: "File not found"
        case .wrongContent(let kind): Self.wrongContentLine(kind)
        case .empty: "No readable text"
        case .folder: "Folders cannot be attached; drop the files."
        case .notRegularFile: "Only files can be attached"
        case .unsupported(let line): line
        case .timedOut: "Reading took too long"
        case .unreadable: "The file could not be read"
        }
    }

    public var errorDescription: String? { message }

    private static func wrongContentLine(_ kind: AttachmentKind) -> String {
        switch kind {
        case .pdf: "Not a PDF"
        case .word: "Not a Word document"
        case .powerpoint: "Not a PowerPoint file"
        case .excel: "Not an Excel file"
        case .html: "Not an HTML file"
        case .image, .screenshot: "Not an image"
        case .text, .markdown, .code, .selection: "Not a text file"
        case .link: "Not a web page"
        case .other: "Not a supported file"
        }
    }
}

// MARK: - Progress

/// What a read in progress is doing.
public enum DocumentReadPhase: Equatable, Sendable {
    case downloadingFromICloud
    case reading
    case recognizingText(page: Int, of: Int)

    /// The line a caller can show while it waits.
    public var message: String {
        switch self {
        case .downloadingFromICloud: "Downloading from iCloud…"
        case .reading: "Reading…"
        case .recognizingText(let page, let total): "OCR · page \(page) of \(total)…"
        }
    }
}

/// Called as a read passes its phases. Optional everywhere.
public typealias DocumentProgressHandler = @Sendable (DocumentReadPhase) -> Void

/// On-device OCR of one rendered image. The default is Apple Vision on this
/// Mac; tests and callers may inject their own.
public typealias DocumentTextRecognizer = @Sendable (CGImage) async -> String

// MARK: - Source

/// Where the bytes came from.
public enum DocumentSourceKind: String, Codable, Sendable, Equatable {
    /// A file on this Mac.
    case file
    /// Bytes handed in directly (a paste, a drop, or an adapter's read).
    case data
    /// The body of a web page the caller fetched. This module never fetches.
    case fetchedBody

    /// True when a caller fetched the bytes over the network.
    public var isRemote: Bool { self == .fetchedBody }
}

/// Source metadata kept with an extraction so original bytes can be found
/// again.
public struct DocumentSource: Sendable, Equatable {
    public var kind: DocumentSourceKind
    /// The display name, including its extension.
    public var name: String
    /// The file on this Mac, for `.file`.
    public var fileURL: URL?
    /// The source URL, for `.fetchedBody` (after redirects) or when a `.data`
    /// caller supplied one.
    public var url: URL?

    public init(kind: DocumentSourceKind, name: String, fileURL: URL? = nil, url: URL? = nil) {
        self.kind = kind
        self.name = name
        self.fileURL = fileURL
        self.url = url
    }
}

// MARK: - Image bytes

/// Re-encoded image bytes, safe to transmit: scaled to the long-side cap and
/// stripped of metadata. The original bytes stay untouched in
/// `DocumentExtraction.originalBytes`.
public struct DocumentImageBytes: Sendable, Equatable {
    public var data: Data
    /// "image/png" or "image/jpeg".
    public var mimeType: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(data: Data, mimeType: String, pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

// MARK: - Result

/// Everything one read produced: the shared schema record, the original bytes
/// exactly as they arrived, and (for a picture) the normalized bytes a model
/// may receive.
///
/// `originalBytes` is the caller's keep-all copy. Nothing in this module
/// mutates it, so an image keeps its EXIF and a document keeps its exact
/// bytes. `normalizedImage` is the derived, metadata-free copy for
/// transmission.
public struct DocumentExtraction: Sendable, Equatable {
    public var document: ExtractedDocument
    /// The original bytes, byte for byte.
    public var originalBytes: Data
    /// The normalized image, when the source was a picture.
    public var normalizedImage: DocumentImageBytes?
    public var source: DocumentSource

    public init(
        document: ExtractedDocument,
        originalBytes: Data,
        normalizedImage: DocumentImageBytes? = nil,
        source: DocumentSource
    ) {
        self.document = document
        self.originalBytes = originalBytes
        self.normalizedImage = normalizedImage
        self.source = source
    }

    public var name: String { document.name }

    /// False when a cap stopped the read short, so a caller never presents a
    /// partial read as the whole document.
    public var isComplete: Bool {
        guard document.truncation == nil, document.unitCut == nil else { return false }
        return !document.notes.contains { note in
            switch note.kind {
            case .partialExtraction, .unsupportedContent, .linkBodyCut: true
            default: false
            }
        }
    }

    /// The lead line of the read's limits, or nil when nothing was cut.
    public var limitSummary: String? { document.truncation?.summary }
}
