import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// The layer stack: Escape and empty Backspace.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - Layer stack (Escape and empty Backspace)

    /// What sits on top of the overlay right now, from the outermost UI
    /// layer down to the root. Escape and an empty Backspace both pop this
    /// stack; the only difference is what they do at the answer and root.
    enum OverlayLayer: Equatable, Sendable {
        case itemActionForm
        case itemActionPane
        case actionPalette
        case transformChooser
        /// A `.reviewChanges` transform's original/proposed card.
        case transformReview
        /// A required `{argument}` free-text slot the Transform field is
        /// asking for (its own field; the composer draft is untouched).
        case transformArgumentField
        case modelChooser
        case assistantChooser
        case captureChooser
        case addContextMenu
        /// The composer's `/` palette. Above `typedText`, because the draft
        /// that opened it is the text underneath.
        case slashCommandPalette
        case recentChats
        case streaming
        case attachment
        case typedText
        case answer
        /// A local answer inline in root search.
        case localAnswer
        case inputMode
        case catalog
        case quickLinkInput
        /// A house command's choices, shown as launcher rows.
        case houseCommandChoice
        case root
    }

    var topLayer: OverlayLayer {
        if isItemActionPanePresented {
            return activeItemActionForm != nil ? .itemActionForm : .itemActionPane
        }
        if isActionPalettePresented { return .actionPalette }
        if isTransformReviewVisible { return .transformReview }
        if isTransformArgumentFieldPresented { return .transformArgumentField }
        if isTransformChooserPresented { return .transformChooser }
        if isModelChooserPresented { return .modelChooser }
        if isAssistantChooserPresented { return .assistantChooser }
        if isCaptureChooserPresented { return .captureChooser }
        if isAddContextMenuPresented { return .addContextMenu }
        if isSlashCommandPalettePresented { return .slashCommandPalette }
        if isRecentChatsPresented { return .recentChats }
        if isStreaming { return .streaming }
        if !input.isEmpty { return .typedText }
        if hasPendingAttachment { return .attachment }
        if isAnswerActive { return .answer }
        if rootAnswer != nil { return .localAnswer }
        if inputMode != nil { return .inputMode }
        if pendingHouseChoice != nil { return .houseCommandChoice }
        if pendingQuickLinkID != nil { return .quickLinkInput }
        if catalogScope != nil { return .catalog }
        return .root
    }

    /// Removes one layer. Returns `false` at the root, where there is
    /// nothing left to pop.
    @discardableResult
    func popTopLayer() -> Bool {
        switch topLayer {
        case .itemActionForm, .itemActionPane:
            dismissItemActionLayer()
        case .actionPalette:
            if actionPaletteSubmenu != nil {
                // A second list goes back to the full one first.
                actionPaletteSubmenu = nil
                actionQuery = ""
            } else {
                closeActionPalette()
            }
        case .transformChooser:
            closeTransformChooser()
        case .transformReview:
            cancelTransformReview()
        case .transformArgumentField:
            cancelTransformArguments()
        case .modelChooser:
            closeModelChooser()
        case .assistantChooser:
            closeAssistantChooser()
        case .captureChooser:
            closeCaptureChooser()
        case .addContextMenu:
            // The Link field and the Clipboard History submenu each go back
            // to the Add Context rows first.
            if attachmentTray.cancelLinkEntry() {
                requestInputFocus()
            } else if isClipboardHistoryOpen {
                closeClipboardHistory()
            } else {
                closeAddContextMenu()
            }
        case .slashCommandPalette:
            // Escape leaves the draft alone: the `/` the user typed is
            // theirs, only the list goes.
            closeSlashCommandPalette()
            requestInputFocus()
        case .recentChats:
            popRecentChatsLayer()
        case .streaming:
            cancel()
        case .typedText:
            input = ""
            errorMessage = nil
            requestInputFocus()
        case .attachment:
            removePendingImage()
        case .answer:
            // Back to root search; the thread is kept behind it.
            closeQuickAI()
        case .localAnswer:
            rootAnswer = nil
            requestInputFocus()
        case .inputMode:
            leaveInputMode()
        case .houseCommandChoice:
            pendingHouseChoice = nil
            input = ""
            errorMessage = nil
            invalidateLauncherRanking()
            requestInputFocus()
        case .quickLinkInput, .catalog:
            leaveCatalog()
        case .root:
            return false
        }
        return true
    }

    /// Backspace on an empty field pops one layer: attachment, answer,
    /// mode, catalog, or Quick Link input. Returns `false` when there is
    /// nothing to pop so the key deletes text as usual.
    @discardableResult
    func popLayerForEmptyBackspace() -> Bool {
        guard input.isEmpty, !isItemActionPanePresented, !isActionPalettePresented else { return false }
        if isModelChooserPresented {
            closeModelChooser()
            return true
        }
        if isAssistantChooserPresented {
            closeAssistantChooser()
            return true
        }
        if isAddContextMenuPresented {
            // Backspace in the Link field edits the link.
            if attachmentTray.isEnteringLink { return false }
            // Backspace in the pane's own search edits the query.
            if !addContextQuery.isEmpty { return false }
            closeAddContextMenu()
            return true
        }
        if isCaptureChooserPresented, !captureChooserQuery.isEmpty {
            // Backspace in the chooser's own search edits the query.
            return false
        }
        return popTopLayer()
    }

    /// Escape is handled at the NSPanel boundary so it works even when a
    /// SwiftUI field editor consumes cancelOperation. It walks the same
    /// stack as Backspace, with one difference: the root hides the overlay.
    /// On the Quick AI surface Escape stops a stream, else returns to root
    /// search with the thread kept; a second Escape there closes the window.
    @discardableResult
    func handleEscapeKey() -> Bool {
        switch topLayer {
        case .root:
            overlayPresenter.dismissOverlay()
        default:
            popTopLayer()
        }
        return true
    }

    /// Escape: a form goes back to the list, the list closes the pane.
    func dismissItemActionLayer() {
        if activeItemActionForm != nil {
            activeItemActionForm = nil
            deleteArmedItemID = nil
            noteInteraction()
        } else {
            closeItemActionPane()
        }
    }

    func handleCommandK() {
        if isItemActionPanePresented {
            closeItemActionPane()
            return
        }
        if let result = focusedLauncherResult, case .catalog = result {
            // Catalog roots have no actions; fall through to the prompt palette.
        } else if let result = focusedLauncherResult {
            openActionPane(for: result)
            return
        }
        // Recent Chats with no row highlighted (the search matches nothing):
        // `⌘K` acts on rows here, never on the chat that is open.
        if isRecentChatsPresented { return }
        toggleActionPalette()
    }

    /// The keys a Recent Chats row answers to: Open in AI Chat (⌘J), Copy
    /// Last Answer (⌘↩), Rename (⌘E), Pin (⇧⌘P), and Delete (⌃X). With no
    /// row highlighted they do nothing, never act on the chat that is open.
    /// The actions a Recent Chats row answers to: Open in AI Chat, Copy Last
    /// Answer, Rename, Pin, and Delete. Read through `shortcuts`, so a rebind
    /// is what the row matches and what the row draws.
    private static let recentChatsRowActions: [ShortcutAction] =
        [.continueInAIChat, .renameChat, .pinChat, .deleteChat]

    /// Direct shortcuts from the list or the pane (⌘↩, ⌘E, ⌃X, ⌘⇧A…).
    /// Returns `false` when nothing matched so the key reaches SwiftUI.
    func performShortcut(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        // ⌘K by default: the action palette, or the pane the surface is in.
        // The launcher's own panel takes this key before the model sees it;
        // the AI Chat window and every other caller reach it here, so both
        // routes answer the resolved key rather than a hardcoded one.
        if shortcuts.matches(
            .commandPalette,
            characters: characters,
            keyCode: keyCode,
            modifiers: modifiers
        ) {
            handleCommandK()
            return true
        }
        if shortcuts.matches(
            .recentChats,
            characters: characters,
            keyCode: keyCode,
            modifiers: modifiers
        ) {
            toggleRecentChats()
            return true
        }
        // ⌘J on the Quick AI surface: Open in AI Chat, as in Raycast,
        // before the first answer too; in Recent Chats, the highlighted chat.
        if offersContinueInAIChat, !isItemActionPanePresented,
           shortcuts.matches(
               .continueInAIChat,
               characters: characters,
               keyCode: keyCode,
               modifiers: modifiers
           ) {
            continueInAIChat()
            return true
        }
        // ⌘⌥T toggles the keyboard-first Transform chooser (reachable without a
        // mouse); while it is open ↑↓ and Return drive it in the view.
        if shortcuts.matches(
            .transformChooser,
            characters: characters,
            keyCode: keyCode,
            modifiers: modifiers
        ) {
            toggleTransformChooser()
            return true
        }
        if shortcuts.matches(
            .transcriptCollapse,
            characters: characters,
            keyCode: keyCode,
            modifiers: modifiers
        ), let id = keyboardToggleMessageID {
            toggleTranscriptMessage(id)
            return true
        }
        // ⌘↑ ⌘↓ ⌥↑ ⌥↓ and a modified PageUp or PageDown move the thread; the
        // field editor would take them otherwise.
        if let key = Self.threadKey(keyCode: keyCode),
           modifiers == [.command] || modifiers == [.option] || key == .pageUp || key == .pageDown,
           handleThreadKey(key, command: modifiers == [.command], option: modifiers == [.option]) {
            return true
        }
        // In Recent Chats a row's own keys (rename, pin, delete, copy) act on
        // the highlighted chat, before the open chat's answer actions.
        if isRecentChatsPresented, performFocusedItemShortcut(
            characters: characters,
            keyCode: keyCode,
            modifiers: modifiers
        ) {
            return true
        }
        // No row took it (the search matches nothing): a row key is
        // swallowed rather than passed to the open chat's answer actions.
        if isRecentChatsPresented,
           Self.recentChatsRowActions.contains(where: {
               shortcuts.matches(
                   $0,
                   characters: characters,
                   keyCode: keyCode,
                   modifiers: modifiers
               )
           }) || KeyShortcut.commandReturn.matches(
               characters: characters,
               keyCode: keyCode,
               modifiers: modifiers
           ) {
            return true
        }
        // Change Model works on the Quick AI surface before the first answer
        // too: the empty surface names this key, and so does the header's
        // model line.
        if isQuickAIPresented, !isItemActionPanePresented,
           shortcuts.matches(
               .changeModel,
               characters: characters,
               keyCode: keyCode,
               modifiers: modifiers
           ) {
            openModelChooser(.change)
            return true
        }
        if canOpenAttachments,
           shortcuts.matches(
               .attachMenu,
               characters: characters,
               keyCode: keyCode,
               modifiers: modifiers
           ) {
            toggleAddContextMenu()
            return true
        }
        // The window key opens the capture chooser: it never attaches
        // anything on its own, so what rides the question is always the row
        // the user highlighted. The panel takes it before the model sees it;
        // the AI Chat window reaches it here.
        if canOpenAttachments, shortcuts.matches(
            .attachWindow, characters: characters, keyCode: keyCode, modifiers: modifiers
        ) {
            openCaptureChooser()
            return true
        }
        if canOpenAttachments, shortcuts.matches(
            .attachDisplay, characters: characters, keyCode: keyCode, modifiers: modifiers
        ) {
            Task { @MainActor in await attachScreenshot(.display, clearingInput: false) }
            return true
        }
        // Tools opens on the surface before the first answer too.
        if isQuickAIPresented, !isItemActionPanePresented, activeItemActionForm == nil,
           shortcuts.matches(
               .tools,
               characters: characters,
               keyCode: keyCode,
               modifiers: modifiers
           ) {
            openActionPaletteSubmenu(.tools)
            return true
        }
        // Change Assistant, too: picking one is how an assistant chat starts.
        if isQuickAIPresented, !isItemActionPanePresented,
           shortcuts.matches(
               .changeAssistant,
               characters: characters,
               keyCode: keyCode,
               modifiers: modifiers
           ) {
            toggleAssistantChooser()
            return true
        }
        if isAnswerActive, !isItemActionPanePresented, activeItemActionForm == nil,
           let action = resultActions.first(where: {
               shortcuts.matches(
                   ShortcutAction.forResultAction($0),
                   characters: characters,
                   keyCode: keyCode,
                   modifiers: modifiers
               )
           }) {
            Task { await performResultAction(action) }
            return true
        }
        return performFocusedItemShortcut(characters: characters, keyCode: keyCode, modifiers: modifiers)
    }

    /// The thread key a virtual key code names, if any.
    static func threadKey(keyCode: UInt16) -> ThreadKey? {
        switch VirtualKey(rawValue: keyCode) {
        case .upArrow: .up
        case .downArrow: .down
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        default: nil
        }
    }

    /// A shortcut of the focused row's `⌘K` actions (the launcher row, or
    /// the highlighted Recent Chats row). Returns `false` when none matched.
    private func performFocusedItemShortcut(
        characters: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard pendingImage == nil,
              !isActionPalettePresented,
              activeItemActionForm == nil,
              let result = focusedLauncherResult
        else { return false }
        guard let action = focusedItemActions.first(where: {
            $0.shortcut?.matches(characters: characters, keyCode: keyCode, modifiers: modifiers) == true
        }), action.kind != .primary else { return false }
        if !performSynchronously(action, on: result) {
            Task { await perform(action, on: result) }
        }
        return true
    }

    func perform(_ action: ItemAction, on result: LauncherSearchResult) async {
        if performSynchronously(action, on: result) { return }
        switch action.kind {
        case .primary:
            closeItemActionPane()
            await performLauncherResult(result)
        case .copyAndPaste:
            guard case .item(let item) = result else { return }
            closeItemActionPane()
            if item.kind == .screenshot {
                attachScreenshotFile(item)
            } else if item.kind == .snippet {
                await insertSnippet(item, mode: .copyAndPaste)
            } else {
                _ = await copyAndPasteLauncherItem(item)
            }
        case .runCommand:
            guard let value = action.commandValue,
                  let command = systemCommands.first(where: { $0.value == value })
            else { return }
            closeItemActionPane()
            await performLauncherItem(command)
        case .copyTextFromImage:
            guard case .item(let item) = result else { return }
            closeItemActionPane()
            _ = await copyTextFromImage(item)
        case .copyQRCode:
            guard case .item(let item) = result else { return }
            closeItemActionPane()
            _ = await copyQRCode(from: item)
        case .pasteAsPlainText:
            guard case .item(let item) = result, item.kind == .clipboard else { return }
            closeItemActionPane()
            _ = await pasteClipboardEntryAsPlainText(item)
        case .attachToQuestion:
            guard case .item(let item) = result, item.kind == .clipboard else { return }
            closeItemActionPane()
            _ = await attachClipboardEntryToQuestion(item)
        case .annotateInPreview:
            guard case .item(let item) = result, item.kind == .screenshot else { return }
            closeItemActionPane()
            await annotateInPreview(item)
        case .renameEntry:
            guard case .item(let item) = result, item.kind == .clipboard else { return }
            enterInputMode(.renameClipboard(item.itemID))
        case .openEntry:
            guard case .item(let item) = result, item.kind == .clipboard else { return }
            closeItemActionPane()
            _ = openClipboardEntry(item)
        case .saveAsFile:
            guard case .item(let item) = result, item.kind == .clipboard else { return }
            closeItemActionPane()
            _ = await saveClipboardEntryAsFile(item)
        default:
            break
        }
    }

    /// Actions that finish without awaiting anything. Returns `false` for
    /// the two that paste, which must await the previous app.
    @discardableResult
    private func performSynchronously(_ action: ItemAction, on result: LauncherSearchResult) -> Bool {
        if action.kind != .delete { deleteArmedItemID = nil }
        switch action.kind {
        case .primary, .copyAndPaste, .runCommand,
             .copyTextFromImage, .copyQRCode, .pasteAsPlainText,
             .attachToQuestion, .annotateInPreview, .renameEntry,
             .openEntry, .saveAsFile:
            return false
        case .quit, .forceQuit, .hide, .relaunch:
            guard case .application(let application) = result else { return true }
            controlRunningApplication(application, action: action.kind)
        case .hideFromLauncher:
            switch result {
            case .application(let application):
                hideApplication(application)
            case .item(let item):
                _ = hideLauncherItem(item)
            case .catalog:
                return true
            }
        case .openInAIChat:
            guard case .item(let item) = result, item.kind == .conversation else { return true }
            openChatInAIChat(itemID: item.itemID)
        case .copyCleanLink:
            guard case .item(let item) = result, let cleaned = URLCleaner.clean(item.value) else { return true }
            pasteboard.writeString(cleaned)
            markJustCopied()
            closeItemActionPane()
            input = ""
            overlayPresenter.dismissOverlay()
        case .secondary:
            switch result {
            case .application(let application):
                revealInFinder(application)
            case .item(let item) where item.kind == .folder:
                guard let location = folderLocation(for: item) else { return true }
                closeItemActionPane()
                input = ""
                overlayPresenter.dismissOverlay()
                workspace.revealInFileViewer([location.expandedURL])
            case .item(let item) where item.kind == .answer:
                closeItemActionPane()
                Task { _ = await pasteLauncherItem(item) }
            case .item(let item) where item.kind == .screenshot:
                if item.screenshotMediaKind == .video {
                    // A video has no image representation to paste: reveal it.
                    closeItemActionPane()
                    input = ""
                    overlayPresenter.dismissOverlay()
                    workspace.revealInFileViewer([URL(fileURLWithPath: item.value)])
                } else if pasteboard.writeImageFile(at: URL(fileURLWithPath: item.value)) {
                    markJustCopied()
                    closeItemActionPane()
                    input = ""
                    overlayPresenter.dismissOverlay()
                } else {
                    errorMessage = "Could not read \(item.title)."
                    requestInputFocus()
                }
            case .item(let item) where item.kind == .snippet:
                // Copy expands the snippet's placeholders too: what lands on
                // the clipboard is what a paste would have typed.
                closeItemActionPane()
                Task { @MainActor in
                    await insertSnippet(item, mode: .copy, dismissingOverlay: true)
                }
            case .item(let item):
                Task { @MainActor in _ = await copyLauncherItem(item) }
                closeItemActionPane()
                input = ""
                overlayPresenter.dismissOverlay()
            case .catalog:
                break
            }
        case .pin:
            guard case .item(let item) = result else { return true }
            switch item.kind {
            case .conversation:
                guard let id = UUID(uuidString: item.itemID) else { return true }
                togglePinConversation(id: id)
                // Pinned chats sort first: the highlight follows the chat.
                if isRecentChatsPresented {
                    closeItemActionPane()
                    recentChatsIndex = recentChatItems.firstIndex { $0.itemID == item.itemID } ?? 0
                    return true
                }
            case .clipboard:
                clipboardHistory?.togglePin(item)
            case .snippet, .quickLink, .screenshot, .askAI, .folder:
                togglePinLauncherItem(item)
            default:
                return true
            }
            invalidateLauncherRanking()
            closeItemActionPane()
            applicationSelectionIndex = 0
        case .saveAsSnippet:
            guard case .item(let item) = result else { return true }
            saveClipboardEntry(item, asLink: false)
        case .saveAsQuickLink:
            guard case .item(let item) = result else { return true }
            saveClipboardEntry(item, asLink: true)
        case .revealInFinder:
            guard case .item(let item) = result else { return true }
            guard item.kind == .screenshot else { return true }
            closeItemActionPane()
            input = ""
            overlayPresenter.dismissOverlay()
            workspace.revealInFileViewer([URL(fileURLWithPath: item.value)])
        case .quickLook:
            guard case .item(let item) = result, item.kind == .screenshot else { return true }
            ScreenshotLibrary.quickLook(URL(fileURLWithPath: item.value))
        case .edit:
            if case .item(let item) = result, item.kind == .conversation, let id = UUID(uuidString: item.itemID) {
                let fromRecentChats = isRecentChatsPresented
                enterInputMode(.renameChat(id))
                renameReturnsToRecentChats = fromRecentChats
                return true
            }
            openActionPane(for: result, form: .edit)
        case .setAlias:
            openActionPane(for: result, form: .alias)
        case .setHotkey:
            openActionPane(for: result, form: .hotkey)
        case .copyUnicode:
            guard case .item(let item) = result, item.kind == .emoji else { return true }
            pasteboard.writeString(EmojiCatalog.unicodeNotation(of: item.value))
            markJustCopied()
            closeItemActionPane()
        case .copyPath:
            let path: String
            switch result {
            case .application(let application): path = application.url.path
            case .item(let item) where item.kind == .screenshot || item.kind == .folder: path = item.value
            default: return true
            }
            pasteboard.writeString(path)
            markJustCopied()
            closeItemActionPane()
        case .delete:
            guard case .item(let item) = result else { return true }
            if deleteArmedItemID == result.id {
                deleteArmedItemID = nil
                switch item.kind {
                case .snippet:
                    _ = deleteSnippet(item)
                case .clipboard:
                    clipboardHistory?.remove(item)
                    closeItemActionPane()
                    applicationSelectionIndex = 0
                case .conversation:
                    if let id = UUID(uuidString: item.itemID) { deleteConversation(id: id) }
                    closeItemActionPane()
                    if isRecentChatsPresented {
                        recentChatsIndex = min(recentChatsIndex, max(recentChatItems.count - 1, 0))
                    }
                case .quickLink:
                    _ = deleteQuickLink(item)
                case .folder:
                    removeCustomFolder(item)
                    closeItemActionPane()
                    applicationSelectionIndex = 0
                case .screenshot:
                    let url = URL(fileURLWithPath: item.value)
                    do {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        removeLauncherItemConfiguration(for: item)
                        reloadScreenshotFiles()
                        closeItemActionPane()
                        applicationSelectionIndex = 0
                    } catch {
                        errorMessage = "Could not move \(item.title) to the Trash."
                        requestInputFocus()
                    }
                default:
                    break
                }
            } else {
                if !isItemActionPanePresented { openActionPane(for: result) }
                deleteArmedItemID = result.id
                noteInteraction()
            }
        }
        return true
    }
}
