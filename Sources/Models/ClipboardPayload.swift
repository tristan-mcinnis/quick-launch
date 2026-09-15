import AppKit
import Foundation
import UniformTypeIdentifiers

/// What a copied clipboard entry is. Decides title, preview, and restore
/// behaviour. Every entry keeps a plain-text fallback for search and preview
/// even when the primary representation is an image or rich content.
enum ClipboardPayloadKind: String, Codable, Sendable, Equatable {
    case text
    case image
    case richText
    case fileURL
    case data
}

/// One representation on one pasteboard item: a pasteboard type and its bytes.
struct ClipboardRawItem: Codable, Sendable, Equatable {
    let type: String
    let data: Data
}

/// The full contents of one clipboard copy, preserved faithfully.
///
/// `items` is the authoritative record: one element per pasteboard item, each
/// an ordered list of `ClipboardRawItem` (type → bytes). This keeps multiple
/// Finder files, a PDF, and custom formats alongside text or an image without
/// dropping any representation. Restore rebuilds an `[NSPasteboardItem]` from
/// it, so item boundaries and every representation come back.
///
/// For entries loaded from the history store, `items` is nil: only the small
/// metadata (kind, text, dimensions, file URLs, `blobKey`) is held in memory
/// and the heavy bytes live in an owner-only blob file keyed by `blobKey`.
/// The store materializes `items` on demand via `ClipboardHistoryStore.payload(for:)`;
/// `write(to:)` and the image/rich preview accessors need the loaded items.
///
/// Only the history store persists this; AI-request attachments remain on the
/// ephemeral `QuickImageAttachment` path and are never written to disk.
struct ClipboardPayload: Sendable, Equatable {
    var kind: ClipboardPayloadKind
    /// Always the plain-text form of the copy (may be empty for images).
    var text: String
    /// Derived image dimensions for preview (from the first image representation).
    var imageWidth: Int?
    var imageHeight: Int?
    /// Every file URL on the copy, so a multi-file Finder selection is kept.
    var fileURLs: [String] = []
    /// Content hash identifying the owner-only blob that holds `items`. Nil for
    /// plain-text entries (and for the in-memory capture form before storage).
    var blobKey: String?
    /// First representation type, for the ".data" row title/search.
    var firstType: String?
    /// The faithful pasteboard items. Nil when this is the store's display form
    /// (bytes are in the blob) or for a legacy plain-text entry.
    var items: [[ClipboardRawItem]]?

    init(
        kind: ClipboardPayloadKind,
        text: String,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        fileURLs: [String] = [],
        blobKey: String? = nil,
        firstType: String? = nil,
        items: [[ClipboardRawItem]]? = nil
    ) {
        self.kind = kind
        self.text = text
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fileURLs = fileURLs
        self.blobKey = blobKey
        self.firstType = firstType
        self.items = items
    }

    /// Per-entry and per-representation bounds. Every copy bounds the total it
    /// captures, an image, and rich text, so the metadata and blobs cannot balloon.
    static let maximumEntryBytes = 20 * 1_024 * 1_024
    static let maximumImageBytes = 12 * 1_024 * 1_024
    static let maximumRichBytes = 5 * 1_024 * 1_024
    static let maximumTextBytes = 200_000

    /// Byte footprint of the raw representations used by the history store's
    /// total-bytes budget. Counts the faithful items, not the derived overlay.
    var estimatedByteSize: Int {
        var total = text.utf8.count
        for item in items ?? [] {
            for rep in item {
                total += rep.data.count
            }
        }
        return total
    }

    // MARK: Derived preview fields

    private var imageRepresentation: (data: Data, mimeType: String)? {
        guard let items else { return nil }
        for item in items {
            for rep in item {
                guard let ut = UTType(rep.type), ut.conforms(to: .image) else { continue }
                return (rep.data, ut.preferredMIMEType ?? "image")
            }
        }
        return nil
    }

    var imageData: Data? { imageRepresentation?.data }

    var imageMimeType: String? { imageRepresentation?.mimeType }

    var hasImageRepresentation: Bool { imageRepresentation != nil }

    private func representationData(for rawType: NSPasteboard.PasteboardType) -> Data? {
        for item in items ?? [] {
            for rep in item where rep.type == rawType.rawValue {
                return rep.data
            }
        }
        return nil
    }

    var rtf: Data? { representationData(for: .rtf) }

    var html: Data? { representationData(for: .html) }

    /// True when the copy is plain text with no non-text representation (image,
    /// rich text, file, or a custom type). Plain-text entries ride the string
    /// pasteboard seam and need no blob; everything else must write the full
    /// payload so the original representation comes back.
    var isPlainTextOnly: Bool {
        if let items {
            for item in items {
                for rep in item {
                    if !Self.isTextishType(rep.type) { return false }
                }
            }
            return true
        }
        // Store display form: no blob means it was plain text.
        return blobKey == nil && kind == .text
    }

    private static func isTextishType(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower == NSPasteboard.PasteboardType.string.rawValue.lowercased()
            || lower.contains("plain-text")
            || lower.contains("utf16")
            || lower.contains("utf8")
            || lower == "public.text"
    }

    // MARK: Capture

    /// Builds a payload from a pasteboard, preserving every item and
    /// representation. Returns nil when the pasteboard holds nothing worth
    /// keeping or when the copy would exceed the per-entry bounds.
    @MainActor
    static func extract(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        guard let sourceItems = pasteboard.pasteboardItems, !sourceItems.isEmpty else {
            return nil
        }

        let ignored = ignoredPasteboardTypes.union(["com.apple.is-remote-clipboard"])
        var rawItems: [[ClipboardRawItem]] = []
        var text: String?
        var imageRep: (data: Data, mimeType: String)?
        var richBytes = 0
        var fileURLs: [String] = []

        for sourceItem in sourceItems {
            var reps: [ClipboardRawItem] = []
            var oversized = false
            for type in sourceItem.types {
                let raw = type.rawValue
                guard !ignored.contains(raw),
                      !raw.localizedCaseInsensitiveContains("promise"),
                      let data = sourceItem.data(forType: type),
                      !data.isEmpty
                else { continue }
                // Per-representation caps: reject the whole copy if an image or
                // rich text blob is too big (covers the TIFF path too, since
                // it is bounded by the same raw bytes).
                if Self.isImageTypeIdentifier(raw), data.count > maximumImageBytes {
                    oversized = true
                    break
                }
                if Self.isRichTextType(raw) {
                    if data.count > maximumRichBytes { oversized = true; break }
                    richBytes += data.count
                }
                reps.append(ClipboardRawItem(type: raw, data: data))
            }
            if oversized { return nil }
            if reps.isEmpty { continue }

            rawItems.append(reps)
            if text == nil, let value = sourceItem.string(forType: .string), !value.isEmpty {
                text = value
            }
            if imageRep == nil {
                imageRep = Self.imageRepresentation(in: reps)
            }
            if let value = sourceItem.string(forType: .fileURL), !value.isEmpty {
                fileURLs.append(value)
            }
        }

        guard !rawItems.isEmpty else { return nil }

        let totalBytes = rawItems.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } }
        guard totalBytes <= maximumEntryBytes else { return nil }

        var width: Int?
        var height: Int?
        if let imageRep {
            let dimensions = Self.imageDimensions(data: imageRep.data)
            width = dimensions?.0
            height = dimensions?.1
        }

        let textValue = text ?? ""
        let kind = Self.kind(forText: textValue, hasImage: imageRep != nil, hasRich: richBytes > 0, hasFiles: !fileURLs.isEmpty)
        var payload = ClipboardPayload(
            kind: kind,
            text: textValue,
            imageWidth: width,
            imageHeight: height,
            fileURLs: fileURLs,
            firstType: rawItems.flatMap { $0 }.first?.type,
            items: rawItems
        )
        payload.blobKey = payload.isPlainTextOnly ? nil : StableIdentifier.make(rawItems)
        return payload
    }

    private static func kind(forText text: String, hasImage: Bool, hasRich: Bool, hasFiles: Bool) -> ClipboardPayloadKind {
        if hasFiles { return .fileURL }
        if hasImage { return .image }
        if hasRich { return .richText }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text }
        return .data
    }

    // MARK: Restore

    /// Rebuilds the pasteboard as an `[NSPasteboardItem]`, preserving item
    /// boundaries and every representation. Returns false (and leaves the
    /// pasteboard untouched) when there is nothing to write, so a missing blob
    /// never clears the user's clipboard. Plain-text entries write their text.
    /// Requires `items` to be loaded for image/rich/file/custom content; the
    /// store materializes them from the blob first. Image writes are marked
    /// self-made so the next overlay open does not offer the app's own paste
    /// buffer back.
    @MainActor
    @discardableResult
    func write(to pasteboard: NSPasteboard = .general) -> Bool {
        if let items, !items.isEmpty {
            pasteboard.clearContents()
            let nsItems: [NSPasteboardItem] = items.map { reps in
                let item = NSPasteboardItem()
                for rep in reps {
                    item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
                }
                return item
            }
            pasteboard.writeObjects(nsItems)
            if hasImageRepresentation {
                ClipboardImageReader.suppressAutoOffer(for: pasteboard)
            }
            return true
        }
        if !text.isEmpty {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return true
        }
        // Nothing to write (e.g. an image whose blob is missing): leave the
        // pasteboard untouched and report failure to the caller.
        return false
    }

    // MARK: Helpers

    private static func imageRepresentation(in reps: [ClipboardRawItem]) -> (data: Data, mimeType: String)? {
        for rep in reps {
            guard let ut = UTType(rep.type), ut.conforms(to: .image) else { continue }
            return (rep.data, ut.preferredMIMEType ?? "image")
        }
        return nil
    }

    static func isImageTypeIdentifier(_ raw: String) -> Bool {
        UTType(raw)?.conforms(to: .image) == true
    }

    private static func isRichTextType(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower == "public.rtf" || lower == "public.html"
    }

    private static func imageDimensions(data: Data) -> (Int, Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    /// Pasteboard markers that mean "do not record": password managers mark
    /// secrets as concealed, and transient/auto-generated content is not a
    /// deliberate user copy. Honouring them keeps passwords out of the history.
    nonisolated private static let ignoredPasteboardTypes: Set<String> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType").rawValue,
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType").rawValue,
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType").rawValue,
    ]
}

/// The small, owner-only JSON form of a clipboard entry's payload. No bytes are
/// stored here; `blobKey` points at the blob file holding the raw items, and
/// `byteSize` is the footprint used for the history's byte budget.
struct StoredPayloadMeta: Codable, Sendable, Equatable {
    var kind: ClipboardPayloadKind
    var imageWidth: Int?
    var imageHeight: Int?
    var fileURLs: [String] = []
    /// Total captured footprint (text + raw items) for the byte budget.
    var byteSize: Int
    /// Content hash of the blob file, or nil for plain-text entries.
    var blobKey: String?
    /// First representation type, used for the ".data" row title/search.
    var firstType: String?
    /// Text recognized from a copied image (Apple Vision), persisted for search
    /// only. Never alters the payload or the restored image.
    var ocrText: String? = nil
}
