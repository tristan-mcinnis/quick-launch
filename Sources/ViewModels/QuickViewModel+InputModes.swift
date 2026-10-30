import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// Input modes.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - Input modes

    func enterInputMode(_ mode: InputMode) {
        clearTransformFlowState()
        // A mode owns the root input row, so the Quick AI surface steps
        // aside; the thread is kept behind it.
        isQuickAIPresented = false
        isRecentChatsPresented = false
        rootAnswer = nil
        renameReturnsToRecentChats = false
        inputMode = mode
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        input = ""
        errorMessage = nil
        applicationSelectionIndex = 0
        if case .renameChat(let id) = mode {
            input = history.first { $0.id == id }?.title ?? ""
        }
        if case .renameClipboard(let itemID) = mode {
            input = clipboardEntries.first { $0.itemID == itemID }?.title ?? ""
        }
        requestInputFocus()
        noteInteraction()
    }

    /// Tab, the Ask AI row, or its hotkey: keep what was typed, hide the
    /// launcher rows, and send the next Return to the model.
    /// A per-item hotkey on a Quick Link that needs typed input: the
    /// overlay opens straight into that link's input field.
    func enterQuickLinkInput(itemID: String) {
        reset([.layers, .mode, .input])
        pendingQuickLinkID = itemID
    }

    func openQuickAI() {
        ShowPathSignpost.quickAIOpen { openQuickAIUntraced() }
    }

    private func openQuickAIUntraced() {
        let preserved = input
        inputMode = nil
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        isActionPalettePresented = false
        actionQuery = ""
        isRecentChatsPresented = false
        input = preserved
        errorMessage = nil
        // A local answer belongs to root search; it does not follow.
        rootAnswer = nil
        applicationSelectionIndex = 0
        // The surface opens on the thread's newest text.
        followThreadBottom()
        isQuickAIPresented = true
        requestInputFocus()
    }

    /// The optional direct Quick AI hotkey: remember and capture the app and
    /// selection behind the overlay before it takes focus, then open the Quick
    /// AI composer on the retained draft. It never submits: the composer
    /// opens ready for the question, and the new-chat/retained-draft policy
    /// still governs what a later Return does.
    func presentQuickAIComposerForHotkey() {
        if let selectedTextService, let target = selectedTextService.currentExternalTarget() {
            rememberSelectionTarget(target)
            captureLaunchSelection()
        }
        openQuickAI()
    }

    /// Escape, the back chevron, or an empty Backspace on the surface: back
    /// to root search. The thread stays; `⌘N` is what starts a new one.
    func closeQuickAI() {
        guard isQuickAIPresented else { return }
        if isStreaming { cancel() }
        // Back in root search the typed text is a search, not a follow-up:
        // closing the layers below must not send it.
        isFollowUpQueued = false
        // Recent Chats' search text belongs to the list, not to root search.
        if isRecentChatsPresented { input = "" }
        isRecentChatsPresented = false
        isModelChooserPresented = false
        isAssistantChooserPresented = false
        isCaptureChooserPresented = false
        isAddContextMenuPresented = false
        isTransformChooserPresented = false
        isActionPalettePresented = false
        actionQuery = ""
        clearTransformFlowState()
        isQuickAIPresented = false
        errorMessage = nil
        applicationSelectionIndex = 0
        requestInputFocus()
    }

    /// Return in the Quick AI composer. One submit runs at a time. While a
    /// stream runs, the submit that started it is still in flight, so
    /// Return goes its own way: it picks in the question card or a chooser,
    /// or queues the typed follow-up (`queueFollowUp`), and never waits.
    func submitFromComposer() {
        // With the `/` palette up, Return takes the highlighted command into
        // the draft instead of sending it. That leaves room for an argument,
        // and keeps a destructive `/clear` two keystrokes away rather than
        // one. Both surfaces come through here.
        if isSlashCommandPalettePresented, completeSlashCommand() { return }
        if isStreaming {
            guard streamingReturnTask == nil else { return }
            streamingReturnTask = Task { @MainActor [weak self] in
                await self?.submitResolvingFuzzyAlias()
                self?.streamingReturnTask = nil
            }
            return
        }
        guard composerSubmitTask == nil else { return }
        composerSubmitTask = Task { @MainActor [weak self] in
            await self?.submitResolvingFuzzyAlias()
            // `cancel()` drops the handle itself; a cancelled submit must
            // not clear a newer one that took its place.
            guard !Task.isCancelled else { return }
            self?.composerSubmitTask = nil
        }
    }

    /// Tab in the launcher: complete a `/alias` when one matches, otherwise
    /// open Quick AI. Typed text is sent in the same gesture; an empty field
    /// opens the surface empty. Returns `false` when Tab should be left to
    /// the text field.
    func handleTab() -> Bool {
        if !savedPromptMatches.isEmpty {
            completeFirstFuzzyAlias()
            return true
        }
        guard !isStreaming, !isItemActionPanePresented,
              !isActionPalettePresented, inputMode == nil, !isQuickAIPresented else { return false }
        // Math and the other local answers stay in root search: the
        // surface never opens for them.
        if answerTypedTextLocally() { return true }
        openQuickAI()
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        learn(.item(askAIItem(query: input)))
        tabSubmitTask = Task { @MainActor [weak self] in
            await self?.submit()
        }
        return true
    }

    /// Leaves the typing mode for root search, or, for a rename started in
    /// Recent Chats, back to that list with the chat highlighted. Returns
    /// true when it went back to Recent Chats.
    @discardableResult
    func leaveInputMode() -> Bool {
        var renamedChatID: UUID?
        if renameReturnsToRecentChats, case .renameChat(let id) = inputMode { renamedChatID = id }
        renameReturnsToRecentChats = false
        inputMode = nil
        pendingSnippetInsertion = nil
        input = ""
        errorMessage = nil
        requestInputFocus()
        guard let renamedChatID else { return false }
        openRecentChats()
        recentChatsIndex = recentChatItems.firstIndex { $0.itemID == renamedChatID.uuidString } ?? recentChatsIndex
        return true
    }

    /// Return in a mode. Returns `false` when no mode is active.
    func submitInputMode() async -> Bool {
        guard let inputMode else { return false }
        switch inputMode {
        case .houseCommandArgument:
            guard let row = pendingHouseCommandText else {
                leaveInputMode()
                return true
            }
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            pendingHouseCommandText = nil
            leaveInputMode()
            await runHouseCommand(row, argument: text)
        case .snippetArgument:
            guard var pending = pendingSnippetInsertion else {
                leaveInputMode()
                return true
            }
            pending.collected.append(input.trimmingCharacters(in: .whitespacesAndNewlines))
            // More slots to fill: stay in the mode and ask for the next one.
            if pending.currentArgument != nil {
                pendingSnippetInsertion = pending
                input = ""
                errorMessage = nil
                requestInputFocus()
                noteInteraction()
                return true
            }
            let finished = pending
            pendingSnippetInsertion = nil
            leaveInputMode()
            await finishSnippetInsertion(
                finished.item,
                arguments: finished.collected,
                mode: finished.mode,
                dismissingOverlay: finished.dismissesOverlay
            )
        case .renameChat(let id):
            renameConversation(id: id, title: input)
            if !leaveInputMode() { enterCatalog(.chats) }
        case .renameClipboard(let itemID):
            if let item = clipboardEntries.first(where: { $0.itemID == itemID }) {
                _ = clipboardHistory?.rename(item, to: input)
            }
            if !leaveInputMode() { enterCatalog(.clipboard) }
        case .caffeinateUntil:
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let date = try CaffeinateSchedule.parse(text)
                guard let caffeinateManager, caffeinateManager.enable(until: date) else {
                    errorMessage = "Could not start Caffeinate."
                    requestInputFocus()
                    return true
                }
                syncCaffeinateState()
                settings.caffeinateEnabled = false
                settings.caffeinateUntil = date
                persistSettings(settings)
                leaveInputMode()
                overlayPresenter.dismissOverlay()
            } catch {
                errorMessage = error.localizedDescription
                requestInputFocus()
            }
        }
        return true
    }

    func enterCatalog(_ scope: LauncherCatalogScope) {
        if scope == .screenshots {
            // A scan from the last two seconds is already on screen; rescanning
            // would only repeat work. Anything older reads the disk once, now.
            let isFresh = lastScreenshotScanAt.map {
                Date().timeIntervalSince($0) < Self.screenshotScanFreshness
            } ?? false
            if !isFresh {
                reloadScreenshotFiles()
            } else {
                // Keep the cached list responsive, then include any capture
                // made during a rapid Back → Return round trip.
                refreshScreenshotFilesInBackground()
            }
        }
        inputMode = nil
        // A catalog is a root-search surface: Quick AI steps aside.
        isQuickAIPresented = false
        isRecentChatsPresented = false
        rootAnswer = nil
        catalogScope = scope
        pendingQuickLinkID = nil
        self.input = ""
        applicationSelectionIndex = 0
        errorMessage = nil
        requestInputFocus()
        noteInteraction()
    }

    func leaveCatalog() {
        let previousScope = catalogScope
        reset([.layers, .mode, .input])
        // Back returns to the catalog's root row, so Return enters it again.
        if let previousScope, let index = launcherMatches.firstIndex(where: {
            if case .catalog(let scope, _) = $0 { return scope == previousScope }
            return false
        }) {
            applicationSelectionIndex = index
        }
        requestInputFocus()
    }

    func noteInteraction() {
        if isHistoryCatalog {
            catalogIdleResetTask?.cancel()
            return
        }
        guard catalogScope != nil || pendingQuickLinkID != nil
                || isCatalogActionPanePresented || isApplicationActionPanePresented else {
            catalogIdleResetTask?.cancel()
            return
        }
        catalogIdleResetTask?.cancel()
        let delay = catalogIdleResetDelay
        catalogIdleResetTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.returnToRootAfterIdle()
        }
    }

    private func returnToRootAfterIdle() {
        guard !isStreaming else { return }
        isCatalogActionPanePresented = false
        isApplicationActionPanePresented = false
        contextualCatalogItemID = nil
        contextualApplicationID = nil
        catalogScope = nil
        pendingQuickLinkID = nil
        inputMode = nil
        input = ""
        applicationSelectionIndex = 0
        requestInputFocus()
    }

    func catalogCount(_ scope: LauncherCatalogScope) -> Int {
        let hidden = hiddenLauncherItemIDs()
        func visible(_ items: [LauncherCatalogItem]) -> Int {
            hidden.isEmpty ? items.count : items.filter { !hidden.contains($0.id) }.count
        }
        switch scope {
        case .snippets: return visible(snippets)
        case .quickLinks: return visible(quickLinks)
        case .clipboard: return visible(filteredClipboardEntries)
        case .emoji: return visible(emojiItems)
        case .screenshots: return visible(screenshotItems)
        case .caffeinate: return visible(caffeinateItems)
        case .chats: return chatCount(excluding: hidden)
        case .commands: return visible(systemCommands)
        case .folders: return visible(folderItems)
        }
    }

    /// Chats that are not hidden. Reading `conversationItems` here would build
    /// every row on each keystroke, so the ids are matched directly.
    private func chatCount(excluding hidden: Set<String>) -> Int {
        guard !hidden.isEmpty else { return history.count }
        return history.reduce(0) { total, conversation in
            hidden.contains("conversation:\(conversation.id.uuidString)") ? total : total + 1
        }
    }

    var launcherCatalogErrorMessage: String? {
        launcherCatalog?.loadErrorMessage
    }

    func reloadLauncherCatalog() {
        launcherCatalog?.reload()
        if let loadError = launcherCatalog?.loadErrorMessage {
            errorMessage = loadError
        }
        applicationSelectionIndex = 0
    }

    func clearClipboardHistory() {
        clipboardHistory?.clear()
        applicationSelectionIndex = 0
    }

    func copySelectedLauncherItem() {
        let matches = launcherMatches
        guard !matches.isEmpty else { return }
        let index = min(applicationSelectionIndex, matches.count - 1)
        guard case .item(let item) = matches[index] else { return }
        if item.kind == .snippet {
            Task { @MainActor in await insertSnippet(item, mode: .copy) }
            return
        }
        Task { @MainActor in await copyLauncherItem(item) }
    }

    @discardableResult
    func copyLauncherItem(_ item: LauncherCatalogItem) async -> Bool {
        if let payload = item.clipboardPayload {
            if payload.isPlainTextOnly {
                pasteboard.writeString(payload.text)
                markJustCopied()
                return true
            }
            // Restore the full representation (image, rich text, file, or a
            // custom format) from the blob, not just the string. Loads are
            // async (cache-first, disk off-main); a missing blob reports as
            // unavailable instead of clearing the user's clipboard.
            let full = await clipboardHistory?.payload(for: item) ?? payload
            guard pasteboard.writePayload(full) else {
                errorMessage = "That clipboard item is no longer available on this Mac."
                requestInputFocus()
                return false
            }
        } else if item.kind == .conversation || item.kind == .answer {
            // Copy Last Answer on a chat row and Copy Answer on a root
            // answer: an answer the app wrote, transient as `copyOutput`.
            pasteboard.writeTransientString(item.value)
        } else {
            // A snippet, a Quick Link, a clipboard entry: the user's own
            // text, which the Clipboard History records as usual.
            pasteboard.writeString(item.value)
        }
        markJustCopied()
        return true
    }

    @discardableResult
    func pasteLauncherItem(_ item: LauncherCatalogItem) async -> Bool {
        if item.isInlineTranslation, item.value.isEmpty {
            // Nothing to paste yet: never put an empty string on the clipboard.
            await performLauncherItem(item)
            return true
        }
        var target = selectionTarget
        if let selectedTextService {
            // A stale capture (app quit) or a missed one (opened from the
            // menu bar, or the window stack changed) falls back to asking
            // the window stack what sits behind the overlay right now.
            // Only a confirmed quit invalidates the capture; an unknown pid
            // (test stubs, odd processes) keeps its captured target.
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
            _ = await copyLauncherItem(item)
            errorMessage = "No text field was available behind Quick Launch. The item was copied instead."
            requestInputFocus()
            return false
        }
        // The overlay must stop being the key window before the target app is
        // activated and receives Command-V. Keeping the floating panel visible
        // until after paste lets it retain/retake keyboard focus.
        prepareForExternalAction?()
        await Task.yield()
        if let payload = item.clipboardPayload, !payload.isPlainTextOnly {
            // Image, rich text, file, or a custom format: restore the original
            // representation onto the pasteboard, then Command-V it in. Loads are
            // async (cache-first, disk off-main).
            let full = await clipboardHistory?.payload(for: item) ?? payload
            guard pasteboard.writePayload(full) else {
                recoverFromExternalActionFailure?()
                errorMessage = "That clipboard item is no longer available on this Mac."
                return false
            }
            let outcome = await selectedTextService.pastePasteboardOutcome(to: target)
            if outcome == .clipboardChanged {
                errorMessage = Self.clipboardChangedMessage
                recoverFromExternalActionFailure?()
                requestInputFocus()
                return false
            }
            guard outcome == .pasted else {
                _ = await copyLauncherItem(item)
                errorMessage = selectedTextService.isAccessibilityTrusted
                    ? "Could not paste into \(target.applicationName). The item was copied instead."
                    : "Allow Quick Launch in Privacy & Security → Accessibility, then try again. The item was copied."
                recoverFromExternalActionFailure?()
                requestInputFocus()
                return false
            }
            return true
        }
        let outcome = await selectedTextService.pasteOutcome(item.value, to: target)
        if outcome == .clipboardChanged {
            errorMessage = Self.clipboardChangedMessage
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        guard outcome == .pasted else {
            _ = await copyLauncherItem(item)
            errorMessage = selectedTextService.isAccessibilityTrusted
                ? "Could not paste into \(target.applicationName). The item was copied instead."
                : "Allow Quick Launch in Privacy & Security → Accessibility, then try again. The item was copied."
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        return true
    }

    @discardableResult
    func copyAndPasteLauncherItem(_ item: LauncherCatalogItem) async -> Bool {
        if item.isInlineTranslation, item.value.isEmpty { return await pasteLauncherItem(item) }
        let pasted = await pasteLauncherItem(item)
        _ = await copyLauncherItem(item)
        return pasted
    }

    func performLauncherItem(_ item: LauncherCatalogItem) async {
        // Every branch returns through here, so one deferred check covers
        // every item action that fails without instrumenting each branch.
        let priorError = errorMessage
        defer {
            noteActionFailure(itemID: item.id, scope: learningScope, priorError: priorError)
        }
        switch item.kind {
        case .quickLink:
            if item.requiresInput {
                pendingQuickLinkID = item.id
                catalogScope = nil
                input = ""
                requestInputFocus()
            } else {
                openQuickLink(item, input: "")
            }
        case .snippet:
            await insertSnippet(item, mode: .paste)
        case .clipboard, .emoji:
            _ = await pasteLauncherItem(item)
        case .screenshot:
            if item.screenshotMediaKind == .video {
                // A video is not an image: open it in its player instead of
                // trying to paste it as a picture.
                workspace.open(URL(fileURLWithPath: item.value))
                learn(.item(item))
                overlayPresenter.dismissOverlay()
                return
            }
            if await pasteImageFile(URL(fileURLWithPath: item.value)) {
                learn(.item(item))
                overlayPresenter.dismissOverlay()
            }
        case .conversation:
            if isRecentChatsPresented {
                // Continue Chat from the row's ⌘K pane: as Return on the row.
                recentChatsIndex = recentChatItems.firstIndex { $0.itemID == item.itemID } ?? recentChatsIndex
                openSelectedRecentChat()
            } else {
                continueChatInQuickAI(itemID: item.itemID)
            }
        case .folder:
            guard let location = folderLocation(for: item) else {
                errorMessage = "That folder is no longer available."
                requestInputFocus()
                return
            }
            input = ""
            prepareForExternalAction?()
            // Native open, not an AppleScript that fronts an existing Finder
            // window: that Apple Event could hang for minutes (measured 107 s).
            if workspace.open(location.expandedURL) {
                overlayPresenter.dismissOverlay()
            } else {
                recoverFromExternalActionFailure?()
                errorMessage = "Could not open \(location.title)."
                requestInputFocus()
            }
        case .answer:
            if item.isInlineTranslation, item.value.isEmpty, let query = inlineTranslation?.query {
                input = ""
                updateInlineTranslation()
                overlayPresenter.openTranslator(text: query.phrase, target: query.target)
                return
            }
            _ = await copyLauncherItem(item)
            input = ""
            rootAnswer = nil
            updateInlineTranslation()
            overlayPresenter.dismissOverlay()
        case .askAI:
            if item.value.isEmpty {
                // Empty root row or global hotkey: open Quick AI empty.
                openQuickAI()
                overlayPresenter.presentOverlay()
            } else {
                // The row carries the query: open Quick AI and send it in
                // the same gesture, exactly as Tab does. A local answer
                // stays in root search, as it does for Tab.
                input = item.value
                if answerTypedTextLocally() { return }
                openQuickAI()
                await submit()
            }
        case .application:
            return
        case .command:
            if let kind = ScreenshotKind(commandID: item.value) {
                if await attachScreenshot(kind, clearingInput: true) {
                    overlayPresenter.presentOverlay()
                }
                return
            }
            if item.value == LatestScreenshotFinder.commandID {
                if attachLatestScreenshot() {
                    overlayPresenter.presentOverlay()
                }
                return
            }
            if item.value == "awareness.area" {
                if await attachScreenArea() {
                    overlayPresenter.restoreAfterExternalAction()
                }
                return
            }
            if item.value == "awareness.selection" {
                if attachSelectedText() {
                    overlayPresenter.presentOverlay()
                }
                return
            }
            if item.value == "screenshot.pasteLatest" {
                await pasteLatestScreenshot()
                return
            }
            if item.value == "screenshot.save" {
                if await savePendingImageToScreenshots() != nil {
                    markJustSaved()
                }
                requestInputFocus()
                return
            }
            performSystemCommand(item)
        }
    }
}
