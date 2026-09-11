import AppKit
import Foundation
import Observation

/// What the AI Chat window model asks of its window. `AIChatWindowController`
/// is the real one; tests pass a fake and count the calls.
@MainActor
protocol AIChatWindowPresenting: AnyObject {
    /// Order the window front and make it key, joining ⌘Tab.
    func showWindow()
    /// Order the window out for a moment (an area capture), not closing it.
    func hideWindowForCapture()
    func setAlwaysOnTop(_ onTop: Bool)
}

/// The AI Chat window: one conversation window over the same providers and
/// tools as Quick AI. No autonomy, no projects, no automations, no file
/// changes; those belong to pi.
///
/// The window has its own `QuickViewModel` (`chat`), so its composer,
/// thread, stream, and layers never touch the launcher's. The two share the
/// `QuickStore` (settings and chat history): one store, two views. This
/// class holds only what the window adds over the Quick AI surface: the chat
/// list rail, find in chat, Keep on Top, and the keys that drive them. The
/// thread and composer are Quick AI's own views.
@Observable @MainActor final class AIChatWindowModel: AIChatWindowHosting {

    // MARK: - Keys

    /// `⌘\`: slide the chat list in or out. Free in every key table.
    nonisolated static let chatListShortcut: KeyShortcut = .command("\\")
    /// `⌘F`: find in chat.
    nonisolated static let findShortcut: KeyShortcut = .command("f")
    /// `⌘G` and `⇧⌘G`: the next and the previous match, as in every Mac app.
    nonisolated static let findNextShortcut: KeyShortcut = .command("g")
    nonisolated static let findPreviousShortcut: KeyShortcut = .commandShift("g")
    /// Keep on Top, remembered across launches. The one place it is kept:
    /// the window's `⌘K` and menu, and Settings › General › Chat › "Keep AI
    /// Chat on top", all read and write this key.
    nonisolated static let alwaysOnTopDefaultsKey = "AIChatAlwaysOnTop"
    /// `⌘1`…`⌘9` open the chat list's first nine rows.
    nonisolated static let jumpRowCount = 9
    /// The composer grows to this many lines, then scrolls.
    nonisolated static let composerLineLimit = 8

    // MARK: - State

    /// The window's own view model. Shares `store` with the launcher's.
    let chat: QuickViewModel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored weak var window: (any AIChatWindowPresenting)?
    /// Watches `defaults`, so a Keep on Top switched in Settings reaches
    /// the open window.
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?

    /// Where the keyboard is, so Return, Escape, and the arrows go to the
    /// right field. The views report it as focus moves.
    enum Focus: Equatable, Sendable {
        case composer
        case find
        case rail
        case rename
        /// A field the window does not route: the `⌘K` palette's search.
        /// Return and ⇧↩ are that field's own.
        case other
    }
    var focus: Focus = .composer

    /// A field gained or lost the keyboard. Losing it moves the window's
    /// idea of focus only when no other field has claimed it since.
    func noteFocus(_ field: Focus, _ focused: Bool) {
        if focused {
            focus = field
        } else if focus == field {
            focus = .other
        }
    }

    /// Keep on Top: the window floats above other apps' windows (still
    /// under the launcher panel).
    var isAlwaysOnTop: Bool {
        didSet {
            guard isAlwaysOnTop != oldValue else { return }
            defaults.set(isAlwaysOnTop, forKey: Self.alwaysOnTopDefaultsKey)
            window?.setAlwaysOnTop(isAlwaysOnTop)
        }
    }

    /// The chat list: hidden by default, slides in on `⌘\` or the header
    /// button, and slides out the same way or with Escape.
    var isRailVisible = false
    /// The rail's search: title and message text.
    var railQuery = "" {
        didSet { if railQuery != oldValue { railIndex = 0; railActionsPresented = false } }
    }
    /// The highlighted rail row, over `railItems`.
    var railIndex = 0
    /// `⌘K` on the rail: the highlighted row's actions.
    var railActionsPresented = false
    var railActionIndex = 0
    /// Delete is pressed twice: the first press arms it on that chat.
    var deleteArmedChatID: UUID?
    /// The chat being renamed in its row, and the name typed so far.
    var renamingChatID: UUID?
    var renameText = ""
    /// Bumped to move the keyboard into the rail's search or the rename field.
    var railFocusRequest = 0
    var renameFocusRequest = 0

    /// Find in chat (`⌘F`): the bar above the thread, its text, and which
    /// match is current. A match is a message that holds the text.
    var isFindPresented = false
    var findQuery = "" {
        didSet { if findQuery != oldValue { moveToFirstMatch() } }
    }
    var currentMatchIndex: Int?
    var findFocusRequest = 0

    init(chat: QuickViewModel, defaults: UserDefaults = .standard) {
        self.chat = chat
        self.defaults = defaults
        self.isAlwaysOnTop = defaults.bool(forKey: Self.alwaysOnTopDefaultsKey)
        chat.chatWindowHost = self
        chat.isQuickAIPresented = true
        // Any defaults change re-reads the one key; a write from this model
        // reads back the value it already holds, so nothing loops.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAlwaysOnTopFromDefaults() }
        }
    }

    isolated deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    /// Takes Keep on Top from `defaults`, where Settings writes it.
    func syncAlwaysOnTopFromDefaults() {
        let stored = defaults.bool(forKey: Self.alwaysOnTopDefaultsKey)
        if stored != isAlwaysOnTop { isAlwaysOnTop = stored }
    }

    // MARK: - Opening

    /// Opens the window. A hand-off (`⌘J` in Quick AI) brings its chat,
    /// model, tools, typed text, and attachments; nil (the "AI Chat"
    /// command, the menu) shows the chat the window holds, or the last one,
    /// or a new one when the Start New Chat interval has passed.
    func open(handoff: AIChatHandoff?) {
        if let handoff {
            closeFind()
            chat.adoptAIChatHandoff(handoff)
            railIndex = currentRailIndex ?? 0
        } else {
            chat.openLatestChat()
        }
        chat.isQuickAIPresented = true
        focus = .composer
        window?.showWindow()
        chat.requestInputFocus()
    }

    // MARK: - Rail

    /// The rail's rows: pinned first, then recent, narrowed by the search.
    var railItems: [LauncherCatalogItem] {
        let terms = FuzzyMatcher.fold(railQuery)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let ordered = QuickHistoryStore.ordered(chat.history)
        let kept = terms.isEmpty ? ordered : ordered.filter { conversation in
            let haystack = FuzzyMatcher.fold(
                ([chat.title(of: conversation)] + conversation.messages.map(\.content))
                    .joined(separator: "\n")
            )
            return terms.allSatisfy { haystack.contains($0) }
        }
        let ids = Set(kept.map(\.id.uuidString))
        return chat.conversationItems.filter { ids.contains($0.itemID) }
    }

    var pinnedRailItems: [LauncherCatalogItem] { railItems.filter(\.isPinned) }

    /// A rail row's second line, short enough for the rail: the question
    /// count and the time today, the day before that.
    func railDetail(for item: LauncherCatalogItem, now: Date = Date()) -> String {
        guard let conversation = chat.history.first(where: { $0.id.uuidString == item.itemID }) else {
            return item.detail
        }
        let turns = conversation.messages.filter { $0.role == .user }.count
        let count = turns == 1 ? "1 question" : "\(turns) questions"
        let stamp = Calendar.current.isDate(conversation.updatedAt, inSameDayAs: now)
            ? conversation.updatedAt.formatted(date: .omitted, time: .shortened)
            : conversation.updatedAt.formatted(.dateTime.month(.abbreviated).day())
        return "\(count) · \(stamp)"
    }
    var recentRailItems: [LauncherCatalogItem] { railItems.filter { !$0.isPinned } }

    /// The open chat's row, when the rail shows it.
    var currentRailIndex: Int? {
        guard let id = chat.currentConversation?.id.uuidString else { return nil }
        return railItems.firstIndex { $0.itemID == id }
    }

    var highlightedRailItem: LauncherCatalogItem? {
        let items = railItems
        return items.indices.contains(railIndex) ? items[railIndex] : nil
    }

    func toggleRail() {
        if isRailVisible { hideRail() } else { showRail() }
    }

    /// Slides the list in with the keyboard in its search, the open chat
    /// highlighted.
    func showRail() {
        isRailVisible = true
        railQuery = ""
        railIndex = currentRailIndex ?? 0
        railActionsPresented = false
        focusRail()
    }

    func hideRail() {
        isRailVisible = false
        railQuery = ""
        railActionsPresented = false
        cancelRename()
        deleteArmedChatID = nil
        focusComposer()
    }

    func focusRail() {
        focus = .rail
        railFocusRequest &+= 1
    }

    func moveRailSelection(_ delta: Int) {
        if railActionsPresented {
            let count = railActions.count
            guard count > 0 else { return }
            railActionIndex = ListSelection.wrappedIndex(railActionIndex, by: delta, count: count)
            return
        }
        let count = railItems.count
        guard count > 0 else { return }
        deleteArmedChatID = nil
        railIndex = ListSelection.wrappedIndex(railIndex, by: delta, count: count)
    }

    /// Return in the rail: open the highlighted chat, or run the highlighted
    /// row action while `⌘K` is open.
    func activateRailSelection() {
        if railActionsPresented {
            guard railActions.indices.contains(railActionIndex) else { return }
            performRailAction(railActions[railActionIndex])
            return
        }
        guard let item = highlightedRailItem else { return }
        openChat(itemID: item.itemID)
    }

    /// Opens a chat from the rail (a click, Return, or `⌘1`…`⌘9`). The rail
    /// stays; the keyboard goes back to the composer.
    func openChat(itemID: String) {
        if chat.isStreaming { chat.cancel() }
        closeFind()
        chat.continueConversation(itemID: itemID)
        chat.isQuickAIPresented = true
        railIndex = railItems.firstIndex { $0.itemID == itemID } ?? railIndex
        railActionsPresented = false
        deleteArmedChatID = nil
        focusComposer()
    }

    /// `⌘1`…`⌘9`: the rail's rows in the order they are drawn, whether or
    /// not the rail is showing.
    @discardableResult
    func jumpToRailRow(_ number: Int) -> Bool {
        let items = railItems
        guard number >= 1, number <= Self.jumpRowCount, items.indices.contains(number - 1) else { return false }
        openChat(itemID: items[number - 1].itemID)
        return true
    }

    // MARK: - Rail row actions (⌘K on a row)

    enum RailAction: String, Identifiable, Sendable, CaseIterable {
        case pin
        case rename
        case delete

        var id: String { rawValue }

        var shortcut: KeyShortcut {
            switch self {
            case .pin: ResultAction.pinChat.shortcut
            case .rename: ResultAction.renameChat.shortcut
            case .delete: ResultAction.deleteChat.shortcut
            }
        }

        var systemImage: String {
            switch self {
            case .pin: "pin"
            case .rename: "pencil"
            case .delete: "trash"
            }
        }
    }

    var railActions: [RailAction] { highlightedRailItem == nil ? [] : RailAction.allCases }

    /// A row action's title for the highlighted chat.
    func title(of action: RailAction) -> String {
        switch action {
        case .pin: highlightedRailItem?.isPinned == true ? "Unpin Chat" : "Pin Chat"
        case .rename: "Rename Chat"
        case .delete:
            highlightedRailItem.flatMap { UUID(uuidString: $0.itemID) } == deleteArmedChatID
                && deleteArmedChatID != nil
                ? "Press Again to Delete"
                : "Delete Chat"
        }
    }

    func toggleRailActions() {
        guard !railActions.isEmpty else { return }
        railActionsPresented.toggle()
        railActionIndex = 0
    }

    func performRailAction(_ action: RailAction) {
        guard let item = highlightedRailItem, let id = UUID(uuidString: item.itemID) else { return }
        switch action {
        case .pin:
            deleteArmedChatID = nil
            chat.togglePinConversation(id: id)
            // The row moves between Pinned and Recent; the highlight follows it.
            railIndex = railItems.firstIndex { $0.itemID == item.itemID } ?? railIndex
            railActionsPresented = false
        case .rename:
            deleteArmedChatID = nil
            railActionsPresented = false
            beginRenamingChat(id: id)
        case .delete:
            // Twice, as everywhere in the app: the first press arms it.
            guard deleteArmedChatID == id else {
                deleteArmedChatID = id
                return
            }
            deleteArmedChatID = nil
            railActionsPresented = false
            chat.deleteConversation(id: id)
            chat.isQuickAIPresented = true
            railIndex = min(railIndex, max(0, railItems.count - 1))
        }
    }

    /// The row keys (`⇧⌘P`, `⌘E`, `⌃X`) on the highlighted rail row, while
    /// the keyboard is in the rail.
    private func performRailRowShortcut(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard focus == .rail, highlightedRailItem != nil,
              let action = RailAction.allCases.first(where: {
                  $0.shortcut.matches(characters: characters, keyCode: keyCode, modifiers: modifiers)
              })
        else { return false }
        performRailAction(action)
        return true
    }

    // MARK: - Rename

    func beginRenamingChat(id: UUID) {
        guard let conversation = chat.history.first(where: { $0.id == id }) else { return }
        if !isRailVisible {
            isRailVisible = true
            railQuery = ""
        }
        railIndex = railItems.firstIndex { $0.itemID == id.uuidString } ?? railIndex
        renamingChatID = id
        renameText = chat.title(of: conversation)
        focus = .rename
        renameFocusRequest &+= 1
    }

    func commitRename() {
        guard let id = renamingChatID else { return }
        chat.renameConversation(id: id, title: renameText)
        renamingChatID = nil
        renameText = ""
        focusRail()
    }

    func cancelRename() {
        guard renamingChatID != nil else { return }
        renamingChatID = nil
        renameText = ""
        if isRailVisible { focusRail() }
    }

    // MARK: - Find in chat

    /// The messages of the open chat that hold the find text, in thread
    /// order. Case and accents are ignored, as in the launcher's search.
    var findMatches: [UUID] {
        let needle = FuzzyMatcher.fold(findQuery).trimmingCharacters(in: .whitespaces)
        guard isFindPresented, !needle.isEmpty else { return [] }
        return chat.conversationMessages
            .filter { $0.role != .system && FuzzyMatcher.fold($0.content).contains(needle) }
            .map(\.id)
    }

    /// The message the find bar is on, drawn with the selection fill.
    var currentMatchID: UUID? {
        let matches = findMatches
        guard let index = currentMatchIndex, matches.indices.contains(index) else { return nil }
        return matches[index]
    }

    /// "2 of 5", "No matches", or nothing before anything is typed.
    var findStatus: String {
        guard !findQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        let count = findMatches.count
        guard count > 0, let index = currentMatchIndex else { return "No matches" }
        return "\(index + 1) of \(count)"
    }

    func openFind() {
        isFindPresented = true
        focus = .find
        findFocusRequest &+= 1
        moveToFirstMatch()
    }

    func closeFind() {
        guard isFindPresented else { return }
        isFindPresented = false
        findQuery = ""
        currentMatchIndex = nil
        focusComposer()
    }

    /// Return and `⌘G`: the next match, wrapping. `⇧↩` and `⇧⌘G`: the
    /// previous one.
    func findNext() { stepMatch(1) }
    func findPrevious() { stepMatch(-1) }

    private func stepMatch(_ delta: Int) {
        let count = findMatches.count
        guard count > 0 else {
            currentMatchIndex = nil
            return
        }
        let next = currentMatchIndex.map { ListSelection.wrappedIndex($0, by: delta, count: count) }
            ?? (delta > 0 ? 0 : count - 1)
        reveal(next)
    }

    private func moveToFirstMatch() {
        guard !findMatches.isEmpty else {
            currentMatchIndex = nil
            return
        }
        reveal(0)
    }

    /// Makes a match current: a folded question opens so the text shows,
    /// and the message's head scrolls to the top of the thread.
    private func reveal(_ index: Int) {
        currentMatchIndex = index
        let id = findMatches[index]
        if let message = chat.conversationMessages.first(where: { $0.id == id }),
           chat.collapseState(for: message).isCollapsible,
           !chat.expandedTranscriptMessageIDs.contains(id) {
            chat.expandedTranscriptMessageIDs.insert(id)
        }
        chat.scrollThread(.messageTop(id))
    }

    // MARK: - Focus

    func focusComposer() {
        focus = .composer
        chat.requestInputFocus()
    }

    // MARK: - Window actions (⌘K)

    var windowSurfaceActions: [QuickAISurfaceAction] {
        [
            isRailVisible ? .hideChatList : .showChatList,
            .findInChat,
            isAlwaysOnTop ? .stopKeepingOnTop : .keepOnTop,
        ]
    }

    func performWindowSurfaceAction(_ action: QuickAISurfaceAction) {
        switch action {
        case .showChatList: showRail()
        case .hideChatList: hideRail()
        case .findInChat: openFind()
        case .keepOnTop: isAlwaysOnTop = true; focusComposer()
        case .stopKeepingOnTop: isAlwaysOnTop = false; focusComposer()
        case .resetSize: focusComposer()
        }
    }

    // MARK: - Keys

    /// Escape, walked from the outermost layer in: the chat's own layers
    /// (the `⌘K` palette, a chooser, a stream), the rename field, the rail's
    /// actions, its search, the rail, the find bar. Typed text, the thread,
    /// and the window stay: `⌘W` closes the window.
    @discardableResult
    func handleEscape() -> Bool {
        switch chat.topLayer {
        case .itemActionForm, .itemActionPane, .actionPalette, .transformChooser,
             .modelChooser, .assistantChooser, .addContextMenu, .streaming:
            chat.popTopLayer()
            return true
        default:
            break
        }
        if renamingChatID != nil {
            cancelRename()
        } else if railActionsPresented {
            railActionsPresented = false
            deleteArmedChatID = nil
        } else if focus == .rail, !railQuery.isEmpty {
            railQuery = ""
        } else if focus == .rail, isRailVisible {
            hideRail()
        } else if isFindPresented {
            closeFind()
        } else if isRailVisible {
            hideRail()
        }
        return true
    }

    /// Return with no modifier. In the composer it asks (the composer is
    /// multi-line, so the window takes Return before the text view does);
    /// in the find bar it moves to the next match.
    func handleReturn() -> Bool {
        switch focus {
        case .composer:
            // The palette's search keeps its own Return.
            guard !chat.isActionPalettePresented, !chat.isItemActionPanePresented else { return false }
            chat.submitFromComposer()
            return true
        case .find:
            findNext()
            return true
        case .rail:
            activateRailSelection()
            return true
        case .rename:
            commitRename()
            return true
        case .other:
            return false
        }
    }

    /// `⇧↩`: a new line in the composer (the caller inserts it), the
    /// previous match in the find bar. Returns what the caller should do.
    enum ShiftReturn: Equatable, Sendable {
        case insertNewline
        case handled
        case ignored
    }

    func handleShiftReturn() -> ShiftReturn {
        switch focus {
        case .composer:
            guard !chat.isActionPalettePresented, !chat.isItemActionPanePresented else { return .ignored }
            // A chooser or the question card over the composer takes Return
            // whatever the modifier; a new line would land under it.
            if chat.isAskQuestionActive || chat.isModelChooserPresented || chat.isAssistantChooserPresented
                || chat.isAddContextMenuPresented || chat.isTransformChooserPresented {
                chat.submitFromComposer()
                return .handled
            }
            return .insertNewline
        case .find:
            findPrevious()
            return .handled
        case .rail, .rename, .other:
            return .ignored
        }
    }

    /// ↑ and ↓ while the keyboard is in the rail's search. The composer's
    /// arrows are Quick AI's own (`ComposerKeyRouting`).
    func handleRailArrow(_ delta: Int) -> Bool {
        guard focus == .rail else { return false }
        moveRailSelection(delta)
        return true
    }

    /// Modified keys, before the chat's own shortcuts. Returns `true` when
    /// the window used the key.
    func handleKeyEquivalent(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        func matches(_ shortcut: KeyShortcut) -> Bool {
            shortcut.matches(characters: characters, keyCode: keyCode, modifiers: modifiers)
        }
        if matches(Self.chatListShortcut) || matches(QuickViewModel.recentChatsShortcut) {
            // `⌘P` is Recent Chats in Quick AI; here the chat list is it.
            if matches(QuickViewModel.recentChatsShortcut), isRailVisible, focus != .rail {
                focusRail()
            } else {
                toggleRail()
            }
            return true
        }
        if matches(Self.findShortcut) {
            openFind()
            return true
        }
        if isFindPresented, matches(Self.findNextShortcut) {
            findNext()
            return true
        }
        if isFindPresented, matches(Self.findPreviousShortcut) {
            findPrevious()
            return true
        }
        if modifiers.overlayRelevant == [.command],
           let digit = characters.flatMap(Int.init), digit >= 1, digit <= Self.jumpRowCount {
            // A number past the list does nothing, and never reaches the chat.
            jumpToRailRow(digit)
            return true
        }
        if focus == .rail, modifiers.overlayRelevant == [.command], characters?.lowercased() == "k" {
            toggleRailActions()
            return true
        }
        if performRailRowShortcut(characters: characters, keyCode: keyCode, modifiers: modifiers) {
            return true
        }
        // Everything else is the chat's: ⌘K, ⌘N, ⌘R, ⇧⌘O, ⌘[ ⌘] …
        if modifiers.overlayRelevant == [.command], characters?.lowercased() == "k" {
            chat.handleCommandK()
            return true
        }
        return chat.performShortcut(characters: characters, keyCode: keyCode, modifiers: modifiers)
    }
}
