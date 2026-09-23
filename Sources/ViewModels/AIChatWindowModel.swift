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

    /// `⌃⌘S`: the built-in key for the chat list. The header tooltip, the
    /// `⌘K` row and the menu equivalent draw the owner's resolved caps
    /// (`chat.shortcutLabel`); this is the built-in value the key tables and
    /// the free-key checks name.
    nonisolated static let chatListShortcut: KeyShortcut = .controlCommand("s")
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
        /// A waiting card of the Chief of Staff (↑↓ from the composer).
        case cards
        /// A waiting card's Edit fields.
        case cardEdit
        /// The Chief of Staff's New task sheet or project picker.
        case cosForm
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
    /// Search within the highlighted chat's actions, separate from chat search.
    var railActionQuery = "" {
        didSet { if railActionQuery != oldValue { railActionIndex = 0 } }
    }
    /// Delete is pressed twice: the first press arms it on that chat.
    var deleteArmedChatID: UUID?
    /// The chat being renamed in its row, and the name typed so far.
    var renamingChatID: UUID?
    var renameText = ""
    /// Bumped to move the keyboard into the rail's search or the rename field.
    var railFocusRequest = 0
    var renameFocusRequest = 0

    /// Find in chat (`⌘F`): the bar above the thread, its text, and which
    /// hit is current. A hit is a range inside the text the thread draws,
    /// not a message: "3 of 17" counts hits.
    var isFindPresented = false
    var findQuery = "" {
        didSet { if findQuery != oldValue { moveToFirstMatch() } }
    }
    /// The current hit, over `findHits`.
    var currentMatchIndex: Int?
    var findFocusRequest = 0
    /// ⌘ is down: the rail shows every row's ⌘1…⌘9 number.
    var isCommandHeld = false
    /// The hits of the last query, and what they were found in, so a
    /// render that reads them several times searches once.
    @ObservationIgnored private var findCache: (query: String, messages: [QuickMessage], hits: [FindHit])?
    /// What each message draws, as find reads it: the question's text, or
    /// each answer segment's rendered text. Kept per message and content.
    @ObservationIgnored private var findCorpus: [UUID: FindCorpusEntry] = [:]
    /// Where the thread measured each hit, under its message's head.
    @ObservationIgnored private var measuredHitOffsets: [FindHit: CGFloat] = [:]
    /// The offset last asked of the thread for the current hit.
    @ObservationIgnored private var requestedHitOffset: (hit: FindHit, y: CGFloat)?
    /// Rail rows' question counts and times, per history.
    @ObservationIgnored private var railFactsCache: (history: [QuickConversation], facts: [String: RailFacts])?

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
            queue: nil
        ) { [weak self] _ in
            // Delivered on the posting thread and handed to the main actor
            // without waiting: a `.main` queue here made every UserDefaults
            // write off the main thread block until the main thread ran this
            // (a suite-wide hang in tests). One re-read per change; nothing
            // to cancel, so no handle is kept.
            Task { @MainActor [weak self] in self?.syncAlwaysOnTopFromDefaults() }
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
        releaseCards()
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

    // MARK: - Chief of Staff

    /// The Chief of Staff, when the app has one and its CLI is installed.
    var chiefOfStaff: ChiefOfStaffModel? {
        chat.chiefOfStaff.flatMap { $0.isAvailable ? $0 : nil }
    }

    /// The pinned Chief of Staff conversation is the open chat.
    var isChiefOfStaffOpen: Bool { chiefOfStaff != nil && chat.isChiefOfStaffChatOpen }

    /// The rail's first row: the pinned conversation, always there, never
    /// renamed or deleted. It answers a search for its name or `cos`.
    var chiefOfStaffRailItem: LauncherCatalogItem? {
        guard let chiefOfStaff else { return nil }
        let item = LauncherCatalogItem(
            kind: .conversation,
            itemID: ChiefOfStaffModel.conversationID.uuidString,
            title: ChiefOfStaffModel.title,
            detail: chiefOfStaff.summary,
            value: "",
            keywords: "cos",
            isPinned: true
        )
        let query = FuzzyMatcher.fold(railQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return item }
        return FuzzyMatcher.fold("\(item.title) cos").contains(query) ? item : nil
    }

    static func isChiefOfStaffItem(_ itemID: String?) -> Bool {
        itemID == ChiefOfStaffModel.conversationID.uuidString
    }

    /// Opens the pinned conversation: the backing chat, the waiting cards
    /// above it, and the keyboard in the composer, or on `proposalID`'s card
    /// when a notification named one.
    func openChiefOfStaff(proposalID: String? = nil) {
        guard chiefOfStaff != nil else { return }
        closeFind()
        chat.openChiefOfStaffChat()
        railIndex = currentRailIndex ?? railIndex
        railActionsPresented = false
        deleteArmedChatID = nil
        if let proposalID {
            focusCards(proposalID)
        } else {
            focusComposer()
        }
        window?.showWindow()
    }

    /// The keyboard onto the waiting cards: `id`'s, or the newest.
    func focusCards(_ id: String? = nil) {
        guard let chiefOfStaff, chiefOfStaff.firstFocusable != nil || id != nil else { return }
        chiefOfStaff.focusCard(id)
        focus = .cards
    }

    /// The keyboard leaves the cards; an open Edit closes.
    private func releaseCards() {
        chiefOfStaff?.releaseCardFocus()
    }

    /// The Chief of Staff's keys, while its conversation is open: ↑↓ onto
    /// and over the cards (←→ between board columns), ⌘↩ Do it, ⌘E Edit,
    /// ⌘L Later, ⌘⌫ No, ⌘R Bring back, esc back; and anywhere in it ⌥⌘1
    /// List, ⌥⌘2 Board, ⌘N New task, ⌘I health, ⇧⌘P project, ⇧⌘↩ Do all TODAY,
    /// ⇧⌘T tasks. True when the key was used; every other chat is untouched.
    func handleChiefOfStaffKey(key: VirtualKey?, characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard isChiefOfStaffOpen, let chiefOfStaff else { return false }
        if focus == .cosForm {
            // The sheet's fields type; ⌘↩ adds the task.
            guard key?.isReturn == true, modifiers.overlayRelevant == [.command], chiefOfStaff.newTask != nil else { return false }
            chiefOfStaff.submitNewTask()
            if chiefOfStaff.newTask == nil { returnFromCosForm() }
            return true
        }
        let place: ChiefOfStaffKeys.Place
        switch focus {
        case .cards:
            if let menu = chiefOfStaff.laterMenu {
                place = menu.isPicking ? .laterPicking : .laterMenu
            } else {
                place = .card(board: chiefOfStaff.viewMode == .board)
            }
        case .cardEdit:
            place = .editing
        case .composer:
            // A chooser, the palette, or the question card over the
            // composer keeps its own keys.
            switch chat.topLayer {
            case .itemActionForm, .itemActionPane, .actionPalette, .transformChooser, .modelChooser,
                 .assistantChooser, .captureChooser, .addContextMenu, .slashCommandPalette, .recentChats:
                return false
            default:
                if chat.isAskQuestionActive { return false }
            }
            place = .composer(draftIsEmpty: chat.input.isEmpty)
        default:
            return false
        }
        guard let action = ChiefOfStaffKeys.route(
            key: key,
            characters: characters,
            modifiers: modifiers,
            place: place,
            hasCards: chiefOfStaff.firstFocusable != nil
        ) else { return false }
        perform(action, on: chiefOfStaff)
        return true
    }

    private func perform(_ action: ChiefOfStaffKeys.Action, on chiefOfStaff: ChiefOfStaffModel) {
        switch action {
        case .focusCards:
            focusCards()
        case .move(let delta):
            chiefOfStaff.moveCardFocus(delta)
            if chiefOfStaff.focusedCardID == nil { focusComposer() }
        case .moveColumn(let delta):
            chiefOfStaff.moveColumnFocus(delta)
        case .toComposer:
            focusComposer()
        case .doIt:
            chiefOfStaff.doFocused()
        case .edit:
            chiefOfStaff.editFocused()
            if chiefOfStaff.isEditingFocusedCard { focus = .cardEdit }
        case .later:
            chiefOfStaff.openLaterMenu()
        case .no:
            chiefOfStaff.noFocused()
        case .bringBack:
            chiefOfStaff.bringBackFocused()
        case .runEdit:
            chiefOfStaff.doFocused()
            focus = .cards
        case .cancelEdit:
            if let id = chiefOfStaff.focusedCardID { chiefOfStaff.cancelEdit(id) }
            focus = .cards
        case .menuMove(let delta):
            chiefOfStaff.moveLaterMenu(delta)
        case .menuPick(let choice):
            chiefOfStaff.chooseLater(choice)
        case .menuClose:
            chiefOfStaff.laterMenu = nil
        case .showList:
            chiefOfStaff.viewMode = .list
        case .showBoard:
            chiefOfStaff.viewMode = .board
        case .newTask:
            chiefOfStaff.openNewTask()
            focus = .cosForm
        case .toggleHealth:
            chiefOfStaff.isHealthDetailShown.toggle()
        case .pickProject:
            chiefOfStaff.toggleProjectPicker()
            if chiefOfStaff.projectPicker != nil { focus = .cosForm }
        case .doAllToday:
            chiefOfStaff.doAllToday()
        case .toggleTasks:
            chiefOfStaff.toggleTasks()
        }
    }

    /// The sheet or picker closed: the keyboard goes back to the card it
    /// came from, else the composer.
    private func returnFromCosForm() {
        if chiefOfStaff?.focusedCardID != nil {
            focus = .cards
        } else {
            focusComposer()
        }
    }

    // MARK: - Rail

    /// The rail's rows: the pinned Chief of Staff first, then pinned chats,
    /// then recent, narrowed and ranked by the search every chat list
    /// shares. The view model caches the rows per query, so reading them
    /// again costs nothing.
    var railItems: [LauncherCatalogItem] {
        let chats = chat.chatItems(matching: railQuery)
        guard let chiefOfStaffRailItem else { return chats }
        return [chiefOfStaffRailItem] + chats
    }

    /// While a query is typed the rail is one ranked list under "Results";
    /// pinned rows keep their glyph but are not floated (spec 4.5).
    var isRailSearching: Bool { !ChatSearchQuery(railQuery).isEmpty }

    var pinnedRailItems: [LauncherCatalogItem] { isRailSearching ? [] : railItems.filter(\.isPinned) }
    var recentRailItems: [LauncherCatalogItem] { isRailSearching ? [] : railItems.filter { !$0.isPinned } }

    /// What a rail row needs from its chat besides the item: the question
    /// count and the time.
    struct RailFacts: Equatable {
        let questions: Int
        let updatedAt: Date
    }

    /// Every chat's facts, read once per history.
    private var railFacts: [String: RailFacts] {
        let history = chat.history
        if let railFactsCache, railFactsCache.history == history { return railFactsCache.facts }
        var facts: [String: RailFacts] = [:]
        for conversation in history {
            facts[conversation.id.uuidString] = RailFacts(
                questions: conversation.messages.lazy.filter { $0.role == .user }.count,
                updatedAt: conversation.updatedAt
            )
        }
        railFactsCache = (history, facts)
        return facts
    }

    /// A rail row's second line, short enough for the rail: the question
    /// count and the time today, the day before that. A row found by its
    /// text shows its snippet there instead, and this moves to the tooltip.
    func railDetail(for item: LauncherCatalogItem, now: Date = Date()) -> String {
        if Self.isChiefOfStaffItem(item.itemID) { return chiefOfStaff?.summary ?? item.detail }
        guard let facts = railFacts[item.itemID] else { return item.detail }
        let count = facts.questions == 1 ? "1 question" : "\(facts.questions) questions"
        let stamp = Calendar.current.isDate(facts.updatedAt, inSameDayAs: now)
            ? facts.updatedAt.formatted(date: .omitted, time: .shortened)
            : facts.updatedAt.formatted(.dateTime.month(.abbreviated).day())
        return "\(count) · \(stamp)"
    }

    /// Characters a rail snippet keeps before its hit: the rail is narrow.
    static let railSnippetLead = 8

    /// The snippet a rail row shows under its title, cut to the rail.
    func railSnippet(for item: LauncherCatalogItem) -> ChatSnippet? {
        item.chatSnippet?.keepingLead(Self.railSnippetLead)
    }

    /// The `⌘` number a row answers to (`⌘1`…`⌘9`), by drawn position
    /// among the chats: the pinned Chief of Staff row above them takes none,
    /// so every chat keeps the number it had.
    func railNumber(at index: Int) -> Int? {
        let offset = chiefOfStaffRailItem == nil ? 0 : 1
        let position = index - offset
        return position >= 0 && position < Self.jumpRowCount ? position + 1 : nil
    }

    /// What the rail says when it has no row.
    var railEmptyText: String {
        if !railQuery.isEmpty { return "No chats match" }
        return chat.settings.historyEnabled ? "No chats yet" : "Chat history is off"
    }

    /// The open chat's id, for its marker in the rail.
    var openChatItemID: String? { chat.currentConversation?.id.uuidString }

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
            let count = filteredRailActions.count
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
            let actions = filteredRailActions
            guard actions.indices.contains(railActionIndex) else { return }
            performRailAction(actions[railActionIndex])
            return
        }
        guard let item = highlightedRailItem else { return }
        openChat(itemID: item.itemID)
    }

    /// Opens a chat from the rail (a click, Return, or `⌘1`…`⌘9`). The rail
    /// stays; the keyboard goes back to the composer.
    func openChat(itemID: String) {
        if Self.isChiefOfStaffItem(itemID) {
            openChiefOfStaff()
            return
        }
        releaseCards()
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
        let items = chat.chatItems(matching: railQuery)
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

        /// The registry action this row's key belongs to: the owner's resolved
        /// table is what the router matches and what a view draws.
        var shortcutAction: ShortcutAction {
            switch self {
            case .pin: .pinChat
            case .rename: .renameChat
            case .delete: .deleteChat
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

    /// The pinned Chief of Staff row has none: it cannot be pinned off,
    /// renamed, or deleted.
    var railActions: [RailAction] {
        guard let item = highlightedRailItem, !Self.isChiefOfStaffItem(item.itemID) else { return [] }
        return RailAction.allCases
    }

    var filteredRailActions: [RailAction] {
        QuickViewModel.rankByQuery(railActions, query: railActionQuery) { title(of: $0) }
    }

    /// A row action's title for the highlighted chat.
    func title(of action: RailAction) -> String {
        title(of: action, for: highlightedRailItem)
    }

    /// The rail already identifies the chat. Keep verbs short enough to
    /// fit beside the shortcut; context menus and VoiceOver use full titles.
    func compactTitle(of action: RailAction) -> String {
        switch action {
        case .pin: highlightedRailItem?.isPinned == true ? "Unpin" : "Pin"
        case .rename: "Rename"
        case .delete:
            deleteArmedChatID != nil && highlightedRailItem?.itemID == deleteArmedChatID?.uuidString
                ? "Confirm" : "Delete"
        }
    }

    /// A row action's title for one row (its context menu, VoiceOver).
    func title(of action: RailAction, for item: LauncherCatalogItem?) -> String {
        switch action {
        case .pin: item?.isPinned == true ? "Unpin Chat" : "Pin Chat"
        case .rename: "Rename Chat"
        case .delete:
            item.flatMap { UUID(uuidString: $0.itemID) } == deleteArmedChatID
                && deleteArmedChatID != nil
                ? "Press Again to Delete"
                : "Delete Chat"
        }
    }

    /// A row action from the row's context menu or a VoiceOver action: the
    /// row is highlighted first, so the action is the one `⌘K` would run.
    func performRailAction(_ action: RailAction, itemID: String) {
        guard let index = railItems.firstIndex(where: { $0.itemID == itemID }) else { return }
        if index != railIndex {
            if deleteArmedChatID?.uuidString != itemID { deleteArmedChatID = nil }
            railIndex = index
        }
        performRailAction(action)
    }

    func toggleRailActions() {
        guard !railActions.isEmpty else { return }
        railActionsPresented.toggle()
        railActionIndex = 0
        railActionQuery = ""
        if !railActionsPresented { focusRail() }
    }

    func performRailAction(_ action: RailAction) {
        guard let item = highlightedRailItem, !Self.isChiefOfStaffItem(item.itemID),
              let id = UUID(uuidString: item.itemID) else { return }
        switch action {
        case .pin:
            deleteArmedChatID = nil
            chat.togglePinConversation(id: id)
            // The row moves between Pinned and Recent; the highlight follows it.
            railIndex = railItems.firstIndex { $0.itemID == item.itemID } ?? railIndex
            railActionsPresented = false
            focusRail()
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
            focusRail()
        }
    }

    /// The row keys (`⇧⌘P`, `⌘E`, `⌃X`) on the highlighted rail row, while
    /// the keyboard is in the rail.
    private func performRailRowShortcut(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard focus == .rail, highlightedRailItem != nil,
              let action = RailAction.allCases.first(where: {
                  chat.shortcuts.matches(
                      $0.shortcutAction,
                      characters: characters,
                      keyCode: keyCode,
                      modifiers: modifiers
                  )
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

    /// Every hit of the find text in the open chat, in document order: the
    /// rendered text of each answer (so Markdown syntax, link targets, and
    /// code fences never match), the text of its code blocks, and each
    /// question. The query is one phrase, folded as the chat search folds
    /// it (case, accents, width).
    var findHits: [FindHit] {
        let query = Self.findNeedle(findQuery)
        guard isFindPresented, !query.isEmpty else { return [] }
        let messages = chat.conversationMessages
        if let findCache, findCache.query == query, findCache.messages == messages { return findCache.hits }
        var hits: [FindHit] = []
        var live = Set<UUID>()
        for message in messages {
            live.insert(message.id)
            for part in corpus(for: message).parts {
                for range in SearchText.ranges(of: query, in: part.text) {
                    hits.append(FindHit(messageID: message.id, part: part.part, range: range))
                }
            }
        }
        findCorpus = findCorpus.filter { live.contains($0.key) }
        // Offsets were measured for the last hits; the thread measures anew.
        measuredHitOffsets = [:]
        findCache = (query, messages, hits)
        return hits
    }

    /// The find text as searched: compatibility forms mapped, white space
    /// as one space, trimmed.
    static func findNeedle(_ query: String) -> String {
        SearchText.collapsingWhitespace(query.precomposedStringWithCompatibilityMapping)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What one message draws, as find searches it.
    private func corpus(for message: QuickMessage) -> FindCorpusEntry {
        if let entry = findCorpus[message.id], entry.content == message.content { return entry }
        let entry = FindCorpusEntry(message)
        findCorpus[message.id] = entry
        return entry
    }

    /// The hit the find bar is on, drawn with the selection fill.
    var currentHit: FindHit? {
        let hits = findHits
        guard let index = currentMatchIndex, hits.indices.contains(index) else { return nil }
        return hits[index]
    }

    /// The message the current hit is in.
    var currentMatchID: UUID? { currentHit?.messageID }

    /// What the thread draws: every hit with the hover fill, the current
    /// one with the selection fill.
    var findHighlights: ThreadFindHighlights? {
        let hits = findHits
        guard !hits.isEmpty else { return nil }
        return ThreadFindHighlights(hits: hits, current: currentHit)
    }

    /// "3 of 17", "No matches", or nothing before anything is typed.
    var findStatus: String {
        guard !Self.findNeedle(findQuery).isEmpty else { return "" }
        let count = findHits.count
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
        requestedHitOffset = nil
        focusComposer()
    }

    /// Return and `⌘G`: the next hit, across messages, wrapping. `⇧↩` and
    /// `⇧⌘G`: the previous one.
    func findNext() { stepMatch(1) }
    func findPrevious() { stepMatch(-1) }

    private func stepMatch(_ delta: Int) {
        let count = findHits.count
        guard count > 0 else {
            currentMatchIndex = nil
            return
        }
        let next = currentMatchIndex.map { ListSelection.wrappedIndex($0, by: delta, count: count) }
            ?? (delta > 0 ? 0 : count - 1)
        reveal(next)
    }

    private func moveToFirstMatch() {
        guard !findHits.isEmpty else {
            currentMatchIndex = nil
            return
        }
        reveal(0)
    }

    /// Makes a hit current: a folded question with the hit in it opens,
    /// and the thread scrolls the hit (not the message's head) a third of
    /// the way down the view.
    private func reveal(_ index: Int) {
        currentMatchIndex = index
        let hit = findHits[index]
        if hit.part == .question,
           let message = chat.conversationMessages.first(where: { $0.id == hit.messageID }),
           chat.collapseState(for: message).isCollapsible,
           !chat.expandedTranscriptMessageIDs.contains(hit.messageID) {
            chat.expandedTranscriptMessageIDs.insert(hit.messageID)
        }
        let y = measuredHitOffsets[hit] ?? 0
        requestedHitOffset = (hit, y)
        chat.scrollThread(.messageOffset(hit.messageID, y))
    }

    /// The thread measured where a hit sits under its message's head. The
    /// current hit's first measure (or a new one, after the text reflowed)
    /// scrolls again, so the hit itself lands in view.
    func noteFindHitOffset(_ y: CGFloat, for hit: FindHit) {
        measuredHitOffsets[hit] = y
        guard hit == currentHit else { return }
        if let requestedHitOffset, requestedHitOffset.hit == hit, abs(requestedHitOffset.y - y) < 1 { return }
        requestedHitOffset = (hit, y)
        chat.scrollThread(.messageOffset(hit.messageID, y))
    }

    // MARK: - Focus

    func focusComposer() {
        releaseCards()
        focus = .composer
        chat.requestInputFocus()
    }

    // MARK: - Window actions (⌘K)

    var windowSurfaceActions: [QuickAISurfaceAction] {
        var actions: [QuickAISurfaceAction] = [
            isRailVisible ? .hideChatList : .showChatList,
            .findInChat,
            isAlwaysOnTop ? .stopKeepingOnTop : .keepOnTop,
        ]
        // Added after the window's own rows, so their order never moves.
        if chiefOfStaff != nil {
            actions.append(isChiefOfStaffOpen ? .newTask : .chiefOfStaff)
        }
        return actions
    }

    func performWindowSurfaceAction(_ action: QuickAISurfaceAction) {
        switch action {
        case .chiefOfStaff: openChiefOfStaff()
        case .newTask:
            chiefOfStaff?.openNewTask()
            focus = .cosForm
        case .showChatList: showRail()
        case .hideChatList: hideRail()
        case .findInChat: openFind()
        case .keepOnTop: isAlwaysOnTop = true; focusComposer()
        case .stopKeepingOnTop: isAlwaysOnTop = false; focusComposer()
        // The chat's own actions, run by the view model.
        case .resetSize, .attach, .copyMessage, .captureMessage, .searchSettings: focusComposer()
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
             .modelChooser, .assistantChooser, .captureChooser, .addContextMenu, .streaming:
            chat.popTopLayer()
            return true
        default:
            break
        }
        if focus == .cosForm, let chiefOfStaff {
            chiefOfStaff.newTask = nil
            chiefOfStaff.projectPicker = nil
            chiefOfStaff.laterMenu = nil
            returnFromCosForm()
        } else if focus == .cardEdit, let chiefOfStaff, let id = chiefOfStaff.focusedCardID {
            chiefOfStaff.cancelEdit(id)
            focus = .cards
        } else if focus == .cards {
            focusComposer()
        } else if isChiefOfStaffOpen, let chiefOfStaff, chiefOfStaff.isHealthDetailShown || chiefOfStaff.newTask != nil
                    || chiefOfStaff.projectPicker != nil {
            chiefOfStaff.isHealthDetailShown = false
            chiefOfStaff.newTask = nil
            chiefOfStaff.projectPicker = nil
        } else if renamingChatID != nil {
            cancelRename()
        } else if railActionsPresented {
            railActionsPresented = false
            deleteArmedChatID = nil
            focusRail()
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
        case .cards:
            // A bare Return never decides a card: ⌘↩ does.
            return true
        case .cardEdit, .cosForm, .other:
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
                || chat.isCaptureChooserPresented || chat.isAddContextMenuPresented || chat.isTransformChooserPresented {
                chat.submitFromComposer()
                return .handled
            }
            return .insertNewline
        case .find:
            findPrevious()
            return .handled
        case .cards:
            return .handled
        case .rail, .rename, .cardEdit, .cosForm, .other:
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
        // The window's own settings are the truth here, the same value its
        // views and the chat's router read.
        let bindings = chat.shortcuts
        func matchesBinding(_ action: ShortcutAction) -> Bool {
            bindings.matches(action, characters: characters, keyCode: keyCode, modifiers: modifiers)
        }
        func matches(_ shortcut: KeyShortcut) -> Bool {
            shortcut.matches(characters: characters, keyCode: keyCode, modifiers: modifiers)
        }
        if matchesBinding(.chatList) || matchesBinding(.recentChats) {
            // `⌘P` is Recent Chats in Quick AI; here the chat list is it.
            if matchesBinding(.recentChats), isRailVisible, focus != .rail {
                focusRail()
            } else {
                toggleRail()
            }
            return true
        }
        if matchesBinding(.findInChat) {
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
        if focus == .rail, matchesBinding(.commandPalette) {
            toggleRailActions()
            return true
        }
        if performRailRowShortcut(characters: characters, keyCode: keyCode, modifiers: modifiers) {
            return true
        }
        // Everything else is the chat's: ⌘K, ⌘N, ⌘R, ⇧⌘O, ⌘[ ⌘] …
        if matchesBinding(.commandPalette) {
            chat.handleCommandK()
            return true
        }
        return chat.performShortcut(characters: characters, keyCode: keyCode, modifiers: modifiers)
    }
}

// MARK: - Find in chat: hits

/// A part of a message Find in Chat searches: the question the user sent,
/// or one segment of an answer (a prose run or a code block, as
/// `MarkdownRenderer.segments` splits it; the index is the segment's id).
enum FindPart: Hashable, Sendable {
    case question
    case segment(Int)
}

/// One hit: a range inside the text one part of one message draws.
struct FindHit: Hashable, Sendable {
    let messageID: UUID
    let part: FindPart
    /// UTF-16 range in the part's drawn text.
    let range: TextRange
}

/// What one message draws, as find reads it. An answer's prose segments
/// are the rendered text (`MarkdownRenderer.render`), the same string its
/// text view holds, so a range found here is a range there.
struct FindCorpusEntry {
    struct Part {
        let part: FindPart
        let text: String
    }

    let content: String
    let parts: [Part]

    init(_ message: QuickMessage) {
        content = message.content
        switch message.role {
        case .user:
            parts = [Part(part: .question, text: message.content)]
        case .system:
            parts = []
        case .assistant:
            // A question the model asked draws as a card, not as prose.
            guard message.askUserQuestion == nil else {
                parts = []
                return
            }
            parts = MarkdownRenderer.segments(message.content).map { segment in
                switch segment.content {
                case .prose(let source):
                    Part(part: .segment(segment.id), text: MarkdownRenderer.render(source).string)
                case .code(let code):
                    Part(part: .segment(segment.id), text: code.code)
                }
            }
        }
    }
}

/// What the thread draws for Find in Chat: every hit in the hover fill,
/// the current one in the selection fill ("hover is half the selection
/// fill", applied to text).
struct ThreadFindHighlights: Equatable {
    let current: FindHit?
    private let ranges: [UUID: [FindPart: [TextRange]]]

    init(hits: [FindHit], current: FindHit?) {
        self.current = current
        var ranges: [UUID: [FindPart: [TextRange]]] = [:]
        for hit in hits {
            ranges[hit.messageID, default: [:]][hit.part, default: []].append(hit.range)
        }
        self.ranges = ranges
    }

    /// The hits in one part of one message.
    func ranges(in messageID: UUID, part: FindPart) -> [TextRange] {
        ranges[messageID]?[part] ?? []
    }

    /// Every segment's hits in one answer, by segment id.
    func segmentRanges(in messageID: UUID) -> [Int: [TextRange]] {
        var output: [Int: [TextRange]] = [:]
        for (part, list) in ranges[messageID] ?? [:] {
            if case .segment(let id) = part { output[id] = list }
        }
        return output
    }

    /// The current hit when it is in this message.
    func current(in messageID: UUID) -> FindHit? {
        current?.messageID == messageID ? current : nil
    }
}
