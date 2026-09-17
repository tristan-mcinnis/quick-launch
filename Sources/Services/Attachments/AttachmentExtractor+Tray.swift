import Foundation

/// The tray's reader: the extractor reads files and links, a picture
/// already in memory becomes its reference as it is, and a selection is
/// cleaned and capped like any other text. Each failure reaches the chip as
/// its one line.
extension AttachmentExtractor: AttachmentExtracting {
    func content(for source: AttachmentSource) async throws -> AttachmentContent {
        do {
            switch source {
            case .file(let url):
                return AttachmentContent(try await extract(fileAt: url))
            case .link(let url):
                return AttachmentContent(try await extract(link: url))
            case .image(let image, let name, let kind):
                return Self.imageContent(image, name: name, kind: kind)
            case .selection(let text, let appName):
                return try Self.selectionContent(text, appName: appName)
            }
        } catch let failure as AttachmentFailure {
            throw AttachmentReadFailure(failure.chipLine)
        }
    }

    /// A pasted, dropped, or captured picture: a reference with its pixel
    /// size, and the pixels in memory only.
    static func imageContent(
        _ image: QuickImageAttachment,
        name: String,
        kind: ChatAttachmentKind
    ) -> AttachmentContent {
        let ref = ChatAttachmentRef(
            kind: kind.isImage ? kind : .image,
            name: name,
            byteCount: image.data.count,
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight
        )
        // The captured or pasted bytes are the exact original submission, so
        // the archive keeps them rather than re-reading anything.
        return AttachmentContent(
            ref: ref,
            image: image,
            kindLabel: kind == .screenshot ? "Screenshot" : "Image",
            originalBytes: image.data
        )
    }

    /// Text selected in another app, as a text attachment: NFKC, the
    /// per-attachment cap, and a hash of what was selected.
    static func selectionContent(_ text: String, appName: String?) throws -> AttachmentContent {
        let finished = try DocumentText(text: text).finished()
        let ref = ChatAttachmentRef(
            kind: .selection,
            name: appName.map { "Selection · \($0)" } ?? "Selection",
            characterCount: finished.characterCount,
            truncation: finished.truncation,
            contentHash: sha256(Data(text.utf8)),
            extractorVersion: version
        )
        return AttachmentContent(ref: ref, text: finished.text, kindLabel: "Selected text")
    }
}

extension AttachmentContent {
    /// What the extractor read, as the tray keeps it.
    init(_ extracted: ExtractedAttachment) {
        self.init(
            ref: extracted.ref,
            text: extracted.text,
            image: extracted.image,
            kindLabel: extracted.kindLabel,
            notes: extracted.notes,
            originalBytes: extracted.originalBytes
        )
    }
}
