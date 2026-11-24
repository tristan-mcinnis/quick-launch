import Foundation

/// The second list a `⌘K` palette row can open.
enum ActionPaletteSubmenu: Equatable, Sendable {
    /// The chat's tools, each toggled with Return.
    case tools
    /// The saved web-search provider, shared by every chat surface.
    case searchProviders
    /// The answer's sources, each opened with Return.
    case sources
    /// Every question and answer of the chat, newest first; Return copies
    /// the row's message, or captures it to memory.
    case messages(MessagePaletteAction)
}

/// What Return does to a message in `⌘K` › Copy Message or Capture Message
/// to Memory.
enum MessagePaletteAction: String, Equatable, Sendable {
    case copy
    case capture
}

/// Tools inside the chat: which ones a chat lets the model call, the lines
/// their calls leave in the thread, the answer's sources, and Capture to
/// Memory.
extension QuickViewModel {

    // MARK: - The chat's tools

    /// The tools the next request offers: the open chat's own set, the set
    /// chosen on the empty surface, or the chat defaults (Settings ›
    /// General › Chat).
    var chatTools: Set<ChatToolKind> {
        currentConversation?.enabledTools
            ?? pendingChatTools
            ?? settings.newChatTools
    }

    /// Whether this Mac has the backend a tool needs. A tool that is on but
    /// unavailable is simply not offered to the model.
    func isChatToolAvailable(_ kind: ChatToolKind) -> Bool {
        switch kind {
        case .memory: memoryService != nil
        case .tasks: memoryService != nil || harnessScripts != nil
        case .skills: skillLibrary != nil
        case .web: webSearchService != nil || pageReader != nil
        case .files: workItemResolver != nil && fileOpener != nil
        case .calendar: harnessScripts != nil
        }
    }

    /// "Memory, Tasks, Skills on", for the Tools row's detail.
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

    var paletteSearchProviders: [WebSearchProvider] {
        Self.rankByQuery(WebSearchProvider.allCases, query: actionQuery, title: \.title)
    }

    func selectWebSearchProvider(_ provider: WebSearchProvider, defaults: UserDefaults = .standard) {
        settings.webSearchProvider = provider
        settings.save(to: defaults)
        closeActionPalette()
    }

    /// Opens the `⌘K` palette on one of its second lists.
    func openActionPaletteSubmenu(_ submenu: ActionPaletteSubmenu) {
        presentedLayer = .actionPalette
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
    /// (a local answer, a command's output).
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
    /// way a Quick Link does. Only a document file inside the memory repo,
    /// the skills repo or the Work folder is opened; anything else says why in the error
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

    // MARK: - Any message (⌘K › Copy Message, Capture Message to Memory)

    /// The messages those two lists offer: every question and answer of the
    /// open chat, newest first.
    var paletteMessages: [QuickMessage] {
        conversationMessages
            .filter { $0.role != .system }
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .reversed()
    }

    /// Message rows in the palette, narrowed by its search field: every
    /// word typed is in the message, case and accents ignored.
    var paletteMessageRows: [QuickMessage] {
        let words = FuzzyMatcher.fold(actionQuery).split(separator: " ")
        guard !words.isEmpty else { return paletteMessages }
        return paletteMessages.filter { message in
            let text = FuzzyMatcher.fold(message.content)
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// A message row's title: its first line of text, trimmed.
    static func messagePreview(_ message: QuickMessage) -> String {
        let line = message.content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// A message row's second line: whose it is.
    func messageDetail(_ message: QuickMessage) -> String {
        message.role == .user ? "Question" : "Answer"
    }

    /// Return on a message row.
    func performMessageAction(_ action: MessagePaletteAction, on message: QuickMessage) async {
        isActionPalettePresented = false
        actionPaletteSubmenu = nil
        actionQuery = ""
        switch action {
        case .copy:
            copyMessage(message)
        case .capture:
            await captureToMemory(message.content, answerID: message.role == .assistant ? message.id : nil)
        }
    }

    /// Copies one message of the chat. An answer is marked transient, as
    /// every copy of an AI answer is; a question is the user's own text.
    func copyMessage(_ message: QuickMessage) {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if message.role == .user {
            pasteboard.writeString(text)
        } else {
            pasteboard.writeTransientString(text)
        }
        markJustCopied()
        confirmInComposer("Copied")
        requestInputFocus()
    }

    // MARK: - Capture to Memory

    /// Sends the answer on screen to `recall capture`. Only ever run by the
    /// user from `⌘K` or `⌥⌘M`; the model has no way to call it. A thread
    /// answer gets a checkmark line under it that stays with the chat.
    func captureAnswerToMemory() async {
        // The answer is named before the wait, so a chat changed meanwhile
        // never gets the line.
        let answerID = answerMessageIndex.flatMap { currentConversation?.messages[$0].id }
        await captureToMemory(output, answerID: answerID)
    }

    /// Sends `content` to `recall capture`. An answer of the thread
    /// (`answerID`) gets the checkmark line; a question does not.
    func captureToMemory(_ content: String, answerID: UUID?) async {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let memoryCapture else { return }
        do {
            try await memoryCapture.capture(text)
        } catch {
            errorMessage = "Capture to Memory failed: \(error.localizedDescription)"
            requestInputFocus()
            return
        }
        errorMessage = nil
        noteFeatureUse(.memoryCaptureRun, itemID: "feature:memory-capture")
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

    // MARK: - Add to Todoist

    /// Whether this answer already holds the Added line for `proposal`.
    func isTodoistProposalAdded(_ proposal: TodoistProposal, in message: QuickMessage) -> Bool {
        message.tools.contains { $0.kind == .todoistAdded && $0.proposal?.id == proposal.id }
    }

    /// The newest answer's first proposed task not yet added. While there is
    /// one, Return on an empty composer adds it (the footer says "Add to
    /// Todoist ↩"), so the launcher stays keyboard-only; ⌘↩ still pastes.
    var pendingTodoistProposal: (proposal: TodoistProposal, answerID: UUID)? {
        guard harnessScripts != nil,
              let answer = currentConversation?.messages.last, answer.role == .assistant
        else { return nil }
        for record in answer.tools where record.kind == .todoistProposal {
            if let proposal = record.proposal, !isTodoistProposalAdded(proposal, in: answer) {
                return (proposal, answer.id)
            }
        }
        return nil
    }

    /// The user's press on Add to Todoist under an answer, or Return while
    /// the task is pending: the only paths that write a task. The model can
    /// only propose one.
    func addProposedTodoist(_ proposal: TodoistProposal, answerID: UUID) async {
        guard let harnessScripts, !todoistAddsInFlight.contains(proposal.id),
              let message = currentConversation?.messages.first(where: { $0.id == answerID }),
              !isTodoistProposalAdded(proposal, in: message)
        else { return }
        todoistAddsInFlight.insert(proposal.id)
        defer { todoistAddsInFlight.remove(proposal.id) }
        do {
            _ = try await harnessScripts.addTodoist(proposal)
        } catch {
            errorMessage = "Add to Todoist failed: \(error.localizedDescription)"
            requestInputFocus()
            return
        }
        errorMessage = nil
        // The chat may have changed during the wait; find the answer again.
        if let index = currentConversation?.messages.firstIndex(where: { $0.id == answerID }) {
            var records = currentConversation?.messages[index].tools ?? []
            records.append(ChatToolRecord(kind: .todoistAdded, summary: "Added to Todoist: \(proposal.line)", proposal: proposal))
            currentConversation?.messages[index].toolRecords = records
            persistCurrentConversation()
        }
        confirmInComposer("Added to Todoist")
        requestInputFocus()
    }

    // MARK: - Changes: reschedule, done, move, undo

    /// What Return confirms on the newest answer, if anything waits.
    enum PendingAction {
        case add(TodoistProposal, answerID: UUID)
        case change(ChangeProposal, answerID: UUID)
    }

    /// The newest answer's first proposal still waiting: a task to add or
    /// a change to make. Return confirms it; the footer names it.
    var pendingAction: PendingAction? {
        guard harnessScripts != nil,
              let answer = currentConversation?.messages.last, answer.role == .assistant
        else { return nil }
        for record in answer.tools {
            if record.kind == .todoistProposal, let proposal = record.proposal,
               !isTodoistProposalAdded(proposal, in: answer) {
                return .add(proposal, answerID: answer.id)
            }
            if record.kind == .changeProposal, let change = record.change, !isChangeDone(change, in: answer) {
                return .change(change, answerID: answer.id)
            }
        }
        return nil
    }

    /// The footer's words for the pending action.
    var pendingActionLabel: String? {
        switch pendingAction {
        case .add(let proposal, _):
            todoistAddsInFlight.contains(proposal.id) ? "Adding…" : "Add to Todoist"
        case .change(let change, _):
            changesInFlight.contains(change.id) ? "Working…" : change.actionLabel
        case nil: nil
        }
    }

    /// Return on the pending action.
    func confirmPendingAction() async {
        switch pendingAction {
        case .add(let proposal, let answerID): await addProposedTodoist(proposal, answerID: answerID)
        case .change(let change, let answerID): await applyProposedChange(change, answerID: answerID)
        case nil: break
        }
    }

    func isChangeDone(_ change: ChangeProposal, in message: QuickMessage) -> Bool {
        message.tools.contains { $0.kind == .changeDone && $0.change?.id == change.id }
    }

    /// The user's Return on a proposed change: the only path that makes one.
    func applyProposedChange(_ change: ChangeProposal, answerID: UUID) async {
        guard let harnessScripts, !changesInFlight.contains(change.id),
              let message = currentConversation?.messages.first(where: { $0.id == answerID }),
              !isChangeDone(change, in: message)
        else { return }
        changesInFlight.insert(change.id)
        defer { changesInFlight.remove(change.id) }
        do {
            try await harnessScripts.apply(change)
        } catch {
            errorMessage = "\(change.actionLabel) failed: \(error.localizedDescription)"
            requestInputFocus()
            return
        }
        errorMessage = nil
        appendRecord(ChatToolRecord(kind: .changeDone, summary: change.doneLine, change: change), to: answerID)
        confirmInComposer("\(change.doneLine) · ⌘Z undoes")
        requestInputFocus()
    }

    /// The newest change on the newest answer that is not undone yet.
    var undoableChange: (change: ChangeProposal, answerID: UUID)? {
        guard harnessScripts != nil,
              let answer = currentConversation?.messages.last, answer.role == .assistant
        else { return nil }
        let undone = Set(answer.tools.filter { $0.kind == .changeUndone }.compactMap { $0.change?.id })
        guard let done = answer.tools.last(where: { $0.kind == .changeDone && !undone.contains($0.change?.id ?? UUID()) }),
              let change = done.change
        else { return nil }
        return (change, answer.id)
    }

    /// ⌘Z on an empty field: puts the newest change back.
    func undoLastChange() async {
        guard let harnessScripts, let (change, answerID) = undoableChange,
              !changesInFlight.contains(change.id)
        else { return }
        changesInFlight.insert(change.id)
        defer { changesInFlight.remove(change.id) }
        do {
            try await harnessScripts.apply(change.inverse)
        } catch {
            errorMessage = "Undo failed: \(error.localizedDescription)"
            requestInputFocus()
            return
        }
        errorMessage = nil
        appendRecord(ChatToolRecord(kind: .changeUndone, summary: "Undone: \(change.doneLine)", change: change), to: answerID)
        confirmInComposer("Undone")
        requestInputFocus()
    }

    private func appendRecord(_ record: ChatToolRecord, to answerID: UUID) {
        // The chat may have changed during the wait; find the answer again.
        guard let index = currentConversation?.messages.firstIndex(where: { $0.id == answerID }) else { return }
        var records = currentConversation?.messages[index].tools ?? []
        records.append(record)
        currentConversation?.messages[index].toolRecords = records
        persistCurrentConversation()
    }
}
