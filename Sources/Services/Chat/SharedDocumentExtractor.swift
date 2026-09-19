import Foundation
import HouseChatCore
import HouseChatDocuments

/// Quick Launch's production attachment reader, built on the shared
/// `HouseChatDocuments.DocumentExtractor`.
///
/// Files go through the shared reader, which returns the shared schema, the
/// original bytes byte-for-byte, and the normalized image. Links stay with
/// the app-side reader because fetching is the caller's job (the shared
/// module never touches the network); selections and in-memory pictures keep
/// the app's in-memory path so no pixel is re-encoded on a paste.
struct SharedDocumentExtractor: AttachmentExtracting {
    let documents: DocumentExtractor
    let app: AttachmentExtractor

    init(
        documents: DocumentExtractor = DocumentExtractor(),
        app: AttachmentExtractor = AttachmentExtractor()
    ) {
        self.documents = documents
        self.app = app
    }

    func content(for source: AttachmentSource) async throws -> AttachmentContent {
        switch source {
        case .file(let url):
            do {
                return Self.content(try await documents.extract(fileURL: url))
            } catch let error as DocumentExtractionError {
                throw AttachmentReadFailure(error.message)
            }
        case .link, .image, .selection:
            var content = try await app.content(for: source)
            // The archive keeps the bytes as read; a link already carries its
            // raw body from the app reader, a selection and an in-memory
            // picture get theirs here so the archive never re-reads a path.
            if content.originalBytes == nil {
                switch source {
                case .image(let image, _, _): content.originalBytes = image.data
                case .selection(let text, _): content.originalBytes = Data(text.utf8)
                default: break
                }
            }
            return content
        }
    }

    // MARK: - Schema bridge

    /// The shared extraction as the thread's attachment content. The original
    /// bytes are the archive's copy; the model reads `document.text`.
    static func content(_ extraction: DocumentExtraction) -> AttachmentContent {
        let document = extraction.document
        let ref = ChatAttachmentRef(
            kind: ChatAttachmentKind(rawValue: document.kind.rawValue) ?? .text,
            name: document.name,
            byteCount: document.byteCount ?? extraction.originalBytes.count,
            pageCount: document.unitCount,
            characterCount: document.characterCount,
            truncation: truncation(for: document.truncation),
            contentHash: document.contentHash ?? SHA256Digest.hex(extraction.originalBytes),
            extractorVersion: document.extractorVersion ?? DocumentExtractor.version,
            path: document.path ?? extraction.source.fileURL?.path,
            url: extraction.source.url ?? document.url,
            pixelWidth: document.pixelWidth,
            pixelHeight: document.pixelHeight
        )
        let image = extraction.normalizedImage.map {
            DocumentImageBytes(
                data: $0.data,
                mimeType: $0.mimeType,
                pixelWidth: $0.pixelWidth,
                pixelHeight: $0.pixelHeight
            )
        }
        return AttachmentContent(
            ref: ref,
            text: document.text,
            kindLabel: document.kindLabel,
            notes: document.notes.compactMap(note(for:)),
            originalBytes: extraction.originalBytes,
            normalizedImage: image,
            extractedDocument: document
        )
    }

    static func truncation(for truncation: TextTruncation?) -> AttachmentTruncation? {
        guard let truncation else { return nil }
        return AttachmentTruncation(
            keptCharacters: truncation.keptCharacters,
            totalCharacters: truncation.totalCharacters,
            unit: truncation.unit.flatMap { AttachmentTruncation.Unit(rawValue: $0.rawValue) },
            keptUnits: truncation.keptUnits,
            totalUnits: truncation.totalUnits
        )
    }

    /// Only the notes the thread can draw have an app-side case; the rest are
    /// already carried by the truncation summary and the completeness flag.
    static func note(for note: DocumentNote) -> AttachmentNote? {
        switch note.kind {
        case .ocr:
            return .ocr(pages: note.pages ?? [], totalPages: note.totalPages ?? 0)
        case .spreadsheetSerialDates:
            return .spreadsheetSerialDates
        case .linkBodyCut:
            return note.limitBytes.map { .linkBodyCut(limitBytes: $0) }
        case .partialExtraction, .unsupportedContent, .other:
            return nil
        }
    }
}
