import AppKit
import Foundation
import UniformTypeIdentifiers

/// Clipboard-history actions that need more than a paste: reading text or a
/// code from a copied image, pasting only the plain-text form, attaching an
/// entry to the question draft, renaming an entry, annotating a saved
/// screenshot, and saving an app-made capture to disk.
///
/// Additive: these live beside the existing dispatch and reuse the same
/// pasteboard, selection and attachment seams. Nothing here sends, overwrites
/// an original, or writes outside the app's own support folder.
extension QuickViewModel {

    // MARK: - Reading text and codes out of an image

    /// Copy the text inside a copied image or a saved screenshot.
    @discardableResult
    func copyTextFromImage(_ item: LauncherCatalogItem) async -> Bool {
        guard let data = await imageBytes(for: item) else {
            errorMessage = "There is no image here to read text from."
            requestInputFocus()
            return false
        }
        let mode = item.kind == .screenshot ? settings.screenshotOCRMode : settings.clipboardHistoryOCRMode
        let text = await ClipboardTextRecognition.text(inImage: data, mode: mode)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "No text was found in that image."
            requestInputFocus()
            return false
        }
        pasteboard.writeString(trimmed)
        markJustCopied()
        return true
    }

    /// Copy the first machine-readable code (a QR code and the other barcode
    /// types Vision reads) inside a copied image or a saved screenshot.
    @discardableResult
    func copyQRCode(from item: LauncherCatalogItem) async -> Bool {
        guard let data = await imageBytes(for: item) else {
            errorMessage = "There is no image here to read a code from."
            requestInputFocus()
            return false
        }
        guard let code = await ClipboardTextRecognition.codeString(inImage: data), !code.isEmpty else {
            errorMessage = "No QR code was found in that image."
            requestInputFocus()
            return false
        }
        pasteboard.writeString(code)
        markJustCopied()
        return true
    }

    /// The image bytes for a clipboard image entry (inline or a file
    /// reference) or a saved image screenshot. Nil for a video or when the
    /// bytes are gone.
    func imageBytes(for item: LauncherCatalogItem) async -> Data? {
        switch item.kind {
        case .clipboard:
            if let payload = item.clipboardPayload, payload.kind == .image {
                let full = await clipboardHistory?.payload(for: item) ?? payload
                return full.imageData
            }
            if let urlString = item.clipboardPayload?.fileURLs.first,
               let path = ClipboardFileReference.localFilePath(from: urlString),
               ClipboardFileReference.isImageFile(atPath: path) {
                return await Self.readCappedFile(atPath: path)
            }
            return nil
        case .screenshot:
            guard item.screenshotMediaKind != .video else { return nil }
            return await Self.readCappedFile(atPath: item.value)
        default:
            return nil
        }
    }

    // MARK: - Plain-text delivery

    /// Paste only the plain-text representation of a clipboard entry into the
    /// app behind Quick Launch. Rich text, an image, or a custom format is
    /// reduced to its text, and the full representation is left on the history
    /// untouched. Falls back to copying when there is no paste target.
    @discardableResult
    func pasteClipboardEntryAsPlainText(_ item: LauncherCatalogItem) async -> Bool {
        let text: String
        if let payload = item.clipboardPayload, !payload.text.isEmpty {
            text = payload.text
        } else {
            text = item.value
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "That clipboard entry has no text to paste."
            requestInputFocus()
            return false
        }
        var target = selectionTarget
        if let selectedTextService {
            if let captured = target,
               runningApplications.isTerminated(processIdentifier: captured.processIdentifier) == true {
                target = nil
            }
            if target == nil, let fresh = selectedTextService.currentExternalTarget() {
                target = fresh
                rememberSelectionTarget(fresh)
            }
        }
        guard let target, let selectedTextService else {
            pasteboard.writeString(text)
            markJustCopied()
            errorMessage = "No text field was available behind Quick Launch. The text was copied instead."
            requestInputFocus()
            return false
        }
        prepareForExternalAction?()
        await Task.yield()
        // Write the plain text marked transient, then Command-V it in. The
        // transient/auto-generated marker keeps this delivery out of Clipboard
        // History (the app's own paste is not a user copy), and it is the
        // deliberate "plain text" path: the original rich/image payload is not
        // restored. An explicit Copy action still writes a real copy.
        pasteboard.writeTransientString(text)
        let outcome = await selectedTextService.pastePasteboardOutcome(to: target)
        if outcome == .clipboardChanged {
            errorMessage = Self.clipboardChangedMessage
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        guard outcome == .pasted else {
            markJustCopied()
            errorMessage = selectedTextService.isAccessibilityTrusted
                ? "Could not paste into \(target.applicationName). The text was copied instead."
                : "Allow Quick Launch in Privacy & Security → Accessibility, then try again. The text was copied."
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        return true
    }

    // MARK: - Attach to the question draft

    /// Attach a clipboard entry to the question draft: text as a selection
    /// chip, an image as a picture chip, and a copied file as a file chip. The
    /// typed text is preserved and nothing is sent; the user presses Return.
    @discardableResult
    func attachClipboardEntryToQuestion(_ item: LauncherCatalogItem) async -> Bool {
        guard item.kind == .clipboard else { return false }
        let before = attachmentTray.items.count
        // Catalog and composer use the same validation, provenance, file
        // bounds and omission notices. There is only one attachment path.
        await attachClipboardHistoryItem(item)
        return attachmentTray.items.count > before
    }

    /// A Quick Launch image attachment from raw bytes. The shared reader
    /// validates the data (nil for corrupt bytes) and keeps the exact bytes;
    /// the payload's real MIME type is kept so JPEG and TIFF are not
    /// relabelled as PNG. Empty/missing MIME falls back to PNG.
    static func imageAttachment(from data: Data, mimeType: String?) -> QuickImageAttachment? {
        let resolved = (mimeType?.isEmpty == false) ? mimeType! : "image/png"
        return ClipboardImageReader.attachment(data: data, mimeType: resolved)
    }

    // MARK: - Annotate a saved screenshot

    /// Open a fresh copy of a saved screenshot in Preview (or the system's
    /// annotate-image host), leaving the original untouched. The copy is made
    /// on an I/O actor. A video is not annotatable here and reports so.
    func annotateInPreview(_ item: LauncherCatalogItem) async {
        guard item.kind == .screenshot else { return }
        guard item.screenshotMediaKind != .video else {
            errorMessage = "Videos cannot be annotated in Preview."
            requestInputFocus()
            return
        }
        let source = URL(fileURLWithPath: item.value)
        let store = ScreenshotAnnotationStore()
        guard let copy = await store.newWorkingCopy(of: source) else {
            errorMessage = "Could not make a copy of \(item.title) to annotate."
            requestInputFocus()
            return
        }
        if let preview = workspace.applicationURL(forBundleIdentifier: ScreenshotAnnotationStore.previewBundleIdentifier) {
            workspace.open(copy, withApplicationAt: preview, activating: true)
        } else {
            workspace.open(copy)
        }
    }

    // MARK: - Save an app-made capture to the screenshots folder

    /// Write the app-made capture waiting in the composer as a new PNG in the
    /// system screenshots folder, so it joins the Screenshots catalog. The
    /// in-memory attachment is kept, the old transient behaviour is unchanged
    /// until this is called, and nothing existing is overwritten. Returns the
    /// new file URL, or nil with a message on failure.
    @discardableResult
    func savePendingImageToScreenshots(now: Date = Date()) async -> URL? {
        guard let image = pendingImage else {
            errorMessage = "There is no capture to save."
            return nil
        }
        let folder = screenshotsFolder
        let name = Self.screenshotFileName(now: now, mimeType: image.mimeType)
        guard let url = await Self.writeNewScreenshot(image.data, in: folder, name: name) else {
            errorMessage = "Could not save the screenshot."
            return nil
        }
        // The list is re-scanned in the background, never synchronously on the
        // main actor; the new file is already on disk and the next scan picks
        // it up.
        refreshScreenshotFilesInBackground()
        return url
    }

    /// Writes a new 0600 PNG in `folder` off the main actor, never overwriting
    /// an existing file. Returns the new URL, or nil on failure.
    nonisolated static func writeNewScreenshot(_ data: Data, in folder: URL, name: String) async -> URL? {
        await ClipboardFileIO.shared.writeCapture(data, folder: folder, name: name)
    }

    /// "Screenshot 2026-10-16 at 14.32.07.png": the name macOS and the
    /// catalog's date parsing recognise, so a saved capture sorts and filters
    /// like any other.
    static func screenshotFileName(now: Date, mimeType: String = "image/png") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let ext = fileExtension(forImageMimeType: mimeType)
        return "Screenshot \(formatter.string(from: now)).\(ext)"
    }

    /// A URL in `folder` whose file does not exist yet, appending a counter
    /// while a name is taken so an existing capture is never overwritten.
    nonisolated static func nonClobberingURL(in folder: URL, name: String, fileManager: FileManager = .default) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let next = "\(base)-\(counter)"
            candidate = folder.appendingPathComponent(next).appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    // MARK: - Catalog filter hint

    /// A visible line naming the active clipboard filter, from the segmented
    /// control or the `source:`/`tag:`/`kind:`/`pin:` query grammar, so the
    /// predicate is discoverable rather than hidden. Nil when nothing narrows
    /// the list.
    var clipboardFilterHint: String? {
        var parts: [String] = []
        let parsed = ClipboardFilterQuery.parse(input)
        if let source = parsed.source { parts.append("source:\(source)") }
        if let tag = parsed.tag { parts.append("tag:\(tag)") }
        if !parsed.kinds.isEmpty {
            parts.append("kind:" + parsed.kinds.map(\.rawValue).sorted().joined(separator: ","))
        }
        if parsed.pinnedOnly { parts.append("pin:true") }
        if clipboardCatalogFilter.pinnedOnly, !parsed.pinnedOnly { parts.append("pin:true") }
        if !clipboardCatalogFilter.kinds.isEmpty, parsed.kinds.isEmpty {
            parts.append("kind:" + clipboardCatalogFilter.kinds.map(\.rawValue).sorted().joined(separator: ","))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The always-visible grammar cheat sheet under the clipboard filter bar.
    static let clipboardFilterHintText = "Narrow with source:App, tag:App, kind:image, or pin:true."

    // MARK: - Open and Save as File

    /// Whether an entry has something to open: a copied file, or a link.
    func canOpenClipboardEntry(_ item: LauncherCatalogItem) -> Bool {
        if !(item.clipboardPayload?.fileURLs.isEmpty ?? true) { return true }
        return ItemActionCatalog.looksLikeURL(item.value)
    }

    /// Open a clipboard entry: a copied file in its default app, or a copied
    /// link in the browser. Nothing else has a meaningful Open.
    @discardableResult
    func openClipboardEntry(_ item: LauncherCatalogItem) -> Bool {
        if let urlString = item.clipboardPayload?.fileURLs.first,
           let path = ClipboardFileReference.localFilePath(from: urlString) {
            workspace.open(URL(fileURLWithPath: path))
            return true
        }
        let trimmed = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ItemActionCatalog.looksLikeURL(trimmed), let url = URL(string: trimmed) {
            workspace.open(url)
            return true
        }
        errorMessage = "There is nothing to open in that clipboard entry."
        requestInputFocus()
        return false
    }

    /// Save a supported clipboard payload to a file the user picks. Writes a
    /// new file only; the history entry, its pins, and its original payload
    /// are untouched. Cancelling the save panel is not an error.
    @discardableResult
    func saveClipboardEntryAsFile(_ item: LauncherCatalogItem) async -> Bool {
        let payload = await clipboardHistory?.payload(for: item) ?? item.clipboardPayload
        guard let picker = attachmentFilePicker else {
            errorMessage = "Saving files is not available here."
            requestInputFocus()
            return false
        }

        // A copied file is copied directly on the I/O thread, never loaded
        // whole into memory. The original file and the history entry are
        // untouched.
        if let payload, payload.kind == .fileURL {
            guard let urlString = payload.fileURLs.first,
                  let path = ClipboardFileReference.localFilePath(from: urlString) else {
                errorMessage = "That copied file is no longer available on this Mac."
                requestInputFocus()
                return false
            }
            let source = URL(fileURLWithPath: path)
            let ext = source.pathExtension
            guard let destination = await picker.chooseExportDestination(
                suggestedName: source.lastPathComponent,
                allowedExtensions: ext.isEmpty ? [] : [ext.lowercased()]
            ) else { return false }
            guard await Self.copyFileOffMain(from: source, to: destination) else {
                errorMessage = "Could not save \(source.lastPathComponent)."
                requestInputFocus()
                return false
            }
            return true
        }

        guard let export = await clipboardExport(from: item, payload: payload) else {
            errorMessage = "That clipboard entry cannot be saved as a file."
            requestInputFocus()
            return false
        }
        guard let destination = await picker.chooseExportDestination(
            suggestedName: export.name,
            allowedExtensions: export.extensions
        ) else {
            return false
        }
        guard await Self.writeFileOffMain(export.data, to: destination) else {
            errorMessage = "Could not save \(export.name)."
            requestInputFocus()
            return false
        }
        return true
    }

    /// The bytes, suggested name, and extension for a clipboard entry's
    /// supported payload. Nil when the entry has no exportable payload.
    func clipboardExport(
        from item: LauncherCatalogItem,
        payload loaded: ClipboardPayload?
    ) async -> (data: Data, name: String, extensions: [String])? {
        guard let payload = loaded else {
            // A legacy plain-text entry with no stored payload.
            guard !item.value.isEmpty else { return nil }
            return (Data(item.value.utf8), "Clipboard Text.txt", ["txt"])
        }
        switch payload.kind {
        case .image:
            guard let data = payload.imageData else { return nil }
            let ext = Self.fileExtension(forImageMimeType: payload.imageMimeType)
            return (data, "Copied Image.\(ext)", [ext])
        case .text, .richText:
            let text = payload.text.isEmpty ? item.value : payload.text
            guard !text.isEmpty else { return nil }
            return (Data(text.utf8), "Clipboard Text.txt", ["txt"])
        case .data:
            guard let rep = payload.items?.first?.first else { return nil }
            let ext = Self.fileExtension(forTypeIdentifier: rep.type)
            return (rep.data, "Clipboard Data.\(ext)", [ext])
        case .fileURL:
            // File payloads are copied directly by `saveClipboardEntryAsFile`.
            return nil
        }
    }

    /// Reads a file's bytes off the main actor, capped at `limit`, so a huge
    /// or hostile file cannot balloon memory on the UI thread. Returns nil
    /// when the file is missing, unreadable, or over the cap.
    nonisolated static func readCappedFile(
        atPath path: String,
        limit: Int = ClipboardImageReader.maximumBytes
    ) async -> Data? {
        await ClipboardFileIO.shared.read(at: URL(fileURLWithPath: path), limit: limit)
    }

    nonisolated static func copyFileOffMain(from source: URL, to destination: URL) async -> Bool {
        await ClipboardFileIO.shared.copy(from: source, to: destination)
    }

    nonisolated static func writeFileOffMain(_ data: Data, to destination: URL) async -> Bool {
        await ClipboardFileIO.shared.write(data, to: destination)
    }

    /// A file extension for an image MIME type, defaulting so a saved image
    /// still opens with a sensible name.
    static func fileExtension(forImageMimeType mimeType: String?) -> String {
        guard let mimeType, let type = UTType(mimeType: mimeType),
              let ext = type.preferredFilenameExtension else { return "png" }
        return ext
    }

    static func fileExtension(forTypeIdentifier identifier: String) -> String {
        if let type = UTType(identifier), let ext = type.preferredFilenameExtension { return ext }
        return "dat"
    }
}
