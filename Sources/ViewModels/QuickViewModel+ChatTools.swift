import Foundation

/// The second list a `⌘K` palette row can open.
enum ActionPaletteSubmenu: Equatable, Sendable {
    /// The chat's tools, each toggled with Return.
    case tools
    /// The answer's sources, each opened with Return.
    case sources
}

/// Tools inside the chat: which ones a chat lets the model call, the lines
/// their calls leave in the thread, the answer's sources, and Capture to
/// Memory.
extension QuickViewModel {

    // MARK: - The chat's tools

    /// The tools the next request offers: the open chat's own set, the set
    /// chosen on the empty surface, or the defaults (memory, vault, and
    /// skills on; web search per Settings).
    var chatTools: Set<ChatToolKind> {
        currentConversation?.enabledTools
            ?? pendingChatTools
            ?? ChatToolKind.defaults(webSearchEnabled: settings.modelWebSearchEnabled)
    }

    /// Whether this Mac has the backend a tool needs. A tool that is on but
    /// unavailable is simply not offered to the model.
    func isChatToolAvailable(_ kind: ChatToolKind) -> Bool {
        switch kind {
        case .memory: memoryService != nil
        case .vault: vaultSearchService != nil
        case .skills: skillLibrary != nil
        case .web: webSearchService != nil
        }
    }

    /// "Memory, Vault, Skills on", for the Tools row's detail.
    var chatToolsSummary: String {
        let on = ChatToolKind.allCases.filter { chatTools.contains($0) }
        return on.isEmpty ? "All off" : on.map(\.displayName).joined(separator: ", ") + " on"
    }

    /// Turns one tool on or off for this chat. A chat with turns keeps the
    /// choice in history; before the first question it waits for the chat
    /// the question starts.
    func toggleChatTool(_ kind: ChatToolKind) {
        var tools = chatTools
        if tools.contains(kind) { tools.remove(kind) } else { tools.insert(kind) }
        if currentConversation != nil {
            currentConversation?.enabledTools = tools
            if !conversationMessages.isEmpty { persistCurrentConversation() }
        } else {
            pendingChatTools = tools
        }
    }

    /// Tools rows in the palette, narrowed by its search field.
    var paletteToolRows: [ChatToolKind] {
        guard !actionQuery.isEmpty else { return ChatToolKind.allCases }
        return Self.rankByQuery(ChatToolKind.allCases, query: actionQuery, title: \.displayName)
    }

    /// Opens the `⌘K` palette on one of its second lists.
    func openActionPaletteSubmenu(_ submenu: ActionPaletteSubmenu) {
        if !isActionPalettePresented {
            closeItemActionPane()
            isActionPalettePresented = true
        }
        isModelChooserPresented = false
        isAddContextMenuPresented = false
        actionPaletteSubmenu = submenu
        actionQuery = ""
    }

    // MARK: - Tool lines

    /// A finished call from the stream. The context line is one per answer
    /// and carries the running total, so a newer one replaces the older.
    func noteLiveToolRecord(_ record: ChatToolRecord) {
        if record.kind == .context,
           let index = liveToolRecords.firstIndex(where: { $0.kind == .context }) {
            liveToolRecords[index] = record
        } else {
            liveToolRecords.append(record)
        }
    }

    /// The lines an answer keeps: an explicit web search first (it ran
    /// before the model was called), then every call in the order it ran.
    func answerToolRecords(usedWebSearch: Bool) -> [ChatToolRecord] {
        var records: [ChatToolRecord] = []
        if usedWebSearch, let note = webSearchNote {
            records.append(ChatToolRecord(kind: .web, summary: note))
        }
        return records + liveToolRecords
    }

    /// The answer on screen as a thread turn, or nil for a detached answer
    /// (a local answer, a Vault Search, a command's output).
    private var answerMessageIndex: Int? {
        guard !output.isEmpty,
              let index = currentConversation?.messages.lastIndex(where: { $0.role == .assistant }),
              currentConversation?.messages[index].content == output
        else { return nil }
        return index
    }

    /// Sources of the answer on screen that name a file on this Mac: what
    /// Open Source offers.
    var answerSources: [ChatSource] {
        guard let index = answerMessageIndex,
              let message = currentConversation?.messages[index]
        else { return [] }
        return message.sources.filter { $0.path != nil }
    }

    /// Source rows in the palette, narrowed by its search field.
    var paletteSourceRows: [ChatSource] {
        let sources = answerSources
        guard !actionQuery.isEmpty else { return sources }
        return Self.rankByQuery(sources, query: actionQuery, title: \.title)
    }

    // MARK: - Open Source

    /// Opens one source with `/usr/bin/open`, then gets out of the way the
    /// way a Quick Link does. Only a document file inside the memory store
    /// or the vault clone is opened; anything else says why in the error
    /// line.
    func openSource(_ source: ChatSource) async {
        isActionPalettePresented = false
        actionPaletteSubmenu = nil
        actionQuery = ""
        guard let fileOpener else { return }
        guard let url = ChatSource.openableURL(for: source.path, roots: sourceRoots) else {
            errorMessage = "\(source.title) is not a file on this Mac."
            requestInputFocus()
            return
        }
        do {
            try await fileOpener.open(url)
            errorMessage = nil
            overlayPresenter.dismissOverlay()
        } catch {
            errorMessage = "Could not open \(source.title): \(error.localizedDescription)"
            requestInputFocus()
        }
    }

    /// Open Source from a click on a source row or a palette row: the open
    /// runs on a stored task, so a view never starts one it cannot track.
    func requestOpenSource(_ source: ChatSource) {
        sourceOpenTask?.cancel()
        sourceOpenTask = Task { [weak self] in
            await self?.openSource(source)
        }
    }

    // MARK: - Capture to Memory

    /// Sends the answer on screen to `recall remember`. Only ever run by the
    /// user from `⌘K` or `⌥⌘M`; the model has no way to call it. A thread
    /// answer gets a checkmark line under it that stays with the chat.
    func captureAnswerToMemory() async {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let memoryCapture else { return }
        // The answer is named before the wait, so a chat changed meanwhile
        // never gets the line.
        let answerID = answerMessageIndex.flatMap { currentConversation?.messages[$0].id }
        do {
            try await memoryCapture.remember(text)
        } catch {
            errorMessage = "Capture to Memory failed: \(error.localizedDescription)"
            requestInputFocus()
            return
        }
        errorMessage = nil
        if let answerID,
           let index = currentConversation?.messages.firstIndex(where: { $0.id == answerID }),
           currentConversation?.messages[index].tools.contains(where: { $0.kind == .capture }) == false {
            var records = currentConversation?.messages[index].tools ?? []
            records.append(ChatToolRecord(kind: .capture, summary: "Captured to memory"))
            currentConversation?.messages[index].toolRecords = records
            persistCurrentConversation()
        }
        confirmInComposer("Captured")
        requestInputFocus()
    }
}
