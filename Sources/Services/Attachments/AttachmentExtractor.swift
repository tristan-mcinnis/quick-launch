import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Failures

/// Why an attachment could not be read. Each case is one short line on the
/// chip (`chipLine`); the chip stays so the user sees what failed, and a
/// failed attachment never rides the request.
enum AttachmentFailure: Error, Equatable, Sendable {
    case passwordProtected
    case damaged
    /// A scanned PDF where OCR found no text either.
    case scannedNoText
    /// Over the size cap for its kind; carries the cap in bytes.
    case tooLarge(limit: Int)
    /// An Office file that would unpack past the ZIP caps (a zip bomb, or a
    /// part too big to read safely).
    case tooLargeUnpacked
    /// An iCloud file that did not arrive within the wait.
    case notDownloaded
    /// macOS privacy protection (or file permissions) refused the read.
    case accessDenied
    case missing
    /// The file's content is not what its name says ("Not a Word document").
    case wrongContent(ChatAttachmentKind)
    /// Text was read, but none of it is readable.
    case empty
    case folder
    /// A socket, device, or other thing that is not a plain file.
    case notRegularFile
    /// A kind v1 does not read; carries the whole line with its way out.
    case unsupported(String)
    case timedOut
    /// Any other read error.
    case unreadable
    // Links
    case invalidLink
    case redirectRefused
    case tooManyRedirects
    case httpStatus(Int)
    /// A link to a file type that is not read over the network.
    case linkContentType(String)
    case unreachable

    var chipLine: String {
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
        case .invalidLink: "Only http and https links can be read"
        case .redirectRefused: "The link leads to a page that cannot be read"
        case .tooManyRedirects: "The link redirects too many times"
        case .httpStatus(let status): "The page returned HTTP \(status)"
        case .linkContentType(let type): "This link is a \(type) file; download it and attach the file."
        case .unreachable: "Could not reach the page"
        }
    }

    private static func wrongContentLine(_ kind: ChatAttachmentKind) -> String {
        switch kind {
        case .pdf: "Not a PDF"
        case .word: "Not a Word document"
        case .powerpoint: "Not a PowerPoint file"
        case .excel: "Not an Excel file"
        case .html: "Not an HTML file"
        case .image, .screenshot: "Not an image"
        case .text, .markdown, .code, .selection: "Not a text file"
        case .link: "Not a web page"
        }
    }
}

// MARK: - Notes, phases, results

/// A fact about how the text was read, said on the chip and to the model.
enum AttachmentNote: Codable, Equatable, Hashable, Sendable {
    /// A scanned PDF read by OCR on this Mac: which pages (1-based), of how many.
    case ocr(pages: [Int], totalPages: Int)
    /// A workbook with custom date formats that stay serial numbers.
    case spreadsheetSerialDates
    /// A link whose body passed the download cap; the text is from the head.
    case linkBodyCut(limitBytes: Int)

    /// The chip's line, or nil when the note is for the model only.
    var chipLine: String? {
        switch self {
        case .ocr(let pages, let total): "OCR · \(Self.pagesPhrase(pages)) of \(total)"
        case .spreadsheetSerialDates: nil
        case .linkBodyCut(let limit): "first \(limit / (1_024 * 1_024)) MB of the page"
        }
    }

    /// The line inside the model block.
    var modelLine: String {
        switch self {
        case .ocr(let pages, let total):
            "[Scanned PDF: text read by OCR on this Mac, \(Self.pagesPhrase(pages)) of \(total).]"
        case .spreadsheetSerialDates:
            "[Dates may appear as spreadsheet serial numbers.]"
        case .linkBodyCut(let limit):
            "[Only the first \(limit / (1_024 * 1_024)) MB of the page was downloaded.]"
        }
    }

    /// "pages 1-10" for a run, "page 4" for one, "10 pages" otherwise.
    private static func pagesPhrase(_ pages: [Int]) -> String {
        guard let first = pages.first, let last = pages.last else { return "0 pages" }
        if pages.count == 1 { return "page \(first)" }
        if last - first + 1 == pages.count { return "pages \(first)-\(last)" }
        return "\(pages.count) pages"
    }
}

/// What a read in progress is doing, for the chip's detail.
enum AttachmentReadPhase: Equatable, Sendable {
    case downloadingFromICloud
    case reading
    case fetching(host: String)
    case recognizingText(page: Int, of: Int)

    var chipLine: String {
        switch self {
        case .downloadingFromICloud: "Downloading from iCloud…"
        case .reading: "Reading…"
        case .fetching(let host): "Fetching \(host)…"
        case .recognizingText(let page, let total): "OCR · page \(page) of \(total)…"
        }
    }
}

typealias AttachmentProgressHandler = @Sendable (AttachmentReadPhase) -> Void
/// On-device OCR of one image. The default is the app's Vision setup.
typealias AttachmentTextRecognizer = @Sendable (CGImage) async -> String

/// What reading one attachment gave: the reference the history keeps, and
/// the text (or the image) the request needs.
struct ExtractedAttachment: Equatable, Sendable {
    var ref: ChatAttachmentRef
    /// The text, already cut to the character cap. Nil for an image.
    var text: String?
    /// The image to send to the vision model. Nil for text.
    var image: QuickImageAttachment?
    /// The kind the model block names: "PDF", "Word document", "Swift source".
    var kindLabel: String
    var notes: [AttachmentNote]
    /// The bytes as read, for the archive. A fetched link keeps the raw body
    /// here, not only its extracted text. Nil when only text is available.
    var originalBytes: Data? = nil

    /// The chip's detail lines beyond the size: the cut, then the notes.
    var chipNotes: [String] {
        var lines: [String] = []
        if let truncation = ref.truncation { lines.append(truncation.summary) }
        lines += notes.compactMap(\.chipLine)
        return lines
    }
}

// MARK: - Document text before the cap

/// Text read from one document, before the character cap and NFKC.
struct DocumentText: Sendable {
    /// One page, slide, or sheet: its marker line and its text.
    struct Section: Sendable, Equatable {
        var marker: String?
        var body: String
    }

    /// A page, slide, sheet, or row cap that stopped the read.
    struct UnitCut: Sendable, Equatable {
        var unit: AttachmentTruncation.Unit
        var kept: Int
        var total: Int?
    }

    var sections: [Section]
    /// What one section is, for a paged document.
    var sectionUnit: AttachmentTruncation.Unit?
    /// Pages, slides, or sheets in the document, read or not.
    var unitCount: Int?
    var unitCut: UnitCut?
    var notes: [AttachmentNote] = []
    /// False for code, whose text is kept exactly.
    var normalizes = true

    init(
        sections: [Section],
        sectionUnit: AttachmentTruncation.Unit? = nil,
        unitCount: Int? = nil,
        unitCut: UnitCut? = nil,
        notes: [AttachmentNote] = [],
        normalizes: Bool = true
    ) {
        self.sections = sections
        self.sectionUnit = sectionUnit
        self.unitCount = unitCount
        self.unitCut = unitCut
        self.notes = notes
        self.normalizes = normalizes
    }

    /// A document with no units: one section, no marker.
    init(text: String, normalizes: Bool = true, notes: [AttachmentNote] = []) {
        self.init(sections: [Section(marker: nil, body: text)], notes: notes, normalizes: normalizes)
    }

    /// The final text: NFKC (unless code), line endings unified, sections
    /// joined, then the head kept up to `characterCap`. The cut is said in
    /// `truncation`. Throws `empty` when no section has readable text.
    func finished(
        characterCap: Int = AttachmentLimits.charactersPerFile
    ) throws -> (text: String, characterCount: Int, truncation: AttachmentTruncation?) {
        var pieces: [String] = []
        var sectionStarts: [Int] = []
        var total = 0
        var hasText = false
        let separator = "\n\n"
        for section in sections {
            let body = AttachmentTextCleaner.clean(section.body, normalizes: normalizes)
            if !body.isEmpty { hasText = true }
            let marker = section.marker.map { AttachmentTextCleaner.clean($0, normalizes: normalizes) }
            let piece = [marker, body.isEmpty ? nil : body].compactMap { $0 }.joined(separator: "\n")
            if !pieces.isEmpty { total += separator.count }
            sectionStarts.append(total)
            pieces.append(piece)
            total += piece.count
        }
        guard hasText else { throw AttachmentFailure.empty }
        let joined = pieces.joined(separator: separator)

        guard total > characterCap else {
            let truncation = unitCut.map {
                AttachmentTruncation(unit: $0.unit, keptUnits: $0.kept, totalUnits: $0.total)
            }
            return (joined, total, truncation)
        }

        let kept = String(joined.prefix(characterCap))
        var truncation = AttachmentTruncation(keptCharacters: characterCap, totalCharacters: total)
        if let sectionUnit, sections.count > 1 {
            let keptSections = sectionStarts.filter { $0 < characterCap }.count
            truncation.unit = sectionUnit
            truncation.keptUnits = keptSections
            truncation.totalUnits = unitCount ?? sections.count
        } else if let unitCut {
            truncation.unit = unitCut.unit
            truncation.keptUnits = unitCut.kept
            truncation.totalUnits = unitCut.total
        }
        return (kept, total, truncation)
    }
}

/// Normalisation every extracted text gets before it is cached, sent, or
/// searched.
enum AttachmentTextCleaner {
    /// NFKC (so a PDF's Kangxi radical U+2F42 reads as 文 and full-width
    /// letters as ASCII), `\r\n` and `\r` to `\n`, NUL bytes out, trailing
    /// white space trimmed. Code skips NFKC and keeps its text exactly
    /// apart from line endings.
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

// MARK: - The extractor

/// Reads one attachment, off the main actor: routes by content type,
/// holds the caps, normalises with NFKC, and reports each failure as one
/// chip line. A file is read once, when the user attaches it.
///
/// The heavy work runs in child tasks, so two attachments read at once;
/// the actor holds only its configuration. Every extractor checks for
/// cancellation between pages, slides, entries, and rows: Escape and the
/// 20-second limit stop a read at the next of those.
actor AttachmentExtractor {
    /// Written into each reference; a newer extractor reads the file again.
    static let version = 1

    private let gate: AttachmentFileGate
    private let linkReader: LinkAttachmentReader
    private let recognizeText: AttachmentTextRecognizer
    private let timeout: Duration

    init(
        gate: AttachmentFileGate = AttachmentFileGate(),
        linkReader: LinkAttachmentReader = LinkAttachmentReader(),
        recognizeText: @escaping AttachmentTextRecognizer = { image in
            await ScreenshotTextIndex.recognizeText(in: image)
        },
        timeout: Duration = AttachmentLimits.extractionTimeout
    ) {
        self.gate = gate
        self.linkReader = linkReader
        self.recognizeText = recognizeText
        self.timeout = timeout
    }

    /// Reads a file the user attached. Throws `AttachmentFailure`, or
    /// `CancellationError` when the read was cancelled.
    func extract(
        fileAt url: URL,
        progress: AttachmentProgressHandler? = nil
    ) async throws -> ExtractedAttachment {
        let gate = self.gate
        let recognizeText = self.recognizeText
        return try await Self.withTimeout(timeout) {
            try await Self.extractFile(url, gate: gate, recognizeText: recognizeText, progress: progress)
        }
    }

    /// Fetches a link once and reads it. Throws `AttachmentFailure`, or
    /// `CancellationError`.
    func extract(
        link url: URL,
        progress: AttachmentProgressHandler? = nil
    ) async throws -> ExtractedAttachment {
        let reader = linkReader
        let recognizeText = self.recognizeText
        return try await reader.read(url, recognizeText: recognizeText, progress: progress)
    }

    /// Runs `body`, or throws `timedOut` when it passes `limit`. Structured:
    /// the losing child is cancelled and joined before this returns.
    static func withTimeout<T: Sendable>(
        _ limit: Duration,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw AttachmentFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    // MARK: Files

    static func extractFile(
        _ url: URL,
        gate: AttachmentFileGate,
        recognizeText: AttachmentTextRecognizer,
        progress: AttachmentProgressHandler?
    ) async throws -> ExtractedAttachment {
        let resolved = try await gate.resolve(url, progress: progress)
        progress?(.reading)
        try Task.checkCancellation()
        let data = try gate.readData(resolved)
        let hash = sha256(data)
        let route = try AttachmentFileGate.confirm(resolved.route, data: data)

        let document: DocumentText
        switch route {
        case .image:
            let image = try AttachmentImageReader.image(from: data)
            let ref = ChatAttachmentRef(
                kind: .image,
                name: resolved.name,
                byteCount: resolved.byteCount,
                pixelWidth: image.pixelWidth,
                pixelHeight: image.pixelHeight
            )
            return ExtractedAttachment(ref: ref, text: nil, image: image, kindLabel: "Image", notes: [])
        case .pdf:
            document = try await PDFTextExtractor.extract(data: data, recognizeText: recognizeText, progress: progress)
        case .docx:
            document = try OOXMLTextExtractor.word(data: data)
        case .pptx:
            document = try OOXMLTextExtractor.powerPoint(data: data)
        case .xlsx:
            document = try OOXMLTextExtractor.excel(data: data)
        case .odt:
            document = try OOXMLTextExtractor.openDocument(data: data)
        case .doc, .rtf, .rtfd:
            document = try AttributedDocumentReader.read(route: route, data: data, packageURL: resolved.url)
        case .html:
            let html = PlainTextReader.decodeHTML(data)
            document = DocumentText(text: htmlText(html))
        case .plainText(let kind, _):
            let text: String
            do {
                text = try PlainTextReader.decode(data, fileURL: resolved.url)
            } catch {
                throw AttachmentFailure.wrongContent(kind)
            }
            document = DocumentText(text: text, normalizes: kind != .code)
        }
        try Task.checkCancellation()

        let finished = try document.finished()
        let ref = ChatAttachmentRef(
            kind: route.kind,
            name: resolved.name,
            byteCount: resolved.byteCount,
            pageCount: document.unitCount,
            characterCount: finished.characterCount,
            truncation: finished.truncation,
            contentHash: hash,
            extractorVersion: version,
            path: resolved.url.path
        )
        return ExtractedAttachment(
            ref: ref,
            text: finished.text,
            image: nil,
            kindLabel: route.label,
            notes: document.notes
        )
    }

    /// An HTML document as a title line, then its readable text.
    static func htmlText(_ html: String) -> String {
        let body = HTMLTextExtractor.text(from: html)
        guard let title = HTMLTextExtractor.title(from: html) else { return body }
        return body.isEmpty ? title : "\(title)\n\n\(body)"
    }

    /// SHA-256 of the source bytes, lowercase hex.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Images

/// Decodes an attached picture and re-encodes it for the vision model:
/// long side at most 2,048 px, PNG, or JPEG when the PNG is over 2 MB.
/// Re-encoding also drops the file's metadata (location, camera).
enum AttachmentImageReader {
    static func image(from data: Data) throws -> QuickImageAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw AttachmentFailure.wrongContent(.image) }

        let longSide = min(max(width, height), AttachmentLimits.imageLongSidePixels)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw AttachmentFailure.damaged }

        guard let png = encode(image, as: .png, quality: nil) else { throw AttachmentFailure.damaged }
        if png.count <= AttachmentLimits.imagePNGBytes {
            return QuickImageAttachment(data: png, mimeType: "image/png", pixelWidth: image.width, pixelHeight: image.height)
        }
        guard let jpeg = encode(image, as: .jpeg, quality: 0.85) else { throw AttachmentFailure.damaged }
        return QuickImageAttachment(data: jpeg, mimeType: "image/jpeg", pixelWidth: image.width, pixelHeight: image.height)
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// MARK: - doc, rtf, rtfd

/// `NSAttributedString` with the explicit document type, never
/// auto-detect: detection "succeeds" on the wrong format with empty or raw
/// output.
enum AttributedDocumentReader {
    /// `packageURL` is the `.rtfd` folder when the file is one; everything
    /// else reads from `data`.
    static func read(route: AttachmentRoute, data: Data, packageURL: URL? = nil) throws -> DocumentText {
        let type: NSAttributedString.DocumentType
        switch route {
        case .doc: type = .docFormat
        case .rtf: type = .rtf
        case .rtfd: type = .rtfd
        case .odt: type = .openDocument
        case .docx: type = .officeOpenXML
        default: throw AttachmentFailure.wrongContent(route.kind)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        let string: NSAttributedString
        do {
            if route == .rtfd, let packageURL,
               (try? packageURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                string = try NSAttributedString(url: packageURL, options: options, documentAttributes: nil)
            } else {
                string = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            }
        } catch {
            throw AttachmentFailure.damaged
        }
        // Attachment characters (U+FFFC) stand for pictures; they are not text.
        let text = string.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        return DocumentText(text: text)
    }
}
