import Foundation

/// Turns one row of the Clipboard History catalog into an attachment, and
/// narrows the catalog by a typed query for the Add Context submenu.
///
/// It reuses the existing `ClipboardHistoryStore` catalog: that store has
/// already dropped concealed and transient copies, written its blobs
/// owner-only, and never keeps anything the pasteboard marked private. This
/// helper only maps a catalog row the store chose to keep onto the one
/// `AttachmentSource` the tray already knows how to read. It never touches
/// the pasteboard, and it adds no store of its own.
enum ClipboardHistoryAttachments {
    /// The chip label a clipboard-sourced text selection carries, so it is
    /// never confused with a live selection from an app.
    static let clipboardAppName = "Clipboard"

    /// How many files a clipboard copy may attach at once. The same bound the
    /// Finder Selection capture uses, so a multi-file copy behaves the same
    /// wherever it entered. The tray's own per-message cap still applies on
    /// top and reports itself.
    static let maximumFiles = AttachmentLimits.finderSelectionFiles

    /// Every attachment a stored payload makes, never silently dropping all
    /// but one of several files. Returns an empty array when the payload holds
    /// nothing attachable (an empty or unreadable row).
    ///
    /// Precedence matches the payload's own overlays: an image representation
    /// (a copied picture or screenshot) wins over its optional text, then
    /// every copied file URL (bounded by `maximumFiles`), then plain text. A
    /// binary `.data` copy is never read as text: with no real text form it
    /// attaches nothing rather than inventing a value.
    static func sources(for payload: ClipboardPayload) -> [AttachmentSource] {
        if let data = payload.imageData,
           let mimeType = payload.imageMimeType,
           let image = ClipboardImageReader.attachment(data: data, mimeType: mimeType) {
            return [.image(image, name: imageName(for: payload), kind: .image)]
        }
        let files = validFileSources(for: payload)
        if !files.isEmpty {
            return Array(files.prefix(maximumFiles))
        }
        guard payload.kind != .data,
              !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return [.clipboard(payload.text, appName: nil)]
    }

    /// File URLs that name a real local file path, in order. A non-file URL is
    /// dropped here; the caller reports how many file URLs did not become a
    /// source instead of silently ignoring them.
    private static func validFileSources(for payload: ClipboardPayload) -> [AttachmentSource] {
        payload.fileURLs.compactMap { urlString -> AttachmentSource? in
            guard let path = ClipboardFileReference.localFilePath(from: urlString) else { return nil }
            return .file(URL(fileURLWithPath: path))
        }
    }

    /// A stable name for a copied picture's chip. The image's own pixel size
    /// is its detail; the name only has to be recognisable in a list.
    /// File URLs that did not become an attachment source: a URL that names no
    /// local file, or one past the `maximumFiles` bound. The caller says so
    /// rather than leaving the user to notice a missing chip.
    static func omittedFileCount(for payload: ClipboardPayload) -> Int {
        let valid = validFileSources(for: payload).count
        let invalid = max(0, payload.fileURLs.count - valid)
        let overBound = max(0, valid - maximumFiles)
        return invalid + overBound
    }

    static func imageName(for payload: ClipboardPayload) -> String {
        if let width = payload.imageWidth, let height = payload.imageHeight {
            return "Clipboard image \(width)×\(height)"
        }
        return "Clipboard image"
    }

    /// The clipboard catalog rows that match `query`, in the store's own
    /// order, with a pinned row first. Matching is the launcher's own folded
    /// fuzzy match over the row's title and its search keywords (which
    /// already include the kind words, a file name, pinned, and OCR text),
    /// so a type or a pinned entry narrows the list the way search always
    /// does.
    static func rows(
        from entries: [LauncherCatalogItem],
        query: String
    ) -> [LauncherCatalogItem] {
        let live = entries.filter { $0.kind == .clipboard }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return live.sorted { $0.isPinned && !$1.isPinned }
        }
        let folded = FuzzyMatcher.fold(trimmed)
        return live
            .compactMap { item -> (LauncherCatalogItem, Int, Bool)? in
                let score = [
                    FuzzyMatcher.score(foldedQuery: folded, foldedCandidate: FuzzyMatcher.fold(item.title)),
                    FuzzyMatcher.score(foldedQuery: folded, foldedCandidate: FuzzyMatcher.fold(item.keywords)),
                ].compactMap { $0 }.max()
                guard let score else { return nil }
                return (item, score, item.isPinned)
            }
            .sorted { lhs, rhs in
                if lhs.2 != rhs.2 { return lhs.2 }
                return lhs.1 > rhs.1
            }
            .map(\.0)
    }
}
