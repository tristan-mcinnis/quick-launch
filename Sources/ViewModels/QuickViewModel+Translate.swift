import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// Translate with shift-return.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - Translate (⇧↩)

    /// Direction ⇧↩ would use for the current input.
    var translationDirection: TranslationDirection? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pendingImage == nil, !text.hasPrefix(settings.savedPromptPrefix) else { return nil }
        return TranslationDirection.detect(text)
    }

    /// ⇧↩: translate the typed text, direction from the script (or the
    /// Translate-mode override).
    func translateInput() async {
        // "<text> in <language>": ⇧↩ acts on the row, in its language.
        if let translation = inlineTranslation {
            await performLauncherItem(Self.inlineTranslationItem(translation))
            return
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let direction = translationDirection else { return }
        inputMode = nil
        await translate(text, direction: direction)
    }

    private func translate(_ text: String, direction: TranslationDirection) async {
        if settings.savedPrompts.contains(where: { $0.alias == direction.alias }) {
            input = settings.savedPromptPrefix + direction.alias + " " + text
        } else {
            let target = direction == .toEnglish ? "English" : "Simplified Chinese"
            input = "Translate the following text to \(target). Return only the translation, no preamble.\n\n\(text)"
        }
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        await submit()
        // Show the text, not the expanded prompt, above the translation.
        lastQuestion = text
    }

    /// Provider that receives attached images.
    var visionProvider: InferenceProvider? {
        settings.providers.first { $0.id == settings.visionProviderID }
            ?? settings.providers.first { $0.id == InferenceProvider.mlxVisionID }
    }

    /// Model used for images: the explicit vision model, else the vision
    /// provider's selected model.
    var visionModelName: String {
        guard let visionProvider else { return "" }
        return settings.visionModel.isEmpty ? visionProvider.selectedModel : settings.visionModel
    }

    var visionDisplayName: String {
        guard let visionProvider else { return "No vision model" }
        let model = visionModelName
        return model.isEmpty
            ? visionProvider.name
            : "\(visionProvider.name) · \(ModelProfile.displayName(forModelID: model))"
    }

    /// Title of the attachment card: "Screen Awareness · Safari" or "Screenshot attached".
    var attachmentTitle: String {
        if let pendingContext, pendingContext.includedSources.count > (pendingContext.hasScreenshot ? 1 : 0) || pendingImages.isEmpty {
            return "Screen Awareness · \(pendingContext.appName)"
        }
        return pendingImages.count > 1 ? "\(pendingImages.count) screenshots attached" : "Screenshot attached"
    }

    /// Subtitle of the attachment card: what is included and where it goes.
    var attachmentSubtitle: String {
        var parts: [String] = []
        if let pendingContext {
            if let title = pendingContext.windowTitle, !title.isEmpty { parts.append(title) }
            parts.append(pendingContext.includedSources.joined(separator: ", "))
        }
        parts.append(!pendingImages.isEmpty ? visionRoutingNote : "Sent as text")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Anything waiting to travel with the next question: a screenshot, the
    /// Add Context context, or a chip on the tray.
    var hasPendingAttachment: Bool {
        !pendingImages.isEmpty || pendingContext != nil || !attachmentTray.isEmpty
    }

    func clearAttachments() {
        pendingImages.removeAll()
        pendingContext = nil
        attachmentTray.removeAll()
        // A cleared attachment strip also drops the launch-scoped selection
        // so it cannot ride a later request.
        clearLaunchScopedState()
    }

    /// One line under the attachment saying where the image goes.
    var visionRoutingNote: String {
        guard let visionProvider else { return "Choose a vision model in Settings › Models" }
        return visionProvider.location == .local
            ? "Sent only to \(visionProvider.name) on this Mac"
            : "Sent to \(visionProvider.name)"
    }

    func setVisionModel(providerID: UUID, model: String) {
        settings.visionProviderID = providerID
        settings.visionModel = model
        persistSettings(settings)
    }

    func performSystemCommand(_ item: LauncherCatalogItem) {
        if HouseCommandCatalog.isHouseCommand(item.value) {
            Task { @MainActor [weak self] in await self?.performHouseCommand(item) }
            return
        }
        if item.value.hasPrefix("toggle."),
           let toggle = QuickToggle(rawValue: String(item.value.dropFirst("toggle.".count))) {
            input = ""
            overlayPresenter.dismissOverlay()
            Task { @MainActor [weak self] in
                if let failure = await QuickToggleService.run(toggle) {
                    guard let self else { return }
                    self.errorMessage = failure
                    self.recoverFromExternalActionFailure?()
                    self.requestInputFocus()
                }
            }
            return
        }

        if item.value.hasPrefix("settingspane."),
           let pane = SystemSettingsPaneCatalog.panes.first(where: { $0.id == String(item.value.dropFirst("settingspane.".count)) }) {
            input = ""
            overlayPresenter.dismissOverlay()
            workspace.open(pane.url)
            return
        }

        if item.value == "snippet.create" {
            beginCreatingSnippet()
            return
        }

        if item.value == "quicklink.create" {
            beginCreatingQuicklink()
            return
        }

        if item.value == "ocr.area" {
            Task { await copyTextFromScreenArea() }
            return
        }

        if item.value == "ocr.areaPaste" {
            Task { await copyTextFromScreenArea(thenPaste: true) }
            return
        }

        if item.value == "paste.plain" {
            guard let text = pasteboard.readString(), !text.isEmpty else {
                errorMessage = "The clipboard has no text."
                requestInputFocus()
                return
            }
            let plain = LauncherCatalogItem(kind: .clipboard, itemID: "plain", title: "Plain text", detail: "", value: text)
            input = ""
            Task {
                if await pasteLauncherItem(plain) {
                    overlayPresenter.dismissOverlay()
                }
            }
            return
        }

        if item.value == "clipboard.cleanLink" {
            guard let text = pasteboard.readString(),
                  let cleaned = URLCleaner.clean(text) else {
                errorMessage = "The clipboard does not hold a web link."
                requestInputFocus()
                return
            }
            pasteboard.writeString(cleaned)
            markJustCopied()
            answerSource = .command(item.title)
            output = cleaned
            lastQuestion = cleaned == text.trimmingCharacters(in: .whitespacesAndNewlines)
                ? "Link had no tracking parameters"
                : "Clean link copied"
            errorMessage = nil
            input = ""
            requestInputFocus()
            return
        }

        if item.value.hasPrefix(SettingsDestination.valuePrefix),
           let destination = SettingsDestinationIndex.destination(
               id: String(item.value.dropFirst(SettingsDestination.valuePrefix.count))
           ) {
            input = ""
            overlayPresenter.dismissOverlay()
            overlayPresenter.openSettings(destination: destination)
            return
        }

        if item.value == "settings.open" {
            input = ""
            overlayPresenter.dismissOverlay()
            overlayPresenter.openSettings()
            return
        }

        if item.value == "caffeinate.toggle" {
            // The action follows the session, not the assertion: a battery-paused
            // session still offers Decaffeinate and this cancels it rather than
            // re-enabling.
            let desired = !hasCaffeinateSession
            guard caffeinateManager?.setEnabled(desired) == true else {
                errorMessage = "Could not change Caffeinate."
                requestInputFocus()
                return
            }
            syncCaffeinateState()
            settings.caffeinateEnabled = desired
            settings.caffeinateUntil = nil
            persistSettings(settings)
            input = ""
            overlayPresenter.dismissOverlay()
            return
        }

        if item.value == "caffeinate.until" {
            enterInputMode(.caffeinateUntil)
            return
        }

        if item.value == "caffeinate.agentWatch" {
            settings.caffeinateAgentWatch.toggle()
            caffeinateManager?.isAgentWatchEnabled = settings.caffeinateAgentWatch
            persistSettings(settings)
            syncCaffeinateState()
            input = ""
            invalidateLauncherRanking()
            return
        }

        if item.value == "caffeinate.status" {
            answerSource = .command(item.title)
            output = caffeinateManager?.statusSummary ?? "Decaffeinated. Normal Mac sleep is enabled."
            lastQuestion = "Caffeinate status"
            errorMessage = nil
            input = ""
            requestInputFocus()
            return
        }

        if item.value == Self.aiChatCommandID {
            openAIChatWindow()
            return
        }

        if item.value == "translate.mode" {
            input = ""
            overlayPresenter.dismissOverlay()
            overlayPresenter.openTranslator()
            return
        }

        if item.value == "type-to-click.mode" {
            input = ""
            overlayPresenter.dismissOverlay()
            overlayPresenter.openTypeToClick()
            return
        }

        if item.value.hasPrefix("caffeinate."),
           let minutes = Int(item.value.dropFirst("caffeinate.".count)) {
            guard let caffeinateManager, caffeinateManager.enable(for: TimeInterval(minutes * 60)) else {
                errorMessage = "Could not start Caffeinate."
                requestInputFocus()
                return
            }
            syncCaffeinateState()
            // A timed session is restored after a relaunch, an indefinite
            // one is the launch-time preference. Persist the intended deadline,
            // not `endsAt`: while the battery has paused the session `endsAt` is
            // nil, but the timer must survive the relaunch.
            settings.caffeinateEnabled = false
            settings.caffeinateUntil = caffeinateManager.sessionDeadline
            persistSettings(settings)
            input = ""
            overlayPresenter.dismissOverlay()
            return
        }

        guard item.value.hasPrefix("window.") else {
            errorMessage = "No manageable window was available behind Quick Launch."
            requestInputFocus()
            return
        }
        let name = String(item.value.dropFirst("window.".count))
        // Quick Launch's own AI Chat window takes the command when it is the
        // window in front, and always when the command came from the chat's
        // own palette. The external path could never reach it: its resolver
        // skips this process, and Accessibility is the wrong actuator for an
        // app's own window. Same layouts, same cycling, different setter.
        if let ownWindowLayout, isAIChatWindow || ownWindowLayout.isFrontmost {
            if runOwnWindowCommand(name, on: ownWindowLayout) { return }
        }
        guard let target = selectionTarget, let windowManager else {
            errorMessage = "No manageable window was available behind Quick Launch."
            requestInputFocus()
            return
        }
        let applied: Bool
        if let layout = WindowLayout(rawValue: name) {
            prepareForExternalAction?()
            applied = windowManager.apply(layout, to: target)
        } else if let move = WindowMove(rawValue: name) {
            prepareForExternalAction?()
            applied = windowManager.move(move, target: target)
        } else {
            errorMessage = "Unknown window command."
            requestInputFocus()
            return
        }
        guard applied else {
            let isDisplayMove = name == WindowMove.nextDisplay.rawValue || name == WindowMove.previousDisplay.rawValue
            errorMessage = windowManager.isAccessibilityTrusted
                ? (isDisplayMove && screenGeometry.screenCount < 2
                    ? "Only one display is connected."
                    : (name == WindowMove.restore.rawValue
                        ? "Nothing to restore yet for \(target.applicationName)."
                        : "Could not resize \(target.applicationName)."))
                : "Accessibility access is required for window management."
            requestInputFocus()
            return
        }
        input = ""
    }

    /// Runs `name` against one of Quick Launch's own windows. Returns false
    /// when the name is not a window command at all, so the caller falls
    /// through to the external path and reports the unknown name there.
    ///
    /// The launcher panel is dismissed first, as it is for an external
    /// window; the chat's own palette is not, because there
    /// `prepareForExternalAction` hides the very window being laid out.
    private func runOwnWindowCommand(_ name: String, on own: any OwnWindowLaying) -> Bool {
        let applied: Bool
        if let layout = WindowLayout(rawValue: name) {
            if !isAIChatWindow { prepareForExternalAction?() }
            applied = own.apply(layout)
        } else if let move = WindowMove(rawValue: name) {
            if !isAIChatWindow { prepareForExternalAction?() }
            applied = own.move(move)
        } else {
            return false
        }
        if applied {
            input = ""
        } else {
            let isDisplayMove = name == WindowMove.nextDisplay.rawValue
                || name == WindowMove.previousDisplay.rawValue
            errorMessage = isDisplayMove && screenGeometry.screenCount < 2
                ? "Only one display is connected."
                : (name == WindowMove.restore.rawValue
                    ? "Nothing to restore yet for \(own.windowName)."
                    : "Could not resize \(own.windowName).")
            requestInputFocus()
        }
        return true
    }

    /// Copy Text from Screen Area: the system selector, Vision OCR on this
    /// Mac, the result on the clipboard and in the panel. No model involved.
    /// Drag out an area, read it with on-device Vision, and copy the text.
    /// `thenPaste` sends the text straight to the app behind the overlay.
    func copyTextFromScreenArea(thenPaste: Bool = false) async {
        guard let screenAwareness else {
            errorMessage = "Screen capture is not available in this build."
            requestInputFocus()
            return
        }
        input = ""
        prepareForExternalAction?()
        guard let attachment = await screenAwareness.captureArea() else {
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return
        }
        let recognized = await ScreenshotTextIndex.recognizeText(in: attachment.data)
        let text = Self.flattenRecognizedText(recognized, keepLineBreaks: settings.ocrKeepLineBreaks)
        guard !text.isEmpty else {
            overlayPresenter.presentOverlay()
            errorMessage = "No text was found in that area."
            requestInputFocus()
            return
        }
        let item = LauncherCatalogItem(
            kind: .clipboard,
            itemID: "ocr",
            title: "Text from screen",
            detail: "",
            value: text
        )
        if thenPaste, await pasteLauncherItem(item) {
            overlayPresenter.dismissOverlay()
            return
        }
        pasteboard.writeString(text)
        markJustCopied()
        overlayPresenter.presentOverlay()
        answerSource = .command("Text from Screen")
        output = text
        lastQuestion = thenPaste ? "Text from screen" : "Text from screen, copied"
        errorMessage = nil
        requestInputFocus()
    }

    /// Vision returns one line per observation. Joining them into a paragraph
    /// is what most pasted text wants; keeping the breaks suits code and lists.
    nonisolated static func flattenRecognizedText(_ text: String, keepLineBreaks: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keepLineBreaks else { return trimmed }
        return trimmed
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func runningApplication(for application: LaunchableApplication) -> (any RunningApplicationControlling)? {
        runningApplications.runningApplication(
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: application.url
        )
    }

    /// ⌘K on a running app: Hide, Quit, Force Quit, Relaunch.
    func controlRunningApplication(_ application: LaunchableApplication, action: ItemActionKind) {
        guard let running = runningApplication(for: application) else {
            errorMessage = "\(application.name) is not running."
            requestInputFocus()
            return
        }
        closeItemActionPane()
        input = ""
        switch action {
        case .hide:
            running.hide()
        case .quit:
            running.terminate()
        case .forceQuit:
            running.forceTerminate()
        case .relaunch:
            running.terminate()
            let catalog = applicationCatalog
            Task { @MainActor in
                for _ in 0..<50 where !running.isTerminated {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                _ = catalog?.launch(application)
            }
        default:
            return
        }
        overlayPresenter.dismissOverlay()
    }

    @discardableResult
    func addCustomFolder(_ url: URL) -> Bool {
        let location = FolderLocationService.custom(from: url)
        let path = location.expandedURL.standardizedFileURL.path
        // A folder already reachable as a built-in (or already added) is
        // deduplicated out of `available`, so storing it would leave a hidden,
        // non-removable record. Reject the covered path.
        let covered = (FolderLocationService.builtIn + settings.customFolders).contains {
            $0.expandedURL.standardizedFileURL.path == path
        }
        guard !covered else { return false }
        settings.customFolders.append(location)
        persistSettings(settings)
        invalidateLauncherRanking()
        return true
    }

    func removeCustomFolder(_ item: LauncherCatalogItem) {
        settings.customFolders.removeAll { $0.id == item.itemID }
        removeLauncherItemConfiguration(for: item)
        persistSettings(settings)
        invalidateLauncherRanking()
    }

    @discardableResult
    func addCustomApplication(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard !settings.customApplicationPaths.contains(path) else { return false }
        // An app inside a scanned Applications folder is already in the list;
        // storing it again adds a duplicate the Items table cannot tell apart.
        let covered = ApplicationCatalogService.roots.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        guard !covered else { return false }
        settings.customApplicationPaths.append(path)
        persistSettings(settings)
        applicationCatalog?.setExtraApplicationPaths(settings.customApplicationPaths)
        return true
    }

    /// Removes an app the user added in Settings › Items. Only a custom app
    /// can be removed: the scanned Applications folders are not this list's to
    /// edit. Also drops the app's alias, hotkey, and pin.
    func removeCustomApplication(_ application: LaunchableApplication) {
        let path = application.url.standardizedFileURL.path
        settings.customApplicationPaths.removeAll { $0 == path }
        removeLauncherItemConfiguration(
            for: LauncherCatalogItem(
                kind: .application,
                itemID: application.id,
                title: application.name,
                detail: "",
                value: path
            )
        )
        persistSettings(settings)
        applicationCatalog?.setExtraApplicationPaths(settings.customApplicationPaths)
    }

    func openQuickLink(_ item: LauncherCatalogItem, input: String) {
        let rendered = QuickLinkQuery.render(
            item.value,
            query: input,
            clipboard: pasteboard.readString() ?? ""
        )
        guard let url = URL(string: rendered),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "This Quick Link does not contain a valid web address."
            requestInputFocus()
            return
        }
        openInQuickLinkBrowser(url)
        self.input = ""
        pendingQuickLinkID = nil
        overlayPresenter.dismissOverlay()
    }

    /// Browsers that can open web links, for the Quick Links setting.
    static var installedBrowsers: [LaunchableApplication] {
        guard let probe = URL(string: "https://example.com") else { return [] }
        return SystemWorkspace().applicationURLs(toOpen: probe)
            .compactMap { url in
                let bundle = Bundle(url: url)
                let name = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                return LaunchableApplication(name: name, bundleIdentifier: bundle?.bundleIdentifier, url: url)
            }
            .filter { $0.bundleIdentifier != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Open `url` in the browser chosen in Settings, or the system default.
    func openInQuickLinkBrowser(_ url: URL) {
        if let bundleID = settings.quickLinkBrowserBundleID,
           let appURL = workspace.applicationURL(forBundleIdentifier: bundleID) {
            workspace.open(url, withApplicationAt: appURL, activating: true)
        } else {
            workspace.open(url)
        }
    }

    var isBareAliasQuery: Bool {
        guard !settings.savedPromptPrefix.isEmpty,
              input.hasPrefix(settings.savedPromptPrefix) else { return false }
        let rest = input.dropFirst(settings.savedPromptPrefix.count)
        return !rest.isEmpty && !rest.contains(where: { $0.isWhitespace })
    }

    /// Remember the app behind the overlay. The selected text is read later,
    /// only when an action needs it, so an Accessibility round trip never
    /// sits between the hotkey and the panel.
    func rememberSelectionTarget(_ target: SelectionTarget?) {
        selectionTarget = target
        selectedTextContext = nil
    }

    /// Capture the selected text in the background app now, before the
    /// overlay takes focus, as an immutable launch-scoped snapshot. Silent:
    /// never prompts for Accessibility permission. No-op when the app is not
    /// trusted, has no selection, or the overlay opened on the menu bar.
    ///
    /// The full `SelectedTextContext` is retained so a saved action that
    /// replaces the selection can write back to the captured target without
    /// re-reading (the app may no longer be frontmost by then).
    func captureLaunchSelection() {
        launchSelection = nil
        selectionRecaptureSuppressed = false
        guard let selectionTarget, let selectedTextService else { return }
        guard let captured = selectedTextService.capture(
            from: selectionTarget,
            promptForPermission: false
        ),
        !captured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Kept for `replace` at completion and for the `{selection}` re-use
        // path; only a fresh capture (or `rememberSelectionTarget`) resets it.
        selectedTextContext = captured
        launchSelection = LaunchSelection(
            text: captured.text,
            appName: selectionTarget.applicationName
        )
    }

    /// Remove the launch-scoped selection: invalidate the snapshot, forget the
    /// cached context (so a result is not written back to a stale target), and
    /// suppress any automatic re-capture until a fresh launch or an explicit
    /// attachment.
    func clearLaunchSelection() {
        launchSelection = nil
        explicitTransformSource = nil
        explicitTransformSourceLabel = nil
        selectedTextContext = nil
        selectionRecaptureSuppressed = true
    }

    /// Clear every piece of launch-scoped selection state. Used when the user
    /// clears attachments and when the overlay is dismissed, so a stale
    /// selection or chip cannot survive into a later request or a reopen.
    func clearLaunchScopedState() {
        launchSelection = nil
        explicitTransformSource = nil
        explicitTransformSourceLabel = nil
        pendingActionSource = nil
        pendingActionSourceLabel = nil
        selectedTextContext = nil
        selectionRecaptureSuppressed = true
    }

    /// Chip heading: where the captured text came from.
    var launchSelectionTitle: String {
        guard let appName = launchSelection?.appName else { return "Selected text" }
        return "Selected text from \(appName)"
    }

    /// Single-line preview of the captured selection, bounded for the chip.
    var launchSelectionPreview: String {
        guard let text = launchSelection?.text else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return trimmed.count > 120 ? trimmed.prefix(117) + "…" : trimmed
    }

    /// Root search's field changed: a keystroke replaces a local answer
    /// with the rows for what is typed.
    func rootInputDidChange(_ newValue: String) {
        if rootAnswer != nil, !newValue.isEmpty { rootAnswer = nil }
        updateInlineTranslation()
    }

    nonisolated static let inlineTranslationDebounce: Duration = .milliseconds(300)

    /// Starts, keeps or drops the live translation for the root text. The
    /// model is asked once per (phrase, language) after a typing pause, and
    /// only when `rankLauncherMatches` would draw the row; a local answer
    /// ("5 km in miles") always wins.
    func updateInlineTranslation() {
        guard !isAnswerActive, inputMode == nil, !hasPendingAttachment,
              pendingHouseChoice == nil, rootAnswer == nil,
              let text = rootLauncherQuery,
              let query = InlineTranslationQuery.parse(text),
              localAnswer(for: text) == nil
        else {
            inlineTranslationTask?.cancel()
            inlineTranslationTask = nil
            inlineTranslation = nil
            return
        }
        if inlineTranslation?.query == query { return }
        inlineTranslationTask?.cancel()
        inlineTranslation = InlineTranslation(query: query)
        inlineTranslationTask = Task { [weak self] in
            try? await Task.sleep(for: Self.inlineTranslationDebounce)
            guard !Task.isCancelled else { return }
            await self?.runInlineTranslation(query)
        }
    }

    /// The running translation task, so a test can wait on one request that
    /// a newer query has since replaced.
    var inlineTranslationTaskForTesting: Task<Void, Never>? { inlineTranslationTask }

    /// What a caller (or a test) waits on: the typing pause and the request.
    func inlineTranslationSettled() async {
        await inlineTranslationTask?.value
    }

    private func runInlineTranslation(_ query: InlineTranslationQuery) async {
        guard let service = makeCurrentService() else {
            inlineTranslation?.status = .failed
            return
        }
        let prompt = TranslatorModel.prompt(for: query.phrase, target: query.target)
        var collected = ""
        do {
            for try await delta in service.send(messages: [QuickMessage(role: .user, content: prompt)]) {
                guard !Task.isCancelled, inlineTranslation?.query == query else { return }
                if let piece = delta.text {
                    collected += piece
                    inlineTranslation?.text = collected
                }
            }
            guard !Task.isCancelled, inlineTranslation?.query == query else { return }
            let text = collected.trimmingCharacters(in: .whitespacesAndNewlines)
            inlineTranslation?.text = text
            inlineTranslation?.status = text.isEmpty ? .failed : .ready
        } catch {
            guard !Task.isCancelled, inlineTranslation?.query == query else { return }
            inlineTranslation?.status = .failed
        }
    }
}
