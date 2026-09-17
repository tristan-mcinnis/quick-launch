import Foundation

/// What Open in AI Chat (`⌘J`) carries from Quick AI to the AI Chat
/// window: the chat (its history, model, and tools ride on it), what is
/// typed, and the attachments. The launcher's view model makes it and the
/// window's view model adopts it; the launcher then lets the chat go, so one
/// chat is open in one window. Sent attachments need nothing: they are
/// references on the chat's messages, and both views read their text and
/// pictures from the one session store.
struct AIChatHandoff {
    var conversation: QuickConversation?
    var pendingChatTools: Set<ChatToolKind>?
    var input: String
    var pendingImages: [QuickImageAttachment]
    var pendingContext: CaptureContext?
    /// The chips not yet sent, each in its phase; a read still running moves
    /// over and goes on there, not started again.
    var pendingAttachments = AttachmentTray.Handoff()
    /// A Change Model on the empty surface, before a chat exists: the model
    /// the next chat starts on. A chat carries its own.
    var pendingModel: ChatModelChoice? = nil
    /// The selected-text chip captured before Quick AI took the keyboard.
    var launchSelection: QuickViewModel.LaunchSelection? = nil

    /// Whether the hand-off brings anything for the composer: text or an
    /// attachment. One that brings none leaves the window's own draft.
    var bringsDraft: Bool {
        !input.isEmpty || !pendingImages.isEmpty || pendingContext != nil || !pendingAttachments.isEmpty || launchSelection != nil
    }
}

/// A provider and a model, as a chat keeps them. The model is per chat: the
/// chooser writes the open chat's, and the next message uses it.
struct ChatModelChoice: Equatable, Sendable {
    let providerID: UUID
    let model: String
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
/// actions, and the chat list's rename. `AIChatWindowModel` conforms. The
/// window itself (its controller) is the view model's `overlayPresenter`.
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
            pendingContext: nil
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
            pendingContext: nil
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
            // The chips leave this tray now, reads and all.
            pendingAttachments: attachmentTray.handOff(),
            pendingModel: pendingModelChoice,
            launchSelection: launchSelection
        )
    }

    // MARK: - Window side

    /// The AI Chat window takes the chat Quick AI handed over, with its
    /// model (the chat's own, or a pick made before it began), tools, typed
    /// text, and attachments. A hand-off that brings nothing to type keeps
    /// the window's own draft. An answer still streaming in the window stops
    /// and keeps what arrived, saved with its chat, and the thread says so.
    func adoptAIChatHandoff(_ handoff: AIChatHandoff) {
        hasOpenedAIChatWindow = true
        if let id = handoff.conversation?.id, id == currentConversation?.id, !handoff.bringsDraft {
            // The window already has this chat: it stays as it is, a stream
            // and the draft included, brought up to the store.
            isQuickAIPresented = true
            refreshOpenChatFromStore()
            requestInputFocus()
            return
        }
        var stoppedChatTitle: String?
        if isStreaming {
            let streamingChat = currentConversation
            cancel()
            // The question too, when no text arrived to save it with.
            persistCurrentConversation()
            if let streamingChat, handoff.conversation?.id != streamingChat.id {
                stoppedChatTitle = title(of: streamingChat)
            }
        }
        let draft = (
            input: input,
            images: pendingImages,
            context: pendingContext,
            selection: launchSelection,
            chips: attachmentTray.handOff()
        )
        reset([.layers, .thread, .attachments, .input])
        isQuickAIPresented = true
        if let conversation = handoff.conversation {
            // The stored copy when history keeps one; the carried one when
            // history is off.
            let stored = history.first { $0.id == conversation.id }
            loadConversation(stored ?? conversation)
            lastQuestion = conversationMessages.last { $0.role == .user }?.content
        }
        pendingChatTools = handoff.pendingChatTools
        pendingModelChoice = handoff.pendingModel
        if handoff.bringsDraft {
            pendingImages = handoff.pendingImages
            pendingContext = handoff.pendingContext
            launchSelection = handoff.launchSelection
            attachmentTray.adopt(handoff.pendingAttachments)
            input = handoff.input
        } else {
            pendingImages = draft.images
            pendingContext = draft.context
            launchSelection = draft.selection
            attachmentTray.adopt(draft.chips)
            input = draft.input
        }
        if let stoppedChatTitle {
            setThreadNotice(Self.stoppedForHandoffNotice(chatTitle: stoppedChatTitle), symbol: Self.chatNoticeSymbol)
        }
        requestInputFocus()
    }

    /// The thread's line when a hand-off stopped the window's answer.
    static func stoppedForHandoffNotice(chatTitle: String) -> String {
        "Stopped the answer in “\(chatTitle)”. What arrived is saved."
    }

    /// The root "AI Chat" command and a reopened window. The first open
    /// lands on the most recently updated chat. After that the window keeps
    /// what it holds, as the store has it now: its chat, a new chat, and
    /// whatever is typed. The Start New Chat interval never applies here.
    func openLatestChat() {
        isQuickAIPresented = true
        refreshOpenChatFromStore()
        if !hasOpenedAIChatWindow, currentConversation == nil,
           let latest = history.max(by: { $0.updatedAt < $1.updatedAt }) {
            continueConversation(itemID: latest.id.uuidString)
        }
        hasOpenedAIChatWindow = true
        requestInputFocus()
    }

    /// The AI Chat window became key. What the user was in before is what
    /// Focused Window and Selected Text read, and the open chat is brought
    /// up to the store (a follow-up asked in the launcher, a rename, a pin,
    /// a delete).
    func aiChatWindowDidBecomeKey() {
        rememberSelectionTarget(selectedTextService?.currentExternalTarget())
        refreshOpenChatFromStore()
    }

    /// New Chat from the AI Chat header, which is live while an answer
    /// streams: the answer stops first and keeps what arrived, as Escape
    /// does, and the chat stays saved; then the thread starts over.
    func startNewChatKeepingAnswer() {
        if isStreaming {
            cancel()
            persistCurrentConversation()
        }
        startNewConversation()
    }
}

// MARK: - One store, two views

extension QuickViewModel {
    /// The other view wrote the history: this view's open chat follows now,
    /// not only when its window comes back.
    func storeHistoryDidChange() {
        refreshOpenChatFromStore()
    }

    /// What a view is called in the line the other view shows when a chat
    /// moves to it.
    var viewName: String { isAIChatWindow ? "AI Chat" : "Quick AI" }

    /// One chat, one view: this view is opening chat `id`, so a view that
    /// has it open lets it go (`letChatGo`), and the two never write it in
    /// turn.
    func takeChatFromOtherViews(_ id: UUID) {
        for view in store.views(besides: self) where view.currentConversation?.id == id {
            view.letChatGo(to: viewName)
        }
    }

    /// The other view opened the chat on this one's thread. A stream still
    /// running stops and keeps what arrived, and the chat is saved; the
    /// thread empties, what is typed stays, and the thread says where the
    /// chat went.
    func letChatGo(to destination: String) {
        if isStreaming { cancel() }
        persistCurrentConversation()
        expandedTranscriptMessageIDs.removeAll()
        reset([.thread])
        setThreadNotice(Self.movedChatNotice(to: destination), symbol: Self.chatNoticeSymbol)
    }

    static func movedChatNotice(to destination: String) -> String {
        "This chat is open in \(destination) now."
    }

    /// Sets the thread's closing line and its glyph.
    func setThreadNotice(_ notice: String, symbol: String) {
        threadNotice = notice
        threadNoticeSymbol = symbol
    }

    /// The line a chat deleted while it streamed leaves under its answer.
    static let deletedWhileAnsweringNotice = "This chat was deleted, so this answer is not saved."
    /// The line a chat deleted in the other view leaves on this one's thread.
    static let deletedChatNotice = "This chat was deleted."

    /// Saves the chat an answer just joined (a finished stream, or Stop). A
    /// chat deleted in the other view while it streamed is never brought
    /// back: the question and the answer stay on screen, not saved, as an
    /// answer with no chat behind it, and the thread says so. The next
    /// question starts a new chat.
    func persistAnsweredConversation() {
        guard canonicalHistoryActive,
              let local = currentConversation,
              !history.contains(where: { $0.id == local.id }),
              store.deletedChatIDs.contains(local.id)
        else {
            persistCurrentConversation()
            return
        }
        currentConversation = nil
        openChatBase = nil
        setThreadNotice(Self.deletedWhileAnsweringNotice, symbol: Self.chatNoticeSymbol)
    }

    /// Brings the open chat up to the store: the other view's turns since
    /// this view last read it, its rename and pin, or its delete (the chat
    /// leaves this thread with a line saying so; what is typed stays).
    /// Called whenever the other view writes the history, before a
    /// question, when the window or the launcher comes back, and on opening
    /// the window. A running stream is left alone; its save merges instead,
    /// and a chat deleted meanwhile keeps its answer on screen, unsaved
    /// (`persistAnsweredConversation`).
    func refreshOpenChatFromStore() {
        guard canonicalHistoryActive, !isStreaming, let local = currentConversation else { return }
        guard let stored = history.first(where: { $0.id == local.id }) else {
            if store.deletedChatIDs.contains(local.id) {
                expandedTranscriptMessageIDs.removeAll()
                reset([.thread])
                setThreadNotice(Self.deletedChatNotice, symbol: Self.chatNoticeSymbol)
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
