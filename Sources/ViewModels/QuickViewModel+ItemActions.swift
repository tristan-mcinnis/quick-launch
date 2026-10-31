import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// Item actions: the command-K pane and direct shortcuts.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - Item actions (⌘K pane and direct shortcuts)

    var isItemActionPanePresented: Bool {
        isCatalogActionPanePresented || isApplicationActionPanePresented
    }

    /// The result that ⌘K and direct shortcuts act on: the pane's item when a
    /// pane is open, otherwise the highlighted row.
    var focusedLauncherResult: LauncherSearchResult? {
        if isCatalogActionPanePresented, let item = contextualCatalogItem { return .item(item) }
        if isApplicationActionPanePresented, let application = contextualApplication {
            return .application(application)
        }
        // In Recent Chats the highlighted chat is the focused row: `⌘K` and
        // the row keys act on it, not on the chat that is open.
        if isRecentChatsPresented {
            let items = recentChatItems
            return items.indices.contains(recentChatsIndex) ? .item(items[recentChatsIndex]) : nil
        }
        let matches = launcherMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(applicationSelectionIndex, matches.count - 1)]
    }

    var focusedItemActions: [ItemAction] {
        guard let result = focusedLauncherResult else { return [] }
        var isRunning = false
        if case .application(let application) = result {
            isRunning = runningApplication(for: application) != nil
        }
        var actions = ItemActionCatalog.actions(
            for: result,
            pasteTarget: pasteTargetName,
            isRunning: isRunning,
            bindings: shortcuts
        )
        // Open in AI Chat needs a window to open, and the window itself has
        // no use for it.
        if aiChatOpener == nil || isAIChatWindow {
            actions.removeAll { $0.kind == .openInAIChat }
        }
        // Hiding is row state, not part of the static catalog: it depends on
        // whether the row is already hidden. A hidden row is filtered out of
        // the list, so this is always the "hide me" direction. It sits just
        // above Delete so the destructive action stays last.
        if let hide = hideAction(for: result) {
            if let deleteIndex = actions.firstIndex(where: { $0.kind == .delete }) {
                actions.insert(hide, at: deleteIndex)
            } else {
                actions.append(hide)
            }
        }
        // In the Screenshots catalog the capture and AI commands ride along
        // in every ⌘K pane; the list itself stays a pure file list.
        if catalogScope == .screenshots {
            actions.append(contentsOf: screenAwarenessActions)
        }
        if deleteArmedItemID == result.id,
           let index = actions.firstIndex(where: { $0.kind == .delete }) {
            actions[index] = ItemAction(
                kind: .delete,
                title: "Confirm Delete",
                systemImage: "trash.fill",
                shortcut: actions[index].shortcut,
                isDestructive: true
            )
        }
        return actions
    }

    /// The "Hide from Quick Launch" row for a result, or nil when the row is
    /// not hideable or already hidden.
    private func hideAction(for result: LauncherSearchResult) -> ItemAction? {
        switch result {
        case .application(let application):
            guard !isApplicationHidden(application) else { return nil }
        case .item(let item):
            guard item.canBeHidden, !isLauncherItemHidden(item) else { return nil }
        case .catalog:
            return nil
        }
        return ItemAction(
            kind: .hideFromLauncher,
            title: "Hide from Quick Launch",
            systemImage: "eye.slash",
            shortcut: nil
        )
    }

    /// The pane's rows after the search filter, best match first — typing
    /// "un" puts "Unpin" above a scattered match like "Attach to Question".
    /// The view renders exactly this list and the window sizes to it.
    var filteredFocusedItemActions: [ItemAction] {
        let all = focusedItemActions
        guard !actionQuery.isEmpty else { return all }
        return Self.rankByQuery(all, query: actionQuery, title: \.title)
    }

    /// Result actions after the palette's search filter, best match first.
    /// On the Quick AI surface Tools is offered before the first answer too,
    /// so a chat's tools can be chosen before it starts.
    var paletteResultActions: [ResultAction] {
        var actions = resultActions
        if isQuickAIPresented, !actions.contains(.tools) { actions.append(.tools) }
        // Change Assistant is on the Quick AI surface before the first
        // answer too: picking one is how an assistant chat starts.
        if isQuickAIPresented, !assistants.isEmpty, !actions.contains(.changeAssistant) {
            actions.append(.changeAssistant)
        }
        // Recent Chats (`⌘P`) is on the Quick AI surface before the first
        // answer too, as its key is.
        if isQuickAIPresented, !isAIChatWindow, canOpenRecentChats, !actions.contains(.recentChats) {
            actions.append(.recentChats)
        }
        guard !actionQuery.isEmpty else { return actions }
        return Self.rankByQuery(actions, query: actionQuery, title: resultActionTitle)
    }

    /// Actions on the Quick AI window itself, while the surface is up:
    /// Reset Quick AI Size once the user has dragged it off 750 × 475.
    var quickAISurfaceActions: [QuickAISurfaceAction] {
        var composerActions: [QuickAISurfaceAction] = canOpenAttachments ? [.attach] : []
        if isQuickAIPresented, webSearchService != nil { composerActions.append(.searchSettings) }
        // The AI Chat window offers its own: the chat list, find, and
        // Keep on Top.
        if let chatWindowHost { return composerActions + chatWindowHost.windowSurfaceActions + messageSurfaceActions }
        guard isQuickAIPresented else { return [] }
        return composerActions + (settings.quickAISize.isStandard ? [] : [.resetSize]) + messageSurfaceActions
    }

    /// Copy Message and Capture Message to Memory, while the chat has a
    /// message to act on: every question and answer, not only the newest.
    var messageSurfaceActions: [QuickAISurfaceAction] {
        guard isQuickAIPresented, !paletteMessages.isEmpty else { return [] }
        return memoryCapture == nil ? [.copyMessage] : [.copyMessage, .captureMessage]
    }

    /// Surface actions after the palette's search filter, best match first.
    var paletteSurfaceActions: [QuickAISurfaceAction] {
        guard !actionQuery.isEmpty else { return quickAISurfaceActions }
        return Self.rankByQuery(quickAISurfaceActions, query: actionQuery, title: \.title)
    }

    func performQuickAISurfaceAction(_ action: QuickAISurfaceAction) {
        if action == .searchSettings {
            openActionPaletteSubmenu(.searchProviders)
            return
        }
        // Copy Message and Capture Message keep the palette, on its list of
        // the chat's messages.
        if action == .copyMessage || action == .captureMessage {
            openActionPaletteSubmenu(.messages(action == .copyMessage ? .copy : .capture))
            return
        }
        isActionPalettePresented = false
        actionQuery = ""
        switch action {
        case .attach:
            openAddContextMenu()
        case .resetSize:
            resetQuickAISize()
        case .copyMessage, .captureMessage, .searchSettings:
            return
        case .showChatList, .hideChatList, .findInChat, .keepOnTop, .stopKeepingOnTop:
            chatWindowHost?.performWindowSurfaceAction(action)
            // Find and the chat list take the focus themselves.
            return
        }
        requestInputFocus()
    }

    /// Attach commands offered in the ⌘K palette, at the root and on an
    /// answer alike, so a screenshot or a selection can join the question
    /// without abandoning the typed text to reach the root search.
    var paletteAttachCommands: [LauncherCatalogItem] {
        let ids = [
            LatestScreenshotFinder.commandID,
            ScreenshotKind.window.commandID,
            ScreenshotKind.display.commandID,
            "awareness.area",
            "awareness.selection",
        ]
        let commands = systemCommands
        return ids.compactMap { id in commands.first { $0.itemID == id } }
    }

    /// Palette attach commands after the search filter, best match first.
    var paletteCommandMatches: [LauncherCatalogItem] {
        guard !actionQuery.isEmpty else { return paletteAttachCommands }
        return Self.rankByQuery(paletteAttachCommands, query: actionQuery, title: \.title)
    }

    /// Run a command row from the ⌘K palette. The typed-command path clears
    /// the input because there the input *is* the command; here the
    /// half-typed question survives the attach.
    func runPaletteCommand(_ item: LauncherCatalogItem) async {
        isActionPalettePresented = false
        actionQuery = ""
        let typed = input
        await performLauncherItem(item)
        if input.isEmpty, !typed.isEmpty { input = typed }
    }

    /// Fuzzy-filters and orders by match score; ties keep the list order.
    static func rankByQuery<T>(
        _ items: [T],
        query: String,
        title: (T) -> String
    ) -> [T] {
        let folded = FuzzyMatcher.fold(query)
        return items.enumerated()
            .compactMap { index, item -> (item: T, score: Int, index: Int)? in
                guard let score = FuzzyMatcher.score(
                    foldedQuery: folded,
                    foldedCandidate: FuzzyMatcher.fold(title(item))
                ) else { return nil }
                return (item, score, index)
            }
            .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
            .map(\.item)
    }

    /// Row count the prompt palette will render, for window sizing.
    var actionPaletteEntryCount: Int {
        switch actionPaletteSubmenu {
        case .tools: paletteToolRows.count
        case .searchProviders: paletteSearchProviders.count
        case .sources: paletteSourceRows.count
        case .messages: paletteMessageRows.count
        case nil:
            paletteResultActions.count + paletteSurfaceActions.count
                + paletteCommandMatches.count + actionMatches.count
        }
    }

    func openActionPane(for result: LauncherSearchResult, form: ItemActionForm? = nil) {
        switch result {
        case .application(let application):
            contextualApplicationID = application.id
            isApplicationActionPanePresented = true
            isCatalogActionPanePresented = false
            contextualCatalogItemID = nil
        case .item(let item):
            contextualCatalogItemID = item.id
            isCatalogActionPanePresented = true
            isApplicationActionPanePresented = false
            contextualApplicationID = nil
        case .catalog:
            return
        }
        isActionPalettePresented = false
        actionQuery = ""
        activeItemActionForm = form
        deleteArmedItemID = nil
        noteInteraction()
    }

    func closeItemActionPane() {
        isCatalogActionPanePresented = false
        isApplicationActionPanePresented = false
        contextualCatalogItemID = nil
        contextualApplicationID = nil
        activeItemActionForm = nil
        deleteArmedItemID = nil
        actionQuery = ""
        requestInputFocus()
        noteInteraction()
    }

    func closeActionPalette() {
        isActionPalettePresented = false
        actionPaletteSubmenu = nil
        actionQuery = ""
        requestInputFocus()
    }

    func perform(action: SavedPrompt) async {
        // With nothing selected, an assistant is picked, not run: the
        // palette row and its hotkey start or switch the Quick AI chat to
        // it, and nothing is sent. With a selection it runs its prompt on
        // the selection, as any saved prompt does.
        if action.isAssistant, !hasSelectedActionSource {
            isActionPalettePresented = false
            actionQuery = ""
            selectAssistant(action)
            return
        }
        let source: String
        // Explicit Screen Awareness selection, then text typed into the
        // launcher, then the launch-scoped background selection, then a fresh
        // capture. Typed text beats the auto-captured snapshot; stale
        // on-screen output is never used as the source.
        if let attached = pendingContext?.selectedText,
           !attached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = attached
        } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let launchSelection,
                  !launchSelection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = launchSelection.text
        } else if let selected = captureSelectedText(promptForPermission: true),
                  !selected.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = selected.text
        } else {
            closeActionPalette()
            errorMessage = selectedTextService?.isAccessibilityTrusted == false
                ? "Allow Accessibility in System Settings, then select text and try again."
                : "Select some text, or type text in the input field, then run this action."
            requestInputFocus()
            return
        }

        pendingActionSource = source
        isActionPalettePresented = false
        actionQuery = ""
        // Bare alias; the source travels via pendingActionSource so a
        // multi-line selection is never whitespace-collapsed by alias context.
        input = settings.savedPromptPrefix + action.alias
        await submit()
    }
}
