import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// The capture chooser.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - Capture chooser (⇧⌘S)

    /// Every capture this surface can run, Selected Text first, before the
    /// search filter. A capture that reads the app behind leaves the list
    /// while no such app is known, so the chooser never advertises a row it
    /// cannot run and every surface keeps at least the two screen captures.
    var captureChooserAllOptions: [AddContextEntry] {
        AddContextEntry.captureChooser(offering: addContextOptions.filter {
            !$0.needsPreviousApp || selectionTarget != nil
        })
    }

    /// The chooser's rows after the search filter, best match first. The
    /// highlight always indexes this list, so the keys and the drawn rows
    /// agree.
    var captureChooserOptions: [AddContextEntry] {
        guard !captureChooserQuery.isEmpty else { return captureChooserAllOptions }
        return Self.rankByQuery(captureChooserAllOptions, query: captureChooserQuery, title: \.title)
    }

    /// Whether the app behind holds selected text, without doing anything
    /// the user can see or has to approve: the selection already captured
    /// for this request, the silent launch snapshot, else the injected
    /// `SelectedTextServicing` seam's own silent read. Tests drive it through
    /// `launchSelection` or a fake service; nothing here prompts for
    /// Accessibility, steals focus, or attaches anything.
    func selectedTextIsAvailableSilently() -> Bool {
        if let cached = selectedTextContext {
            return !cached.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let text = launchSelection?.text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let target = selectionTarget, let selectedTextService else { return false }
        return selectedTextService.hasSelection(from: target)
    }

    /// The row the chooser highlights: Selected Text when selected text is
    /// available, else Focused Window, else the first capture this surface
    /// offers. Always a row inside `captureChooserOptions`.
    var preferredCaptureEntry: AddContextEntry {
        let options = captureChooserAllOptions
        if captureChooserHasSelection, options.contains(.selectedText) { return .selectedText }
        if options.contains(.focusedWindow) { return .focusedWindow }
        return options.first ?? .selectedArea
    }

    func openCaptureChooser() {
        isModelChooserPresented = false
        isAssistantChooserPresented = false
        isAddContextMenuPresented = false
        isTransformChooserPresented = false
        isActionPalettePresented = false
        closeItemActionPane()
        attachmentTray.cancelLinkEntry()
        errorMessage = nil
        captureChooserQuery = ""
        let options = captureChooserOptions
        guard !options.isEmpty else {
            // Never a silent no-op: the key says why it did nothing.
            errorMessage = "Nothing can be captured from here."
            requestInputFocus()
            return
        }
        captureChooserHasSelection = selectedTextIsAvailableSilently()
        captureChooserIndex = options.firstIndex(of: preferredCaptureEntry) ?? 0
        isCaptureChooserPresented = true
        requestInputFocus()
    }

    func closeCaptureChooser() {
        guard isCaptureChooserPresented else { return }
        isCaptureChooserPresented = false
        requestInputFocus()
    }

    func moveCaptureChooserSelection(_ delta: Int) {
        let options = captureChooserOptions
        guard !options.isEmpty else { return }
        captureChooserIndex = ListSelection.wrappedIndex(
            captureChooserIndex,
            by: delta,
            count: options.count
        )
    }

    /// Return in the open chooser: attach exactly the highlighted capture,
    /// through the same capture paths the Add Context rows use.
    func runCaptureChooserSelection() async {
        let options = captureChooserOptions
        guard !options.isEmpty else {
            // Never a silent no-op, even if the surface changed under the
            // chooser: the key says why it did nothing.
            isCaptureChooserPresented = false
            errorMessage = "Nothing can be captured from here."
            requestInputFocus()
            return
        }
        let entry = options[min(max(captureChooserIndex, 0), options.count - 1)]
        isCaptureChooserPresented = false
        await addContext(entry)
    }

    /// The character that opens Add Context from the composer.
    static let addContextTrigger: Character = "@"

    /// Typing `@` opens the same menu the control does. The `@` is a trigger,
    /// not content, so it is dropped; a `@` inside a word (an address) never
    /// opens the menu. Returns whether it opened.
    @discardableResult
    func addContextTriggerDidChange(_ newValue: String) -> Bool {
        guard !isAddContextMenuPresented,
              !isStreaming,
              !isItemActionPanePresented,
              // In Recent Chats the composer is a search field.
              !isRecentChatsPresented,
              // Only the root and answer composers: inside a catalog search or
              // a typed command an `@` is part of what is being typed.
              catalogScope == nil,
              inputMode == nil,
              pendingQuickLinkID == nil,
              newValue.last == Self.addContextTrigger
        else { return false }
        let head = newValue.dropLast()
        guard head.isEmpty || head.last?.isWhitespace == true else { return false }
        input = String(head)
        openAddContextMenu()
        return true
    }

    /// Save the current result as a new snippet, then open its ⌘K pane so
    /// the title can be edited in place.
    func saveOutputAsSnippet() {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            errorMessage = "There is no result to save yet."
            requestInputFocus()
            return
        }
        guard let launcherCatalog else {
            errorMessage = LauncherCatalogError.creationUnsupported.localizedDescription
            requestInputFocus()
            return
        }
        let prompt = currentConversation?.messages.first(where: { $0.role == .user })?.content
        let title = Self.snippetTitle(from: prompt ?? value)
        do {
            let item = try launcherCatalog.createSnippet(title: title, value: value)
            isActionPalettePresented = false
            actionQuery = ""
            errorMessage = nil
            contextualCatalogItemID = item.id
            isCatalogActionPanePresented = true
            noteInteraction()
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
        }
    }

    /// First line of `text`, trimmed to a short title.
    static func snippetTitle(from text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#*>-• "))
        guard !cleaned.isEmpty else { return "Quick Launch result" }
        return cleaned.count > 48 ? String(cleaned.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : cleaned
    }

    /// Run a web search using the current result as the query.
    func searchWebForOutput() async {
        let query = Self.searchQuery(from: output)
        guard !query.isEmpty else {
            errorMessage = "There is no result to search for yet."
            requestInputFocus()
            return
        }
        isActionPalettePresented = false
        actionQuery = ""
        startNewConversation()
        input = "search the web for \(query)"
        await submit()
    }

    /// First sentence or line of `text`, capped for a search box.
    static func searchQuery(from text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#*>-• "))
        return String(cleaned.prefix(160))
    }

    /// Every directory root the browser scans: the system screenshot folder
    /// first, then the user's extra folders. Only these roots are scanned,
    /// never home, and never recursively. Duplicates are dropped.
    var screenshotFolders: [URL] {
        var roots = [screenshotsFolder]
        for path in settings.screenshotFolders {
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.isEmpty,
                  !roots.contains(where: { $0.path == expanded })
            else { continue }
            roots.append(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return roots
    }
    /// A scan this fresh is trusted on catalog entry, so entering costs nothing.
    static let screenshotScanFreshness: TimeInterval = 2

    /// Reads the folder off the main thread and swaps the list in when done.
    /// Repeated calls collapse into the running scan. Keeps the root badge
    /// and a first catalog entry instant: no disk work on the hot path.
    func refreshScreenshotFilesInBackground() {
        guard screenshotScanTask == nil else { return }
        let folder = screenshotsFolder
        let folders = screenshotFolders
        let includeAllMedia = settings.screenshotIncludeAllMedia
        let requestedAt = Date()
        screenshotScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let items = ScreenshotLibrary.items(
                inFolders: folders,
                includeAllMedia: includeAllMedia,
                now: requestedAt
            )
            await MainActor.run { [weak self] in
                self?.applyScreenshotScan(items, from: folder, requestedAt: requestedAt)
            }
        }
    }

    /// Re-runs screenshot OCR after the recognition mode changes, so the
    /// Text recognition control takes effect instead of leaving the first
    /// pass's text cached. The running pass is cancelled first so its stale
    /// results cannot overwrite the new mode's.
    func reindexScreenshotText(mode: ClipboardOCRMode) {
        screenshotTextIndex.cancel()
        screenshotTextIndex.refresh(for: screenshotFiles, mode: mode)
    }

    /// Warms the list when the cached scan is older than the freshness window.
    /// Called whenever the overlay appears, off the keystroke path.
    func warmScreenshotCatalogIfStale() {
        if catalogScope == .screenshots {
            // A rapid capture can arrive inside the cache freshness window.
            // Retained history always refreshes when the overlay reopens.
            refreshScreenshotFilesInBackground()
            return
        }
        if let last = lastScreenshotScanAt, Date().timeIntervalSince(last) < Self.screenshotScanFreshness {
            return
        }
        refreshScreenshotFilesInBackground()
    }

    /// Waits out a running background scan, for tests.
    func waitForScreenshotScanForTesting() async {
        await screenshotScanTask?.value
        screenshotScanTask = nil
    }

    /// Applies a finished background scan. A scan that was requested before
    /// newer data already landed (a synchronous reload on catalog entry, or
    /// a later scan) is dropped: without this, a slow listing taken before
    /// the newest capture would land afterwards and push it off the top.
    func applyScreenshotScan(_ items: [LauncherCatalogItem], from folder: URL, requestedAt: Date) {
        screenshotScanTask = nil
        guard folder == screenshotsFolder else { return }
        if let applied = lastScreenshotScanAt, requestedAt < applied { return }
        let browsedItemID = catalogScope == .screenshots && applicationSelectionIndex > 0
            ? focusedLauncherResult?.id : nil
        screenshotFiles = items
        lastScreenshotScanAt = Date()
        if settings.screenshotTextSearch {
            screenshotTextIndex.refresh(for: items, mode: settings.screenshotOCRMode)
        }
        invalidateLauncherRanking()
        if let browsedItemID {
            // Keep an older capture under the cursor when a new one arrives.
            // Row zero intentionally follows the newest capture for rapid paste.
            applicationSelectionIndex = launcherMatches.firstIndex { $0.id == browsedItemID }
                ?? min(applicationSelectionIndex, max(0, launcherMatches.count - 1))
        }
    }

    /// Send Screen Area to AI: the system selection rectangle, then attach.
    @discardableResult
    func attachScreenArea() async -> Bool {
        guard let screenAwareness else {
            errorMessage = "Screen capture is not available in this build."
            requestInputFocus()
            return false
        }
        prepareForExternalAction?()
        guard let attachment = await screenAwareness.captureArea() else {
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        pendingImage = attachment
        pendingContext = selectionTarget.map { CaptureContext(appName: $0.applicationName, hasScreenshot: true) }
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        input = ""
        errorMessage = nil
        applicationSelectionIndex = 0
        requestInputFocus()
        return true
    }

    /// Send Selected Text to AI: context only, no image.
    @discardableResult
    func attachSelectedText() -> Bool {
        guard let selectionTarget else {
            errorMessage = ScreenshotCaptureError.noPreviousApp.localizedDescription
            requestInputFocus()
            return false
        }
        // An explicit Selected Text capture re-arms the selection read: a
        // prior "remove chip" must not suppress it, and the cached context is
        // refreshed rather than reused.
        selectionRecaptureSuppressed = false
        selectedTextContext = nil
        guard let selected = captureSelectedText(promptForPermission: true)?.text
                .trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty else {
            errorMessage = selectedTextService?.isAccessibilityTrusted == false
                ? "Allow Accessibility in System Settings, then select text and try again."
                : "Nothing is selected in \(selectionTarget.applicationName)."
            requestInputFocus()
            return false
        }
        var context = screenAwareness?.readContext(for: selectionTarget)
            ?? CaptureContext(appName: selectionTarget.applicationName)
        context.selectedText = selected
        context.appText = nil
        context.focusedValue = nil
        pendingContext = context
        // Adding text keeps the images already chosen for this question.
        // An explicit Selected Text capture supersedes the auto-captured
        // launch selection, so the two are never sent twice.
        launchSelection = nil
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        input = ""
        errorMessage = nil
        requestInputFocus()
        return true
    }

    /// Paste Latest Screenshot: newest file straight into the app behind.
    func pasteLatestScreenshot() async {
        guard let url = LatestScreenshotFinder.newestScreenshot(in: screenshotsFolder) else {
            errorMessage = "No screenshot found in \(screenshotsFolder.lastPathComponent)."
            requestInputFocus()
            return
        }
        await pasteImageFile(url)
    }

    /// Copies an image file to the pasteboard and presses ⌘V in the previous app.
    @discardableResult
    func pasteImageFile(_ url: URL) async -> Bool {
        guard pasteboard.writeImageFile(at: url) else {
            errorMessage = "Could not read \(url.lastPathComponent)."
            requestInputFocus()
            return false
        }
        guard let target = selectionTarget, let selectedTextService else {
            markJustCopied()
            errorMessage = "No app was behind Quick Launch. The image was copied instead."
            requestInputFocus()
            return false
        }
        prepareForExternalAction?()
        await Task.yield()
        let outcome = await selectedTextService.pastePasteboardOutcome(to: target)
        if outcome == .clipboardChanged {
            errorMessage = Self.clipboardChangedMessage
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        guard outcome == .pasted else {
            markJustCopied()
            errorMessage = "Could not paste into \(target.applicationName). The image was copied instead."
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        input = ""
        return true
    }

    /// Attach a saved screenshot file to the next question.
    @discardableResult
    func attachScreenshotFile(_ item: LauncherCatalogItem) -> Bool {
        let url = URL(fileURLWithPath: item.value)
        guard let attachment = LatestScreenshotFinder.attachment(for: url) else {
            errorMessage = "Could not read \(url.lastPathComponent)."
            requestInputFocus()
            return false
        }
        learn(.item(item))
        pendingImage = attachment
        pendingContext = CaptureContext(appName: item.title, hasScreenshot: true)
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        input = ""
        errorMessage = nil
        applicationSelectionIndex = 0
        requestInputFocus()
        return true
    }

    /// Attach the newest saved screenshot from the screenshots folder.
    @discardableResult
    func attachLatestScreenshot() -> Bool {
        guard let url = LatestScreenshotFinder.newestScreenshot(in: screenshotsFolder) else {
            errorMessage = "No screenshot found in \(screenshotsFolder.lastPathComponent)."
            requestInputFocus()
            return false
        }
        guard let attachment = LatestScreenshotFinder.attachment(for: url) else {
            errorMessage = "Could not read \(url.lastPathComponent)."
            requestInputFocus()
            return false
        }
        pendingImage = attachment
        // Same attachment card as the other captures: what it is and where
        // it came from.
        pendingContext = selectionTarget.map { CaptureContext(appName: $0.applicationName, hasScreenshot: true) }
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        input = ""
        errorMessage = nil
        applicationSelectionIndex = 0
        requestInputFocus()
        return true
    }
}
