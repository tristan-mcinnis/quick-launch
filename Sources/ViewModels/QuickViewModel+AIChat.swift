import Foundation

/// What Open in AI Chat (`⌘J`) carries from Quick AI to the AI Chat
/// window: the chat (its history, model, and tools ride on it), what is
/// typed, and the attachments. The launcher's view model makes it and the
/// window's view model adopts it; the launcher then lets the chat go, so one
/// chat is open in one window.
struct AIChatHandoff {
    var conversation: QuickConversation?
    var pendingChatTools: Set<ChatToolKind>?
    var input: String
    var pendingImages: [QuickImageAttachment]
    var pendingContext: CaptureContext?
    var conversationImages: [QuickImageAttachment]
}

/// The store's copy of a chat at one moment: when it was last written and
/// which messages it held. A view model keeps one for its open chat
/// (`openChatBase`), so a save can tell the other view's changes from its own.
struct StoredChatStamp: Equatable {
    let id: UUID
    let updatedAt: Date
    let messageIDs: Set<UUID>

    init(_ conversation: QuickConversation) {
        id = conversation.id
        updatedAt = conversation.updatedAt
        messageIDs = Set(conversation.messages.map(\.id))
    }
}

/// The AI Chat window as its view model sees it: the window's own `⌘K`
/// actions, and the chat list's rename. `AIChatWindowModel` conforms.
@MainActor
protocol AIChatWindowHosting: AnyObject {
    var windowSurfaceActions: [QuickAISurfaceAction] { get }
    func performWindowSurfaceAction(_ action: QuickAISurfaceAction)
    func beginRenamingChat(id: UUID)
}

extension QuickViewModel {
    /// The root-search command that opens the AI Chat window.
    static let aiChatCommandID = "aichat.open"

    var aiChatCommand: LauncherCatalogItem {
        LauncherCatalogItem(
            kind: .command,
            itemID: Self.aiChatCommandID,
            title: "AI Chat",
            detail: "Open the chat window on a new or the last chat",
            value: Self.aiChatCommandID,
            keywords: "chat window conversation ai ask"
        )
    }

    // MARK: - Launcher side

    /// `⌘J`, `⌘K` › Open in AI Chat, or the header's Open in AI Chat
    /// button: the chat moves to the AI Chat window and the launcher closes.
    /// In Recent Chats it is the highlighted chat, as `⌘K` and the row keys
    /// act on it; with no row highlighted (a search that matches nothing)
    /// nothing moves.
    func continueInAIChat() {
        guard aiChatOpener != nil, !isAIChatWindow else { return }
        if isRecentChatsPresented {
            if case .item(let item)? = focusedLauncherResult, item.kind == .conversation {
                openChatInAIChat(itemID: item.itemID)
            }
            return
        }
        handOffOpenChat()
    }

    /// Open in AI Chat on a chat row (the Chats catalog, Recent Chats): that
    /// chat moves to the window. The chat open here moves as `⌘J` moves it,
    /// with its attachments; another chat leaves this thread as it is. The
    /// list's search text is not a draft, so it goes nowhere.
    func openChatInAIChat(itemID: String) {
        guard let aiChatOpener, !isAIChatWindow,
              let id = UUID(uuidString: itemID),
              let conversation = history.first(where: { $0.id == id })
        else { return }
        closeItemActionPane()
        isRecentChatsPresented = false
        input = ""
        if currentConversation?.id == id {
            handOffOpenChat()
            return
        }
        // A stream still running stops and keeps what arrived, as Escape
        // does, and the chat it belongs to stays saved.
        if isStreaming { cancel() }
        persistCurrentConversation()
        overlayPresenter.dismissOverlay()
        aiChatOpener(AIChatHandoff(
            conversation: conversation,
            pendingChatTools: nil,
            input: "",
            pendingImages: [],
            pendingContext: nil,
            conversationImages: []
        ))
    }

    /// The open chat to the window. A stream still running stops first and
    /// keeps what arrived, as Escape does.
    private func handOffOpenChat() {
        guard let aiChatOpener else { return }
        if isStreaming { cancel() }
        let handoff = makeAIChatHandoff()
        // One chat, one window: the launcher lets it go (it stays in
        // Recent Chats), so the two view models never write it in turn.
        reset([.layers, .thread, .attachments, .input])
        // The panel goes first, so hiding it cannot take the keyboard back
        // from the window that opens next.
        overlayPresenter.dismissOverlay()
        aiChatOpener(handoff)
    }

    /// The root "AI Chat" command and ⋯ › Open AI Chat: the window on a new
    /// or the last chat. As a fallback command it gets what was typed: the
    /// window opens a new chat with the text in its composer, unsent.
    func openAIChatWindow(draft: String = "") {
        guard let aiChatOpener else { return }
        input = ""
        overlayPresenter.dismissOverlay()
        guard !draft.isEmpty else {
            aiChatOpener(nil)
            return
        }
        aiChatOpener(AIChatHandoff(
            conversation: nil,
            pendingChatTools: nil,
            input: draft,
            pendingImages: [],
            pendingContext: nil,
            conversationImages: []
        ))
    }

    /// ⋯ › New Chat: Quick AI on an empty chat. The chat on the surface is
    /// saved first (a stream still running stops and keeps what arrived),
    /// so it stays in Recent Chats; only the surface starts over.
    func openNewChat() {
        if isStreaming { cancel() }
        persistCurrentConversation()
        startNewConversation()
        openQuickAI()
    }

    /// The ⋯ menu's chat entries: Open AI Chat only when there is a window
    /// to open.
    var chatMenuEntries: [ChatMenuEntry] {
        ChatMenuEntry.allCases.filter { $0 != .openAIChat || aiChatOpener != nil }
    }

    /// Recent Chats is greyed out with nothing to list.
    func isChatMenuEntryEnabled(_ entry: ChatMenuEntry) -> Bool {
        entry == .recentChats ? canOpenRecentChats : true
    }

    /// One ⋯ chat entry, by the same path its key or command takes.
    func performChatMenuEntry(_ entry: ChatMenuEntry) {
        switch entry {
        case .newChat: openNewChat()
        case .recentChats: openRecentChats()
        case .openAIChat: openAIChatWindow()
        }
    }

    /// The chat on the surface, saved first so the stored copy is current.
    func makeAIChatHandoff() -> AIChatHandoff {
        persistCurrentConversation()
        return AIChatHandoff(
            conversation: currentConversation,
            pendingChatTools: pendingChatTools,
            input: input,
            pendingImages: pendingImages,
            pendingContext: pendingContext,
            conversationImages: conversationImages
        )
    }

    // MARK: - Window side

    /// The AI Chat window takes the chat Quick AI handed over, with its
    /// model, tools, typed text, and attachments.
    func adoptAIChatHandoff(_ handoff: AIChatHandoff) {
        if isStreaming { cancel() }
        reset([.layers, .thread, .attachments, .input])
        isQuickAIPresented = true
        // The model rides in the shared settings. Loading a chat selects the
        // model it last answered with; the hand-off keeps the one Quick AI
        // would have used next (a Change Model after the last answer).
        let modelChoice = settings
        if let conversation = handoff.conversation {
            // The stored copy when history keeps one; the carried one when
            // history is off.
            let stored = history.first { $0.id == conversation.id }
            loadConversation(stored ?? conversation)
            lastQuestion = conversationMessages.last { $0.role == .user }?.content
            settings = modelChoice
            settings.save()
        }
        pendingChatTools = handoff.pendingChatTools
        conversationImages = handoff.conversationImages
        pendingImages = handoff.pendingImages
        pendingContext = handoff.pendingContext
        input = handoff.input
        requestInputFocus()
    }

    /// The root "AI Chat" command and a reopened window: the chat the
    /// window already holds (as the store has it now), or the most recently
    /// updated chat, unless the Start New Chat interval says the next
    /// question starts a fresh one.
    func openLatestChat() {
        isQuickAIPresented = true
        refreshOpenChatFromStore()
        if currentConversation == nil,
           let latest = history.max(by: { $0.updatedAt < $1.updatedAt }) {
            continueConversation(itemID: latest.id.uuidString)
        }
        if shouldStartNewConversation {
            if isStreaming { return }
            startNewConversation()
        }
        requestInputFocus()
    }
}

// MARK: - One store, two views

extension QuickViewModel {
    /// Brings the open chat up to the store: the other view's turns since
    /// this view last read it, its rename and pin, or its delete (the chat
    /// leaves this thread; what is typed stays). Called before a question,
    /// when the window or the launcher comes back, and on opening the
    /// window. A running stream is left alone; its save merges instead.
    func refreshOpenChatFromStore() {
        guard settings.historyEnabled, !isStreaming, let local = currentConversation else { return }
        guard let stored = history.first(where: { $0.id == local.id }) else {
            if store.deletedChatIDs.contains(local.id) {
                expandedTranscriptMessageIDs.removeAll()
                reset([.thread])
            }
            return
        }
        guard let merged = conversationToStore(local), merged != local else {
            openChatBase = StoredChatStamp(stored)
            return
        }
        currentConversation = merged
        // The store's copy is the base; turns only this view has (a question
        // that got no answer) are still this view's to save.
        openChatBase = StoredChatStamp(stored)
        guard merged.messages != local.messages else { return }
        output = merged.messages.last(where: { $0.role == .assistant })?.content ?? ""
        lastQuestion = merged.messages.last(where: { $0.role == .user })?.content
    }

    /// The copy of `local` to write: the store's name and pin (the other
    /// view may have changed them), and, when the other view wrote this
    /// chat since this view read it, its turns merged with this view's.
    /// Nil when the chat was deleted: a save never brings it back.
    func conversationToStore(_ local: QuickConversation) -> QuickConversation? {
        guard let stored = history.first(where: { $0.id == local.id }) else {
            return store.deletedChatIDs.contains(local.id) ? nil : local
        }
        var merged = local
        merged.customTitle = stored.customTitle
        merged.isPinned = stored.isPinned
        guard let base = openChatBase, base.id == local.id, base != StoredChatStamp(stored) else {
            return merged
        }
        // A three-way merge of an append-mostly list: the store's turns,
        // less the ones this view removed since its base (a regenerated
        // answer), then the turns this view added since.
        let localIDs = Set(local.messages.map(\.id))
        let storedIDs = Set(stored.messages.map(\.id))
        let kept = stored.messages.filter { !base.messageIDs.contains($0.id) || localIDs.contains($0.id) }
        let added = local.messages.filter { !base.messageIDs.contains($0.id) && !storedIDs.contains($0.id) }
        merged.messages = kept + added
        merged.updatedAt = max(local.updatedAt, stored.updatedAt)
        if merged.titleSource == nil { merged.titleSource = stored.titleSource }
        return merged
    }
}
