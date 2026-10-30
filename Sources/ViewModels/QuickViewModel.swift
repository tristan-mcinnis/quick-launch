import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

/// Does nothing but say so. Used when a presenter was assigned and has since
/// been released (a short-lived test double): the view model must not fall back
/// to posting legacy notifications that nothing asked for. Every call leaves a
/// trace, so an overlay action that reached no presenter is visible rather
/// than silently swallowed.
@MainActor
private final class ReleasedOverlayPresenter: OverlayPresenting {
    func presentOverlay() { Self.report("presentOverlay") }
    func dismissOverlay() { Self.report("dismissOverlay") }
    func openSettings() { Self.report("openSettings") }
    func openTranslator() { Self.report("openTranslator") }
    func openTypeToClick() { Self.report("openTypeToClick") }

    private static func report(_ action: String) {
        AppLog.overlay.error(
            "Overlay action \(action, privacy: .public) dropped: the assigned presenter was released"
        )
    }
}

@Observable @MainActor final class QuickViewModel {

    // MARK: - Published state

    var input: String = ""
    /// The answer on screen. Every lane but a local answer asked in root
    /// search (math, conversions, dates, system facts, drawn inline there as
    /// `rootAnswer`) lives on the Quick AI surface, so a non-empty answer
    /// presents it.
    var output: String = "" {
        didSet { if !output.isEmpty, !isQuickAIPresented { isQuickAIPresented = true } }
    }
    /// Where the answer on screen came from. A model answer is a turn of the
    /// thread and the header names the model; a command action's output and
    /// are not turns, and the header names them instead.
    enum AnswerSource: Equatable, Sendable {
        case model
        /// A command action or a system command, by its name.
        case command(String)
        /// Math, a conversion, a date, or a system fact asked from the
        /// Quick AI composer: answered here, never by the model.
        case local
    }
    var answerSource: AnswerSource = .model
    /// A local answer shown inline in root search under its question, as
    /// v1.3.0 drew it: math, a conversion, a date, or a system fact. It
    /// never opens the Quick AI surface and never joins a chat.
    struct RootAnswer: Equatable, Sendable {
        let question: String
        let answer: String
    }
    var rootAnswer: RootAnswer?
    /// The live row for "<text> in <language>" in root search.
    var inlineTranslation: InlineTranslation?
    @ObservationIgnored private var inlineTranslationTask: Task<Void, Never>?
    /// A provider error on a turn of the thread, drawn under that question
    /// with Retry. The turn stays; `⌘R` asks it again. Errors that belong to
    /// no turn (permissions, no provider or key) use `errorMessage`.
    struct ThreadError: Equatable, Sendable {
        let messageID: UUID
        let message: String
    }
    var threadError: ThreadError?
    /// Hands the thread the saved spot for the chat it now shows, once.
    func takeOpeningAnchor(for conversationID: UUID) -> ThreadScrollAnchor? {
        defer { openingAnchor = nil }
        guard let opening = openingAnchor, opening.conversationID == conversationID else { return nil }
        return opening.anchor
    }

    /// Whether the thread keeps the newest text in view. True while the
    /// reader is within `threadFollowThreshold` of the bottom, and again on
    /// every new question; false once they scroll up, which shows the
    /// "Latest" chip.
    var isThreadFollowingBottom = true
    /// The saved spot the chat just opened was left at, for the thread to
    /// take on its next chat change. Kept apart from the follow flag, which
    /// the previous chat's last report can still flip before the thread
    /// looks.
    private(set) var openingAnchor: (conversationID: UUID, anchor: ThreadScrollAnchor)?
    /// Where each chat was left when the reader had scrolled up in it. The
    /// thread writes it as the reader scrolls and reads it when the chat opens.
    @ObservationIgnored var threadAnchors = ThreadScrollAnchorStore()
    /// How close to the bottom counts as reading the newest text.
    static let threadFollowThreshold = House.Control.row
    /// Return while an answer streams queues the typed follow-up: it stays
    /// in the composer and is sent when the stream ends. Escape stops the
    /// stream and keeps the text, unsent.
    var isFollowUpQueued = false
    var isStreaming: Bool = false {
        didSet { if isStreaming { isQuickAIPresented = true } }
    }
    /// Which models the user turned off and the reasoning effort chosen
    /// for each. The app's one store; tests pass an in-memory one.
    @ObservationIgnored var modelPreferences: ModelPreferenceStore = .shared
    /// The Quick AI surface: the thread with its own header and composer, in
    /// place of the launcher. Opened by Tab, the Ask AI row, or any answer;
    /// Escape and the back chevron return to root search with the thread
    /// kept, so the surface and the thread are separate state.
    var isQuickAIPresented = false
    /// `⌘P`: Recent Chats replaces the thread inside the Quick AI surface.
    var isRecentChatsPresented = false {
        didSet { if !isRecentChatsPresented { resumeQueuedFollowUp() } }
    }
    /// Highlighted row of the Recent Chats list.
    var recentChatsIndex = 0
    /// "Search web: …" for the ask in flight, drawn as the tool line above
    /// its answer while the search runs and the answer streams. When the
    /// answer lands the line moves onto it (`QuickMessage.toolRecords`), so
    /// a reopened chat still shows it.
    var webSearchNote: String?
    /// The tool lines of the answer streaming now, in the order the calls
    /// finished. They join the answer's message when it lands.
    var liveToolRecords: [ChatToolRecord] = []
    /// The tools chosen on the empty surface, before a chat exists. The chat
    /// the next question starts takes them; nil means the defaults.
    var pendingChatTools: Set<ChatToolKind>?
    /// Change Model on the empty surface, before a chat exists: the chat the
    /// next question starts takes it. Nil means the Quick AI default. Per
    /// view: the other window never sees it.
    var pendingModelChoice: ChatModelChoice?
    /// A second list inside the `⌘K` palette: the chat's tools, or the
    /// answer's sources. Escape returns to the full list.
    var actionPaletteSubmenu: ActionPaletteSubmenu?
    /// The thread's closing line after Continue in pi ("Opened in pi ·
    /// tmux session ql-3fa9c1"), or what happened to the chat on screen
    /// ("This chat was deleted…", an answer stopped by a hand-off, a chat
    /// that moved to the other view). Like the search line it belongs to
    /// the chat on screen: the next question, another chat, and a new chat
    /// clear it, and it is never written to history.
    var threadNotice: String?
    /// The glyph `threadNotice` is drawn with: the terminal for a pi
    /// hand-off, an info mark for what happened to the chat.
    var threadNoticeSymbol = QuickViewModel.piNoticeSymbol
    static let piNoticeSymbol = "terminal"
    static let chatNoticeSymbol = "info.circle"
    /// True while Continue in pi runs, so a second press waits for it.
    private(set) var isHandingOffToPi = false
    /// Short progress note from the service while streaming ("Searching
    /// the web…"); shown in place of "Thinking…" until answer text lands.
    var streamingStatus: String?
    var errorMessage: String? = nil
    /// Settings and chat history live in `store`, which the AI Chat window's
    /// own view model shares: one store, two views.
    let store: QuickStore
    var settings: QuickSettings {
        get { store.settings }
        set { store.settings = newValue }
    }

    // MARK: - In-app shortcuts

    /// The live in-app shortcut table, read through this view model's own
    /// settings: the router, the footer hints, the palette rows, the key-cap
    /// badges and the tooltips all resolve through it, so a rebind in Settings
    /// redraws every surface at once. The two AppKit surfaces that have no
    /// view model of their own (the launcher panel, the AI Chat menu) are
    /// handed these same bindings by their owner.
    var shortcuts: ShortcutBindings { settings.shortcuts }

    /// The key an action answers to now, for caps and help text.
    func shortcut(for action: ShortcutAction) -> KeyShortcut {
        shortcuts.keyShortcut(for: action)
    }

    func shortcutKeyCaps(for action: ShortcutAction) -> [String] {
        shortcuts.keyCaps(for: action)
    }

    func shortcutDisplayName(for action: ShortcutAction) -> String {
        shortcuts.displayName(for: action)
    }

    /// The caps as one label, for a tooltip: `⌥⌘K`.
    func shortcutLabel(for action: ShortcutAction) -> String {
        shortcuts.displayName(for: action)
    }

    /// Why a key may not be bound to an action, given every other setting
    /// that owns a key. Nil means it may.
    func shortcutConflict(for action: ShortcutAction, candidate: ActionHotkey) -> String? {
        settings.shortcutConflict(for: action, candidate: candidate)
    }

    /// Rebinds one action, persists it, and tells the AppKit layers (the AI
    /// Chat menu rebuilds its key equivalents). A collision refuses the change
    /// and returns its message for the row to show; nil means it was applied.
    /// Nothing process-wide is written: the resolved table is derived from
    /// these settings, and every reader holds the settings it belongs to.
    @discardableResult
    func setShortcut(_ hotkey: ActionHotkey?, for action: ShortcutAction) -> String? {
        var updated = settings
        if let conflict = updated.setShortcut(hotkey, for: action) { return conflict }
        settings = updated
        settings.save()
        NotificationCenter.default.post(name: .shortcutBindingsChanged, object: nil)
        return nil
    }

    /// Back to the built-in key for one action.
    func resetShortcut(_ action: ShortcutAction) {
        setShortcut(nil, for: action)
    }

    /// Back to every built-in key.
    func resetAllShortcuts() {
        var updated = settings
        updated.resetAllShortcuts()
        settings = updated
        settings.save()
        NotificationCenter.default.post(name: .shortcutBindingsChanged, object: nil)
    }
    var updateState: UpdateState = .idle
    /// Every write tells the other view on the store (`QuickStore`), so its
    /// open chat follows at once.
    var history: [QuickConversation] {
        get { store.history }
        set {
            store.history = newValue
            store.historyDidChange(by: self)
        }
    }
    /// Where chat history is kept on disk. The app passes the real
    /// `chat-history.json`; nil (the default, and every test) keeps history
    /// in memory only, so a test run never reads, replaces, or deletes the
    /// user's chats.
    let historyFileURL: URL?
    /// The durable, keep-all chat archive. The app passes a real root; nil
    /// (the default, and every test) keeps the archive off, so a test run
    /// never writes to or reads the user's Application Support folder.
    let chatArchive: ChatArchive?
    /// Whether chats are kept at all. With the canonical archive present the
    /// answer is always yes: the legacy "Keep chat history" switch no longer
    /// decides what is read or kept, and its key survives only as rollback
    /// data and as the bound on the legacy cache. Without an archive (the
    /// legacy store, and tests that keep history in memory) the old switch
    /// still decides, because then that store is all there is.
    var canonicalHistoryActive: Bool { chatArchive != nil || settings.historyEnabled }
    var currentConversation: QuickConversation?
    /// The composer's explicit context override, observable and per chat. Nil
    /// means the retrieval policy decides from the wording alone. `/new`,
    /// `/clear`, and opening another chat reset it.
    var contextOverride: ContextOverride?
    /// Records the archive could not read. A non-zero badge tells the user a
    /// chat is missing, instead of the list looking complete.
    var archiveDamagedCount = 0
    /// True while a confirmed "Delete All Chats" is running. The Settings row
    /// reads it to disable its button and say the deletion is in progress.
    private(set) var isClearingHistory = false
    /// Why the last saved-chat operation could not finish. Non-nil is the
    /// honest outcome on screen: the caller must not report success when this
    /// is set. Cleared when a new confirmed operation starts.
    private(set) var savedHistoryOperationError: String?
    /// True only when a caller explicitly accepted reading a newly attached
    /// image as text on this Mac because no vision route is available. False
    /// is the default and the only value any view produces: the Settings and
    /// composer surfaces have no affordance for it, so an image with no route
    /// is refused rather than silently OCR'd. The explicit-consent path exists
    /// for callers that decide to offer it.
    var allowImageTextFallback = false
    /// One-shot: the next submit bypasses the command router and sends the
    /// typed text to the model. Set only by `sendRefusedCommandAsText`; a
    /// repeated Return or ⌘Return never sets it.
    @ObservationIgnored var sendAsTextOnce = false
    /// The last slash line refused locally, if any. Observable, so the
    /// composer can offer the explicit Send as Text action.
    var refusedCommandText: String?
    /// The chat's chosen route, frozen at the start of `submit` before any
    /// async prepare/enrich. Streamed as the `chosen` side of the turn's
    /// selection; the model that actually ran is the `effective` side.
    @ObservationIgnored var pendingModelFreeze: FrozenChatModel?
    /// The turn submitted durably before any external network. `stream`
    /// consumes these ids so the archived turn and the live turn are one.
    @ObservationIgnored var pendingSubmission: PendingSubmission?

    /// Ids reserved for the durable submission of one question.
    struct PendingSubmission: Sendable {
        var conversationID: UUID
        var messageID: UUID
        var attachments: [AttachmentContent]
        var startedAt: Date
    }
    /// Characters of the streaming answer at the last archive checkpoint, so
    /// checkpoints are periodic rather than per-delta.
    @ObservationIgnored var archiveCheckpointCharacters = 0
    /// The durable checkpoint in flight, if any. One at a time, and never
    /// awaited by the token loop: a checkpoint is a whole-file rewrite of
    /// the conversation with two `fsync` calls, so waiting for it between
    /// deltas puts disk latency straight into token rendering.
    @ObservationIgnored var archiveCheckpointTask: Task<Void, Never>?
    /// Which checkpoint owns the slot. An older task that finishes late must
    /// not clear a newer checkpoint's handle.
    @ObservationIgnored var archiveCheckpointGeneration = 0
    /// The archive writes the quit path starts, owned so a quit can wait for
    /// them and learn whether they landed.
    @ObservationIgnored var durability: AnswerDurability?
    /// The archived assistant turn id for the stream in flight, so every
    /// path that persists the answer (completion, stop, error, resume) uses
    /// one record.
    @ObservationIgnored var currentAssistantTurnID: UUID?
    /// When the request started and when its first token arrived, for the
    /// turn's real timings. Nil means the value was never measured.
    @ObservationIgnored var streamStartedAt: Date?
    @ObservationIgnored var streamFirstTokenAt: Date?
    /// The phases of this turn, each captured only when it actually ran. A nil
    /// phase is written as absent, never as a zero.
    @ObservationIgnored var turnEntryAt: Date?
    @ObservationIgnored var turnPrepareStartedAt: Date?
    @ObservationIgnored var turnPrepareFinishedAt: Date?
    @ObservationIgnored var turnPersistStartedAt: Date?
    @ObservationIgnored var turnPersistFinishedAt: Date?
    @ObservationIgnored var turnEnrichStartedAt: Date?
    @ObservationIgnored var turnEnrichFinishedAt: Date?
    /// The tool rounds the in-flight turn has finished, and the token usage
    /// the provider reported. Both empty for a turn that used neither.
    @ObservationIgnored var streamToolRounds: [ToolRound] = []
    @ObservationIgnored var streamUsage: TokenUsage?
    /// Tokens of the accepted submits that have not reached their model
    /// request yet. One token per submit, removed only by that submit's own
    /// completion, command lane, model start or defer: an older submit
    /// finishing can never clear a newer submit's claim. A quit that freezes
    /// while the set is non-empty refuses instead of exiting over
    /// question-persistence or provider-start work it does not own.
    @ObservationIgnored var preStreamSubmitTokens: Set<UUID> = []
    /// Test seam, nil in the app: an accepted submit waits here immediately
    /// before its durable question write, so a test can hold the exact
    /// pre-stream window deterministically with no provider and no sleep.
    @ObservationIgnored var beforeDurableSubmitWrite: (@MainActor () async -> Void)?
    /// The store's copy of the open chat as this view last read or wrote
    /// it. The other view's writes since then are what a save merges in.
    @ObservationIgnored var openChatBase: StoredChatStamp?
    var modelRefreshMessage: String?
    var hotkeyRegistrationError: String?
    var clipboardHistoryHotkeyRegistrationError: String?
    var translatorHotkeyRegistrationError: String?
    var typeToClickHotkeyRegistrationError: String?
    var quickAIHotkeyRegistrationError: String?
    var launcherItemHotkeyRegistrationErrors: [String: String] = [:]
    /// The one ⌘K layer that can sit above the launcher. Exclusive by
    /// construction: a palette and a pane can never both be open.
    enum PresentedLayer: Equatable, Sendable {
        case actionPalette
        case applicationPane
        case catalogPane
    }
    var presentedLayer: PresentedLayer? {
        didSet { if presentedLayer == nil { resumeQueuedFollowUp() } }
    }
    var isActionPalettePresented: Bool {
        get { presentedLayer == .actionPalette }
        set { presentedLayer = newValue ? .actionPalette : (presentedLayer == .actionPalette ? nil : presentedLayer) }
    }
    var isApplicationActionPanePresented: Bool {
        get { presentedLayer == .applicationPane }
        set { presentedLayer = newValue ? .applicationPane : (presentedLayer == .applicationPane ? nil : presentedLayer) }
    }
    var isCatalogActionPanePresented: Bool {
        get { presentedLayer == .catalogPane }
        set { presentedLayer = newValue ? .catalogPane : (presentedLayer == .catalogPane ? nil : presentedLayer) }
    }
    var contextualApplicationID: String?
    var contextualCatalogItemID: String?
    /// Sub-form shown in the ⌘K pane instead of the action list.
    var activeItemActionForm: ItemActionForm?
    /// Item whose Delete action was pressed once; a second press deletes.
    var deleteArmedItemID: String?
    var catalogScope: LauncherCatalogScope?
    var pendingQuickLinkID: String?
    var actionQuery: String = ""
    var applicationSelectionIndex: Int = 0 {
        didSet { selectionShowsDetailPane = showsDetailPane }
    }
    /// `showsDetailPane` as of the last selection change. The panel watches
    /// this instead of the index, so it wakes when the pane opens or closes
    /// and not on every arrow press.
    private(set) var selectionShowsDetailPane = false
    var inputFocusRequest: Int = 0
    /// True briefly after auto-copy fires, so the UI can flash a "Copied!" indicator.
    var justCopied: Bool = false
    /// True briefly after a capture is saved to the Screenshots folder, so the
    /// launcher can confirm the save the way a copy is confirmed.
    var justSaved: Bool = false
    /// What the Quick AI composer confirms for a moment after Copy Answer
    /// or Copy Chat ("Copied"), drawn with a checkmark in place of the
    /// primary action. Nil the rest of the time.
    var composerConfirmation: String?
    /// Where the thread should scroll, and a revision so asking twice for
    /// the same place scrolls twice. Set by Show more and Collapse (the
    /// message's head to the top), by PageUp/PageDown and ⌥↑/⌥↓ (a page),
    /// by ⌘↑/⌘↓ (the ends), and by the "Latest" chip; the thread observes it.
    struct ThreadScrollRequest: Equatable, Sendable {
        enum Target: Equatable, Sendable {
            case messageTop(UUID)
            /// Find in Chat: the hit `y` points below the message's head,
            /// as the thread measured it, a third of the way down the view.
            case messageOffset(UUID, CGFloat)
            case pageUp
            case pageDown
            case top
            case bottom
        }
        let target: Target
        let revision: Int

        init(target: Target, revision: Int) {
            self.target = target
            self.revision = revision
        }

        /// Show more and Collapse: the message's head at the top.
        init(messageID: UUID, revision: Int) {
            self.init(target: .messageTop(messageID), revision: revision)
        }

        var messageID: UUID? {
            if case .messageTop(let id) = target { return id }
            return nil
        }
    }
    var threadScrollRequest: ThreadScrollRequest?
    /// Screenshots waiting to travel with the next question, oldest first.
    var pendingImages: [QuickImageAttachment] = []
    /// The newest attachment. Setting appends; setting nil clears all.
    var pendingImage: QuickImageAttachment? {
        get { pendingImages.last }
        set {
            if let newValue {
                if !pendingImages.contains(newValue) { pendingImages.append(newValue) }
            } else {
                pendingImages.removeAll()
            }
        }
    }
    /// Screen Awareness: what was read from the window behind the overlay.
    var pendingContext: CaptureContext?
    /// Auto-captured selected text from the app behind the overlay, captured
    /// at launch before the overlay took focus. Drives the removable chip.
    var launchSelection: LaunchSelection?
    var screenshotIndexProgress = ScreenshotTextIndex.Progress()
    /// What the user typed for the answer on screen, shown above it.
    var lastQuestion: String?
    /// The question of the ask in flight before it is a turn of the thread:
    /// set when the web search or page read starts (the user message joins
    /// the thread only once the model is called) and by a local answer,
    /// which never becomes a turn; cleared when the message is appended,
    /// when the ask is stopped, and with the thread. The surface draws it
    /// as its own pill so an answer never draws without its question.
    var pendingQuestion: String?
    var isCaffeinating: Bool = false
    /// A Caffeinate session is in force (manual, timed, or agents), even while
    /// the battery has paused the assertion. Distinct from `isCaffeinating`,
    /// which is only whether the sleep assertion is held right now. The row
    /// and its action follow this, so a paused session still reads
    /// "Decaffeinate" and can be cancelled.
    var hasCaffeinateSession: Bool = false
    /// Why the assertion is released while a session is live (a battery pause).
    var caffeinatePauseDetail: String?
    /// End of a timed Caffeinate session, for the command title.
    var caffeinateEndsAt: Date?
    var caffeinateReason: String?
    var caffeinateCountdownTask: Task<Void, Never>?
    /// Clock for anything time-derived in the launcher rows and the new-chat
    /// window; tests pin it.
    var now: () -> Date = Date.init
    /// Typing-capture modes beyond Quick Link input.
    var inputMode: InputMode?
    var launcherSelectionAnnouncement = ""
    var launcherSelectionAnnouncementRevision = 0

    enum InputMode: Equatable, Sendable {
        case caffeinateUntil
        case renameChat(UUID)
        /// A clipboard entry is asking for a new name; `itemID` identifies it.
        case renameClipboard(String)
        /// A snippet is asking for one `{argument}`; `pendingSnippetInsertion`
        /// holds which, and what to do once every slot is answered.
        case snippetArgument
        /// A house command is asking for its one `text` argument;
        /// `pendingHouseCommandText` holds which command is waiting.
        case houseCommandArgument
    }

    /// How an expanded snippet reaches the user: the same three moves every
    /// launcher row already offers.
    enum SnippetInsertMode: Equatable, Sendable {
        case paste
        case copy
        case copyAndPaste
    }

    /// A snippet waiting on its `{argument}` slots. Each Return fills the
    /// next one, in the order the template names them; the insertion runs
    /// when the last is answered.
    struct PendingSnippetInsertion: Equatable, Sendable {
        let item: LauncherCatalogItem
        let arguments: [SnippetArgument]
        var collected: [String]
        let mode: SnippetInsertMode
        /// The row's ⌘↩ closes the overlay once the text is out; ⌘C inside a
        /// catalog leaves it open. Either way the prompt runs first.
        var dismissesOverlay = false

        var currentArgument: SnippetArgument? {
            arguments.indices.contains(collected.count) ? arguments[collected.count] : nil
        }
    }

    var pendingSnippetInsertion: PendingSnippetInsertion?

    // MARK: - House commands

    /// What every other house app can do right now, read from the manifests
    /// in `~/Library/Application Support/House/commands`. Empty until
    /// `refreshHouseCommands()` has run, so nothing reads the disk on the
    /// keystroke path and no test depends on what is installed on this Mac.
    private(set) var houseCommandRows: [HouseCommandRow] = []

    /// The house commands as launcher rows: the effect as the title, the
    /// owning app as the detail.
    var houseCommandItems: [LauncherCatalogItem] { houseCommandRows.map(\.item) }

    /// A house command that needs one `text` argument, waiting for it.
    var pendingHouseCommandText: HouseCommandRow?

    /// A house command that needs one `choice`, with the options fetched
    /// when the user opened it. Return on one runs the command with that
    /// option's id.
    struct PendingHouseChoice: Equatable, Sendable {
        let row: HouseCommandRow
        let choices: [HouseCommandChoice]
    }

    var pendingHouseChoice: PendingHouseChoice?

    /// Polls an app that started slow work, so the launcher reports the end
    /// without ever waiting for it.
    @ObservationIgnored private var houseCommandWaitTask: Task<Void, Never>?

    @ObservationIgnored private var houseCommandRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var houseCommandRefreshPending = false
    @ObservationIgnored private var houseCommandRefreshForce = false

    /// Re-reads every manifest and the statuses that gate rows, off the main
    /// thread, and applies the result. Never throws and never blocks: an app
    /// that is missing, dead, or slow simply offers nothing this time round.
    ///
    /// A request made while a refresh is in flight is not dropped: it marks
    /// one more refresh pending, run after the current one, so the newest
    /// state wins and two refreshes never overlap.
    ///
    /// `force` skips the catalog's status cache. A follow-up always forces,
    /// and so does a refresh that follows a command run: both exist because
    /// the app's state just changed, so a status read moments ago is stale.
    func refreshHouseCommands(force: Bool = false) {
        guard let houseCommandCatalog else { return }
        if houseCommandRefreshTask != nil {
            houseCommandRefreshPending = true
            return
        }
        houseCommandRefreshForce = force
        houseCommandRefreshTask = Task { @MainActor [weak self] in
            repeat {
                let forced = self?.houseCommandRefreshForce ?? false
                self?.houseCommandRefreshPending = false
                self?.houseCommandRefreshForce = true  // any follow-up forces
                let rows = await houseCommandCatalog.refresh(force: forced)
                guard let self else { return }
                self.applyHouseCommands(rows)
            } while self?.houseCommandRefreshPending == true
            self?.houseCommandRefreshTask = nil
        }
    }

    /// Waits out a running refresh and its follow-up, for tests.
    func waitForHouseCommandRefreshForTesting() async {
        await houseCommandRefreshTask?.value
        houseCommandRefreshTask = nil
    }

    func applyHouseCommands(_ rows: [HouseCommandRow]) {
        guard rows.map(\.id) != houseCommandRows.map(\.id) || rows != houseCommandRows else { return }
        houseCommandRows = rows
        // A row that has just gone away must not stay on screen as a prompt.
        if let pendingHouseChoice, !rows.contains(where: { $0.id == pendingHouseChoice.row.id }) {
            self.pendingHouseChoice = nil
        }
        if let pendingHouseCommandText, !rows.contains(where: { $0.id == pendingHouseCommandText.id }) {
            self.pendingHouseCommandText = nil
            if inputMode == .houseCommandArgument { inputMode = nil }
        }
        invalidateLauncherRanking()
    }

    /// The choices of the command being asked about, as launcher rows,
    /// narrowed by what has been typed.
    var houseChoiceItems: [LauncherCatalogItem] {
        guard let pending = pendingHouseChoice else { return [] }
        let row = pending.row
        let items = pending.choices.enumerated().map { index, choice in
            // The option is carried by position, never by its own id: an id
            // is opaque and may hold any character, including the one that
            // separates it from the command.
            let value = HouseCommandCatalog.choiceValue(rowID: row.id, index: index)
            return LauncherCatalogItem(
                kind: .command,
                itemID: value,
                title: choice.title,
                detail: choice.detail ?? (row.manifest.name + " · " + row.command.title),
                value: value,
                keywords: choice.id + " " + row.command.title
            )
        }
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        let folded = FuzzyMatcher.fold(query)
        return items
            .compactMap { item -> (LauncherCatalogItem, Int)? in
                guard let score = FuzzyMatcher.score(
                    foldedQuery: folded,
                    foldedCandidate: FuzzyMatcher.fold(item.title)
                ) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Return on a house command row: run it, ask for its text, or show its
    /// choices.
    func performHouseCommand(_ item: LauncherCatalogItem) async {
        guard let houseCommandCatalog else { return }
        // A choice row names its option by position in the list the user is
        // looking at.
        if let picked = HouseCommandCatalog.choice(inValue: item.value) {
            guard let pending = pendingHouseChoice,
                  pending.row.id == picked.rowID,
                  pending.choices.indices.contains(picked.index)
            else {
                errorMessage = "That command is no longer available."
                requestInputFocus()
                return
            }
            let row = pending.row
            let choice = pending.choices[picked.index]
            pendingHouseChoice = nil
            await runHouseCommand(row, argument: choice.id)
            return
        }
        guard let row = await houseCommandCatalog.row(forValue: item.value) else {
            errorMessage = "That command is no longer available."
            requestInputFocus()
            return
        }
        switch row.command.needs {
        case .text:
            pendingHouseCommandText = row
            enterInputMode(.houseCommandArgument)
        case .choice:
            // The list is fetched now, not at launch: it changes under a
            // running app. A fetch that fails says so instead of opening a
            // picker with nothing in it.
            do {
                let choices = try await houseCommandCatalog.choices(for: row)
                pendingHouseChoice = PendingHouseChoice(row: row, choices: choices)
                inputMode = nil
                catalogScope = nil
                input = ""
                errorMessage = nil
                applicationSelectionIndex = 0
                invalidateLauncherRanking()
                requestInputFocus()
                noteInteraction()
            } catch {
                errorMessage = error.localizedDescription
                requestInputFocus()
            }
        case nil:
            await runHouseCommand(row, argument: nil)
        }
    }

    /// Runs one house command and reports the outcome where every other
    /// launcher failure is reported. A command that fails says so.
    func runHouseCommand(_ row: HouseCommandRow, argument: String?) async {
        guard let houseCommandCatalog else { return }
        errorMessage = nil
        do {
            let outcome = try await houseCommandCatalog.run(row, argument: argument)
            noteFeatureUse(.houseCommandRun, itemID: "command:\(row.id)")
            input = ""
            switch outcome {
            case .completed(let reply):
                // The app's own words when it sent any, so a command that
                // answers something useful is not swallowed.
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty || text.lowercased() == "ok" {
                    overlayPresenter.dismissOverlay()
                } else {
                    answerSource = .command(row.command.title)
                    output = text
                    lastQuestion = row.command.title
                    requestInputFocus()
                }
            case .started:
                // The work is running. The launcher says so at once and
                // watches for the end; it never waits for it.
                answerSource = .command(row.command.title)
                lastQuestion = row.command.title
                output = "Started. \(row.manifest.name) is working."
                requestInputFocus()
                watchHouseCommand(row)
            }
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
        }
        // What the app is doing has changed, so the rows must catch up.
        refreshHouseCommands(force: true)
    }

    /// Follows work that started, off the launcher's path, and reports how
    /// it ended. A poll that never settles is a reported failure, not a
    /// hang: the launcher stays usable throughout either way.
    private func watchHouseCommand(_ row: HouseCommandRow) {
        guard let houseCommandCatalog else { return }
        houseCommandWaitTask?.cancel()
        houseCommandWaitTask = Task { @MainActor [weak self] in
            let status = await houseCommandCatalog.waitWhileBusy(row)
            guard let self, !Task.isCancelled else { return }
            // The user has moved on: their screen is not ours to take back.
            guard self.lastQuestion == row.command.title else { return }
            if let status {
                if status.ok {
                    self.output = status.detail ?? "Finished."
                } else {
                    self.errorMessage = status.detail ?? "\(row.manifest.name) could not finish."
                }
            } else {
                self.errorMessage = "\(row.manifest.name) did not finish in time."
            }
            self.houseCommandWaitTask = nil
            self.refreshHouseCommands(force: true)
        }
    }

    /// Waits out a running watch, for tests.
    func waitForHouseCommandWatchForTesting() async {
        await houseCommandWaitTask?.value
        houseCommandWaitTask = nil
    }

    /// A snippet or Quicklink being written in the ⌘K editor before it
    /// exists anywhere. It lives only while that form is open; Save writes
    /// it to the store and the real item takes its place.
    var draftCatalogItem: LauncherCatalogItem?

    static let draftSnippetID = "draft.snippet"
    static let draftQuickLinkID = "draft.quicklink"

    /// True for the blank item the Create commands put in the editor.
    func isDraftItem(_ item: LauncherCatalogItem) -> Bool {
        item.itemID == Self.draftSnippetID || item.itemID == Self.draftQuickLinkID
    }

    /// A snapshot of selected text captured from the background app when the
    /// overlay opened, before the overlay stole focus. Immutable for the
    /// session; shown as a removable chip and attached to exactly one request
    /// so it never leaks into later follow-ups or a new conversation.
    struct LaunchSelection: Equatable, Sendable {
        let text: String
        let appName: String
    }

    // MARK: - Dependencies

    /// Reads the house manifests and talks to the other apps. Nil in every
    /// test that does not ask for house commands, so no test touches the
    /// real manifest folder or a live app.
    @ObservationIgnored let houseCommandCatalog: HouseCommandCatalog?

    /// Test seam. When set, every provider resolves to this service.
    /// Production leaves it nil and builds a client per provider.
    var service: (any QuickService)?
    /// The context skills the open assistant chat has loaded, so each chat
    /// reads its skill files once (`assistantSystemMessage(for:)`).
    @ObservationIgnored var assistantSkillCache: AssistantSkillCache?
    var selectedTextService: (any SelectedTextServicing)?
    var applicationCatalog: (any ApplicationCatalogServicing)?
    var launcherCatalog: (any LauncherCatalogServicing)?
    var clipboardHistory: (any ClipboardHistoryServicing)?
    var webSearchService: (any WebSearchServicing)?
    /// Memory and task reads through `recall`. Nil in tests that do not fake it.
    var memoryService: (any MemoryRecalling)?
    /// Capture to Memory (`recall capture`), a user action only.
    var memoryCapture: (any MemoryCapturing)?
    /// `read_skill`, over the canonical skills folder.
    var skillLibrary: SkillLibrary?
    /// Open Source: `/usr/bin/open` on a source's local path.
    var fileOpener: (any LocalFileOpening)?
    /// The folders Open Source may open from (the memory repo, the skills repo
    /// and the Work folder); tests point it at a temporary folder.
    @ObservationIgnored var sourceRoots: [URL] = ChatSource.defaultRoots
    /// Continue in pi. The app sets `PiHandoffService`; nil (every test
    /// that does not set one) leaves the action out of `⌘K`, so no test
    /// can start tmux or open Ghostty.
    @ObservationIgnored var piHandoff: (any PiHandoffServicing)?
    /// Settings › General › Chat's status lines. The app sets
    /// `ChatBackendProbe`; nil (every test that does not set one) runs no
    /// lookups and the card leaves the lines out.
    @ObservationIgnored var chatBackendProbe: (any ChatBackendProbing)?
    /// The probe's last answer; nil until it answers.
    var chatBackendStatus: ChatBackendStatus?
    /// Opens the AI Chat window: on a hand-off from Quick AI (`⌘J`), or on
    /// a new or the last chat (nil, the root "AI Chat" command). The app
    /// sets it; nil (every test that does not set one) leaves both out.
    @ObservationIgnored var aiChatOpener: ((AIChatHandoff?) -> Void)?
    /// The AI Chat window, when this is that window's own view model. Nil
    /// for the launcher. Set, the launcher-only answer actions leave `⌘K`,
    /// the window's own actions join it, and Rename Chat goes to the
    /// window's chat list. The window model lives in `AIChatWindowModel`,
    /// not here.
    @ObservationIgnored weak var chatWindowHost: (any AIChatWindowHosting)?
    var isAIChatWindow: Bool { chatWindowHost != nil }
    /// Set once the AI Chat window has opened. Its first open lands on the
    /// most recent chat; after that it keeps what it holds.
    @ObservationIgnored var hasOpenedAIChatWindow = false
    /// VoiceOver announcements the view model makes itself ("Answer ready"
    /// in AI Chat). Tests record them instead.
    @ObservationIgnored var announce: (String) -> Void = { QuickAIAnnouncement.post($0, priority: .medium) }
    /// Reads pages whose URLs appear in the prompt, so answers can use the
    /// live content instead of the model's stale training data.
    var pageReader: (any WebPageReading)?
    var windowManager: (any WindowManaging)?
    /// Lays out Quick Launch's own AI Chat window, which `windowManager`
    /// cannot reach. Nil until that window has been built.
    @ObservationIgnored var ownWindowLayout: (any OwnWindowLaying)?
    var caffeinateManager: (any CaffeinateManaging)?
    var screenshotService: (any ScreenshotCapturing)?
    var screenAwareness: (any ScreenAwarenessReading)?
    /// AppKit seams (pasteboard, Finder/URL opening, running apps, displays).
    /// The app keeps the system defaults; tests inject fakes. The seams that
    /// change the system are the exceptions: with none injected they are
    /// inert (`InMemoryPasteboard`, `InMemoryWorkspace`,
    /// `NoRunningApplications`), and the app passes the system ones, so a test
    /// never replaces the user's clipboard, opens a real browser tab or Finder
    /// window, or quits a real app.
    @ObservationIgnored var pasteboard: any PasteboardWriting
    @ObservationIgnored var workspace: any WorkspaceOpening
    @ObservationIgnored var runningApplications: any RunningApplicationsQuerying
    @ObservationIgnored var screenGeometry: any ScreenGeometryProviding
    /// On-device OCR over the screenshots folder. Defaults to in-memory;
    /// the app injects one backed by a file.
    @ObservationIgnored var screenshotTextIndex: ScreenshotTextIndex
    /// Learned ranking. Defaults to an in-memory store; the app injects a
    /// persistent one.
    @ObservationIgnored var launcherUsage: LauncherUsageStore
    /// Local, bounded review log of launcher and AI *outcomes*. Read-only
    /// evidence for the user: it never feeds `launcherUsage` or ranking.
    @ObservationIgnored var interactionJournal: InteractionJournalStore
    /// Shows/hides the panel. AppDelegate installs the real one; the default
    /// posts the legacy notifications so tests and previews keep working.
    ///
    /// Held weakly: the AI Chat window's controller installs itself here, and a
    /// strong reference would close controller -> model -> chat -> controller.
    /// The weak reference breaks that cycle, but it does not by itself make the
    /// controller's `isolated deinit` reachable: `AppDelegate` holds the
    /// controller strongly for the app's life and never clears it, so the deinit
    /// runs only if that strong reference is released. The fallback keeps the
    /// stored, non-optional call syntax (`overlayPresenter.dismissOverlay()`).
    @ObservationIgnored private weak var overlayPresenterTarget: (any OverlayPresenting)?
    @ObservationIgnored private let fallbackOverlayPresenter = NotificationOverlayPresenter()
    @ObservationIgnored private let releasedOverlayPresenter = ReleasedOverlayPresenter()
    @ObservationIgnored private var didAssignOverlayPresenter = false
    var overlayPresenter: any OverlayPresenting {
        get {
            if let target = overlayPresenterTarget { return target }
            // A presenter assigned and since released (a short-lived test
            // double) is not swapped for the notifying default: nothing
            // asked for those notifications. Before any assignment, the
            // default keeps observers and previews working.
            return didAssignOverlayPresenter ? releasedOverlayPresenter : fallbackOverlayPresenter
        }
        set {
            overlayPresenterTarget = newValue
            didAssignOverlayPresenter = true
        }
    }
    @ObservationIgnored var prepareForExternalAction: (() -> Void)?
    @ObservationIgnored var recoverFromExternalActionFailure: (() -> Void)?
    @ObservationIgnored var persistSettings: (QuickSettings) -> Void = { $0.save() }
    /// Keychain lookup, replaceable in tests so they never touch the real Keychain.
    /// Defaults to no key; the app injects `QuickViewModel.keychainAPIKey`.
    /// A locked login keychain prompts and hangs `swift test`, so nothing but
    /// the app's own launch path reaches the real Keychain.
    @ObservationIgnored var apiKeyProvider: (UUID) -> String?
    /// The production lookup, passed in by `AppDelegate`.
    static let keychainAPIKey: (UUID) -> String? = { APIKeyStore.load(providerID: $0) }
    /// Whether a provider has a key, remembered for this session. The route
    /// resolver runs several times per body pass (`chatDestinationLabel`,
    /// `attachmentRoutingLine`, the pre-send controls), and each check read
    /// the Keychain: a heavy body re-evaluated three times a second produced
    /// hundreds of `SecItemCopyMatching` calls a second and most of the CPU
    /// the app burned. Cleared whenever a key or a provider setting changes.
    @ObservationIgnored private var apiKeyPresence: [UUID: Bool] = [:]

    // How long the "just copied" flag stays true after auto-copy.
    @ObservationIgnored var justCopiedTimeout: Duration = .seconds(2)
    /// How long the composer's checkmark stays after a copy on Quick AI.
    @ObservationIgnored var composerConfirmationDuration: Duration = .milliseconds(1500)
    @ObservationIgnored private var composerConfirmationTask: Task<Void, Never>?
    @ObservationIgnored var webAnswerTimeout: Duration = .seconds(15)
    @ObservationIgnored var catalogIdleResetDelay: Duration = .seconds(15)
    @ObservationIgnored private var justCopiedTask: Task<Void, Never>?
    @ObservationIgnored private var justSavedTask: Task<Void, Never>?
    /// A source being opened from the thread or the palette; a second click
    /// replaces it.
    @ObservationIgnored var sourceOpenTask: Task<Void, Never>?
    @ObservationIgnored private var catalogIdleResetTask: Task<Void, Never>?

    // MARK: - Private

    @ObservationIgnored var streamTask: Task<Void, Never>?
    /// Bumped by every model request and by `cancel()` and a thread reset.
    /// A stream task writes state only while its generation is current, so
    /// a stopped stream that ends late (by a `CancellationError`, or by a
    /// service that finishes its continuation instead) never touches the
    /// next ask, and its outcome is never recorded twice. Never persisted.
    @ObservationIgnored var streamGeneration = 0
    /// The chat and the user turn of the model request in flight, so Stop
    /// can give that turn the text that arrived.
    @ObservationIgnored var inFlightTurn: (conversationID: UUID, messageID: UUID)?
    /// Return while a stream runs (a pick in a chooser, or a queued
    /// follow-up). The submit that started the stream is still in flight,
    /// so this one never waits on it.
    @ObservationIgnored var streamingReturnTask: Task<Void, Never>?
    /// The Retry control under a failed turn, kept so a test can await it.
    @ObservationIgnored var retryTask: Task<Void, Never>?
    /// Rename Chat started from Recent Chats returns there, not to the
    /// Chats catalog.
    @ObservationIgnored private var renameReturnsToRecentChats = false
    /// The folded query the user actually submitted or acted on in this overlay
    /// session, set where the submission happens — not inferred from whatever
    /// `input` happens to hold when the outcome is recorded. That is what stops
    /// a failed or cancelled request from also being logged as an abandoned
    /// search, since those paths restore the typed text into `input`.
    /// In memory only.
    @ObservationIgnored var journalActedQuery: String?
    /// The command-action process for the request on screen, so Escape can
    /// really terminate it instead of only hiding its output.
    /// Internal rather than private: the launcher tests arm a pending task
    /// here to prove that clearing or replacing the thread cancels the
    /// command lane. Nothing outside this file reads it in production.
    @ObservationIgnored var commandTask: Task<String, Error>?
    /// Tokens arrive faster than the overlay can re-render a long answer, so
    /// deltas collect here and `output` is published at most every 33 ms.
    @ObservationIgnored var streamBuffer = ""
    @ObservationIgnored private var streamFlushTask: Task<Void, Never>?
    @ObservationIgnored private var lastStreamFlush = ContinuousClock.now
    static let streamFlushInterval: Duration = .milliseconds(33)
    @ObservationIgnored let currentVersion: String
    @ObservationIgnored private(set) var selectionTarget: SelectionTarget?
    @ObservationIgnored var selectedTextContext: SelectedTextContext?
    /// The captured selection a preview-first rewrite action produced for the
    /// answer now on screen, so the Replace Selection result action is offered
    /// only for an answer that actually rewrote a captured selection — never
    /// for a later follow-up or an unrelated ad-hoc answer. Cleared when a new
    /// request begins.
    @ObservationIgnored var replaceableSelectionContext: SelectedTextContext?
    /// Text an action dispatch (picker/hotkey) resolved explicitly, so a
    /// multi-line selection is never whitespace-collapsed by alias context.
    @ObservationIgnored var pendingActionSource: String?
    /// The label of the source in `pendingActionSource` ("Clipboard", or an
    /// app name), consumed once for the review card's attribution.
    @ObservationIgnored var pendingActionSourceLabel: String?
    /// The text of a source the user chose explicitly (a clipboard item),
    /// which a transform must act on ahead of the auto-captured launch
    /// snapshot. Cleared with the launch scope it belongs to.
    @ObservationIgnored var explicitTransformSource: String?
    /// The label of `explicitTransformSource`, so the review card says
    /// "Clipboard" rather than borrowing the live selection's app name.
    @ObservationIgnored var explicitTransformSourceLabel: String?
    /// True after the user removes a launch selection: suppresses the
    /// automatic re-capture of `{selection}` for a saved action until a fresh
    /// launch or an explicit attachment, so a dismissed chip is not silently
    /// re-read.
    @ObservationIgnored var selectionRecaptureSuppressed = false
    // MARK: - Attachments (QuickViewModel+Attachments.swift)

    /// The chips waiting to ride the next question: files, links, pictures,
    /// and selections, one tray per view. Every way to attach lands here.
    let attachmentTray: AttachmentTray
    /// Whether `providerID` has an API key, from the cache after the first
    /// read. The Keychain itself is the source; this only stops one body pass
    /// from reading it repeatedly.
    func hasAPIKey(_ providerID: UUID) -> Bool {
        if let cached = apiKeyPresence[providerID] { return cached }
        let has = !(apiKeyProvider(providerID) ?? "").isEmpty
        apiKeyPresence[providerID] = has
        return has
    }

    /// A key or a provider was added, removed, or edited: the next check
    /// reads the Keychain again.
    func invalidateAPIKeyPresence() {
        apiKeyPresence.removeAll()
    }

    /// Reads a source for Re-attach; the tray reads through the same one.
    @ObservationIgnored let attachmentReader: any AttachmentExtracting
    /// File…'s open panel. The app sets the system one; nil in tests unless
    /// a test passes a fake.
    @ObservationIgnored var attachmentFilePicker: (any AttachmentFilePicking)?
    /// Reads the text of a picture on this Mac, for the OCR fallback when no
    /// vision model can take it.
    @ObservationIgnored var recognizeImageText: @Sendable (Data) async -> String = { data in
        await ScreenshotTextIndex.recognizeText(in: data)
    }
    /// Sent chips being read again (Re-attach), or whose read failed.
    var reattachStates: [UUID: AttachmentChipModel.Phase] = [:]
    @ObservationIgnored var reattachTasks: [UUID: Task<Void, Never>] = [:]
    /// One writer per chat for archive-only metadata (pin, rename): two rapid
    /// actions would otherwise reach the actor in whatever order their Tasks
    /// were scheduled.
    @ObservationIgnored private var archiveWriteChain: [UUID: Task<Void, Never>] = [:]
    /// True while a send waits for chips still reading.
    var isWaitingForAttachments = false
    /// An Add Context row's work (File…, a capture), kept so a test can
    /// await it.
    @ObservationIgnored var addContextTask: Task<Void, Never>?
    /// `⌘R`: the turn asked again keeps the attachments it had.
    @ObservationIgnored var reaskedAttachments: [ChatAttachmentRef]?

    /// The question a web search or page read took out of the composer, held
    /// until the model call makes it a turn.
    var enrichmentSubmittedInput: String?

    /// The send a closed layer started for a held follow-up, kept so a test
    /// can await it and `cancel()` can stop it.
    @ObservationIgnored var queuedFollowUpTask: Task<Void, Never>?

    /// Bumped whenever the journal changes, so the Settings review list can
    /// re-render; the store itself is `@ObservationIgnored`.
    var interactionJournalRevision: Int = 0

    /// The active filter over the clipboard catalog. Empty means every entry.
    /// Set through `setClipboardCatalogFilter(_:)` so ranking and selection
    /// follow every change.
    var clipboardCatalogFilter = ClipboardCatalogFilter()

    /// The folded text of every chat, for the chat lists' search
    /// (`QuickViewModel+ChatSearch.swift`).
    @ObservationIgnored let chatSearchIndex = ChatSearchIndex()

    /// Files are listed when the catalog is entered, so typing never hits the disk.
    var screenshotFiles: [LauncherCatalogItem] = []

    /// Memoized skin-toned emoji, rebuilt only when the tone changes.
    @ObservationIgnored var emojiTonedItems: (tone: Int, items: [LauncherCatalogItem])?

    // MARK: - Init

    init(
        settings: QuickSettings = QuickSettings(),
        store: QuickStore? = nil,
        service: (any QuickService)? = nil,
        selectedTextService: (any SelectedTextServicing)? = nil,
        applicationCatalog: (any ApplicationCatalogServicing)? = nil,
        launcherCatalog: (any LauncherCatalogServicing)? = nil,
        clipboardHistory: (any ClipboardHistoryServicing)? = nil,
        webSearchService: (any WebSearchServicing)? = nil,
        pageReader: (any WebPageReading)? = nil,
        windowManager: (any WindowManaging)? = nil,
        caffeinateManager: (any CaffeinateManaging)? = nil,
        launcherUsage: LauncherUsageStore? = nil,
        interactionJournal: InteractionJournalStore? = nil,
        screenshotService: (any ScreenshotCapturing)? = nil,
        screenAwareness: (any ScreenAwarenessReading)? = nil,
        screenshotTextIndex: ScreenshotTextIndex? = nil,
        pasteboard: (any PasteboardWriting)? = nil,
        historyFileURL: URL? = nil,
        archiveRootURL: URL? = nil,
        workspace: (any WorkspaceOpening)? = nil,
        runningApplications: (any RunningApplicationsQuerying)? = nil,
        screenGeometry: (any ScreenGeometryProviding)? = nil,
        attachmentExtractor: (any AttachmentExtracting)? = nil,
        houseCommandCatalog: HouseCommandCatalog? = nil,
        apiKeyProvider: ((UUID) -> String?)? = nil,
        currentVersion: String = "1.0.0"
    ) {
        self.apiKeyProvider = apiKeyProvider ?? { _ in nil }
        // The non-injected path matches production: the shared reader, so a
        // document is extracted by HouseChatDocuments and not the app-side
        // OOXML copy that has drifted from the package's.
        let reader = attachmentExtractor ?? SharedDocumentExtractor()
        self.attachmentReader = reader
        self.attachmentTray = AttachmentTray(extractor: reader)
        // A shared store (the AI Chat window's view model) brings its own
        // settings; `settings` seeds a new one.
        self.store = store ?? QuickStore(settings: settings)
        let settings = self.store.settings
        self.service = service
        self.selectedTextService = selectedTextService
        self.applicationCatalog = applicationCatalog
        self.launcherCatalog = launcherCatalog
        self.clipboardHistory = clipboardHistory
        self.webSearchService = webSearchService
        self.pageReader = pageReader
        self.windowManager = windowManager
        self.caffeinateManager = caffeinateManager
        self.launcherUsage = launcherUsage ?? LauncherUsageStore(fileURL: nil)
        self.interactionJournal = interactionJournal ?? InteractionJournalStore(fileURL: nil)
        self.interactionJournal.retentionDays = settings.interactionJournalRetentionDays
        self.interactionJournal.eventCap = settings.interactionJournalEventCap
        self.interactionJournal.prune()
        self.screenshotService = screenshotService
        self.screenAwareness = screenAwareness
        self.screenshotTextIndex = screenshotTextIndex ?? ScreenshotTextIndex(storeURL: nil)
        self.pasteboard = pasteboard ?? InMemoryPasteboard()
        self.historyFileURL = historyFileURL
        self.chatArchive = archiveRootURL.flatMap { try? ChatArchive.shared(root: $0) }
        if let chatArchive {
            self.durability = AnswerDurability(
                writer: ChatArchiveAnswerWriter(archive: chatArchive)
            )
        }
        self.workspace = workspace ?? InMemoryWorkspace()
        self.runningApplications = runningApplications ?? NoRunningApplications()
        self.screenGeometry = screenGeometry ?? SystemScreenGeometry()
        self.houseCommandCatalog = houseCommandCatalog
        self.currentVersion = currentVersion
        self.screenshotTextIndex.onProgress = { [weak self] progress in
            self?.screenshotIndexProgress = progress
            // Newly recognized text changes what queries match; drop cached
            // rankings so text hits appear without waiting for a keystroke.
            self?.invalidateLauncherRanking()
        }
        self.store.register(self)
        durability?.onFailure = { [weak self] failure in
            guard let self else { return }
            switch failure.kind {
            case .terminal:
                AppLog.persistence.error("Chat archive answer write failed: \(failure.message)")
            case .projection:
                AppLog.persistence.error("Chat archive answer sync failed: \(failure.message)")
            case .deletion:
                AppLog.persistence.error("Chat archive delete failed: \(failure.message)")
                self.errorMessage = "Could not delete this chat from the archive: \(failure.message)"
            }
        }
        attachmentTray.onChooseFiles = { [weak self] in
            self?.runAddContextRow(.file)
        }
        attachmentTray.onReadFinderSelection = { [weak self] in
            self?.attachFinderSelection()
        }
    }

    // MARK: - Quick AI size

    /// The Quick AI surface's size: the one the user dragged it to, never
    /// below the standard 750 × 475. The AppDelegate clamps it to the
    /// display (`PanelSizing.quickAIPlacedSize`) before it compares or
    /// applies the frame; the stored value keeps the user's choice for a
    /// larger display.
    var quickAISize: CGSize { settings.quickAISize.atLeastStandard.cgSize }

    /// True while Quick AI is up at a size the user dragged: a programmatic
    /// resize then keeps the window's centre where the drag left it. Root
    /// search, and Quick AI back at 750 × 475 (Reset), centre on the
    /// launcher's anchor, so a one-edge drag never moves the search field.
    var keepsUserSizedFrame: Bool {
        isQuickAIPresented && !settings.quickAISize.isStandard
    }

    /// Remembers the size the user dragged the panel to, once the drag
    /// ends. Only while the Quick AI surface is up: root search is never
    /// user-sized. Returns true when a new size was stored.
    @discardableResult
    func rememberQuickAISize(_ size: CGSize) -> Bool {
        guard isQuickAIPresented else { return false }
        let remembered = QuickAISize(size).atLeastStandard
        let current = settings.quickAISize.atLeastStandard
        guard abs(remembered.width - current.width) >= 1
            || abs(remembered.height - current.height) >= 1
        else { return false }
        updateSettings { $0.quickAISize = remembered }
        return true
    }

    /// ⌘K › Reset Quick AI Size: back to 750 × 475. The window follows on
    /// the next resize pass.
    func resetQuickAISize() {
        guard !settings.quickAISize.isStandard else { return }
        updateSettings { $0.quickAISize = .standard }
    }

    struct GridSection: Equatable {
        let title: String
        let range: Range<Int>
    }

    /// Section headers over `launcherMatches` in the emoji grid.
    var gridSections: [GridSection] {
        guard isGridCatalog, catalogScope == .emoji else { return [] }
        let count = launcherMatches.count
        guard count > 0 else { return [] }
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty, emojiFavouriteCount > 0 {
            let favourites = min(emojiFavouriteCount, count)
            var sections = [GridSection(title: "Frequently Used", range: 0..<favourites)]
            if favourites < count { sections.append(GridSection(title: "All", range: favourites..<count)) }
            return sections
        }
        return [GridSection(title: query.isEmpty ? "All" : "Results", range: 0..<count)]
    }

    private var emojiFavouriteCount: Int {
        guard settings.launcherLearningEnabled else { return 0 }
        return min(18, launcherUsage.topItemIDs(scope: LauncherCatalogScope.emoji.rawValue, limit: 18).count)
    }

    static func maxRows(for scope: LauncherCatalogScope?) -> Int {
        scope == .emoji ? maxGridCells : maxLauncherRows
    }

    func screenshotText(for item: LauncherCatalogItem) -> String? {
        screenshotTextIndex.text(for: item)
    }
    /// Learned favourites shown above the catalog roots when nothing is typed.
    static let emptyQueryFavouriteRows = 2

    var catalogMatches: [LauncherCatalogItem] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // The Chats catalog is Recent Chats' list: the same order (pinned,
        // then newest), the same search (title and message text), every
        // chat. Learned favourites never reorder it. `chatItems` already
        // drops hidden chats.
        if catalogScope == .chats { return chatItems(matching: query) }
        // Hidden rows leave before ranking, so row caps, learned favourites,
        // and pins all see the same visible set.
        let items = visibleLauncherItems(catalogItems)
        let scope = catalogScope?.rawValue ?? LauncherUsageStore.rootScope
        let rows = effectiveRowLimit
        // Clipboard grammar (`source:`/`tag:`/`kind:`/`pin:`) narrows the list
        // and is stripped from the free-text needle, so the visible hint and
        // the results agree. The segmented control's filter still applies
        // underneath through `catalogItems`.
        if catalogScope == .clipboard, !query.isEmpty {
            let parsed = ClipboardFilterQuery.parse(query)
            var filter = clipboardCatalogFilter
            if let source = parsed.source { filter.sourceName = source }
            if let tag = parsed.tag { filter.tag = tag }
            if !parsed.kinds.isEmpty { filter.kinds = parsed.kinds }
            if parsed.pinnedOnly { filter.pinnedOnly = true }
            let narrowed = items.filter(filter.matches)
            guard !parsed.needle.isEmpty else { return Array(narrowed.prefix(rows)) }
            let foldedNeedle = FuzzyMatcher.fold(parsed.needle)
            return Array(narrowed.compactMap { item -> (LauncherCatalogItem, Int)? in
                guard let score = matchScore(
                    foldedQuery: foldedNeedle,
                    title: item.title,
                    alias: launcherItemAlias(for: item),
                    keywords: item.keywords
                ) else { return nil }
                return (item, score)
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1
                    ? lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
                    : lhs.1 > rhs.1
            }
            .prefix(rows)
            .map(\.0))
        }
        guard !query.isEmpty else {
            // Time-ordered catalogs stay chronological: the clipboard store
            // and the screenshots list already put pins first, and learned
            // favourites must never shuffle a dated list.
            guard catalogScope != .clipboard, catalogScope != .screenshots,
                  settings.launcherLearningEnabled else {
                return Array(items.prefix(rows))
            }
            let favouriteLimit = catalogScope == .emoji ? 18 : rows
            let favourites = launcherUsage.topItemIDs(scope: scope, limit: favouriteLimit)
            let pinned = items.filter(\.isPinned)
            let ordered = pinned + favourites.compactMap { id in items.first { $0.id == id && !$0.isPinned } }
            let rest = items.filter { item in !ordered.contains { $0.id == item.id } }
            return Array((ordered + rest).prefix(rows))
        }
        let signals = learnedSignals(query: query, scope: scope)
        if catalogScope == .screenshots {
            let parsed = ScreenshotQuery.parse(query)
            let windowed = items.filter { item in
                guard let interval = parsed.interval else { return true }
                guard let capturedAt = item.capturedAt else { return parsed.needle.isEmpty ? false : true }
                return interval.contains(capturedAt)
            }
            guard !parsed.needle.isEmpty else { return Array(windowed.prefix(rows)) }
            let variants = Self.searchVariants(for: parsed.needle)
            // One normalized form per variant for OCR containment.
            let literals = variants.map(ScreenshotTextIndex.normalize)
            return Array(windowed.compactMap { item -> (LauncherCatalogItem, Int)? in
                var best: Int?
                var titleHit = false
                for (index, variant) in variants.enumerated() {
                    if let score = matchScore(foldedQuery: variant, title: item.title, alias: launcherItemAlias(for: item), keywords: item.keywords) {
                        best = max(best ?? 0, score + 1_000)
                        titleHit = true
                    }
                    // Text inside the image: literal, whitespace-flattened,
                    // all words present, tried per plural variant.
                    if item.kind == .screenshot, settings.screenshotTextSearch,
                       let text = screenshotTextIndex.normalizedText(for: item) {
                        let literal = literals[index]
                        let words = literal.split(separator: " ").map(String.init)
                        if !literal.isEmpty,
                           text.contains(literal) || (words.count > 1 && words.allSatisfy { text.contains($0) }) {
                            best = max(best ?? 0, 500)
                        }
                    }
                }
                guard let score = best else { return nil }
                var matched = item
                if !titleHit, !(matched.title.lowercased().contains(literals[0])), matched.kind == .screenshot {
                    matched.detail = "Text match · " + matched.detail
                }
                return (matched, score + LauncherRanker.boost(for: signals[item.id]) + pinBoost(item))
            }
            .sorted { $0.1 == $1.1 ? ($0.0.capturedAt ?? .distantPast) > ($1.0.capturedAt ?? .distantPast) : $0.1 > $1.1 }
            .prefix(rows)
            .map(\.0))
        }
        let foldedQuery = FuzzyMatcher.fold(query)
        return Array(items.compactMap { item -> (LauncherCatalogItem, Int)? in
            guard let score = matchScore(
                foldedQuery: foldedQuery,
                title: item.title,
                alias: launcherItemAlias(for: item),
                keywords: item.keywords
            ) else { return nil }
            return (item, score + LauncherRanker.boost(for: signals[item.id]) + pinBoost(item))
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1
                ? lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
                : lhs.1 > rhs.1
        }
        .prefix(rows)
        .map(\.0))
    }

    /// Everything the root launcher can reach in one keystroke, ranked in one
    /// list: apps, commands, catalog roots, snippets, and quick links. Learned
    /// choices outrank fuzzy text matches.
    ///
    /// The view, the footer, and the panel sizer all read this several times
    /// per keystroke, so one ranking pass is cached until any input changes.
    var launcherMatches: [LauncherSearchResult] {
        let key = launcherMatchesCacheKey
        if let cached = launcherMatchesCache, cached.key == key { return cached.value }
        let value = rankLauncherMatches()
        launcherMatchesCache = (key, value)
        return value
    }

    @ObservationIgnored private var launcherMatchesCache: (key: String, value: [LauncherSearchResult])?
    /// Bumped whenever learned ranking changes, so the cache cannot go stale.
    @ObservationIgnored var launcherRankingVersion = 0

    private var launcherMatchesCacheKey: String {
        var parts: [String] = []
        parts.append(input)
        parts.append(catalogScope?.rawValue ?? "")
        parts.append(pendingQuickLinkID ?? "")
        parts.append(hasPendingAttachment ? "1" : "0")
        parts.append(isAnswerActive ? "1" : "0")
        parts.append(rootAnswer == nil ? "" : "local")
        parts.append(inlineTranslation.map { "\($0.status)\u{0}\($0.text)" } ?? "")
        parts.append(inputMode == nil ? "" : "mode")
        parts.append(pendingHouseChoice?.row.id ?? "")
        parts.append(houseCommandRows.map(\.id).joined(separator: ","))
        parts.append(String(snippets.count))
        parts.append(String(quickLinks.count))
        parts.append(String(clipboardHistory?.revision ?? 0))
        parts.append(String(history.count))
        let pinnedChats = history.filter { $0.isPinned }.count
        parts.append(String(pinnedChats))
        // The Chats catalog follows every chat's time and name, which the
        // other view can change without changing the count.
        if catalogScope == .chats {
            parts.append(history.map { "\($0.id)\($0.updatedAt.timeIntervalSinceReferenceDate)\($0.customTitle ?? "")" }.joined())
        }
        parts.append(isCaffeinating ? "1" : "0")
        // The status row shows minutes left, so the cache turns over with them.
        parts.append(caffeinateEndsAt.map { String(Int($0.timeIntervalSince(now()) / 60)) } ?? "-")
        parts.append(caffeinateReason ?? "")
        parts.append(settings.launcherLearningEnabled ? "1" : "0")
        parts.append(settings.savedPromptPrefix)
        parts.append(String(settings.launcherItemConfigurations.hashValue))
        parts.append(String(launcherRankingVersion))
        parts.append(String(applicationCatalog?.version ?? 0))
        parts.append(activeModelDisplay)
        // The Ask AI row carries the Tab hint and, when the first Fallback
        // Command is not Ask AI, that command's name: both change the row.
        parts.append(settings.tabShortcutHintVisible ? "hint" : "nohint")
        parts.append(settings.fallbackCommandIDs.joined(separator: ","))
        return parts.joined(separator: "\u{1F}")
    }

    /// The Quick AI surface owns the panel: no launcher rows, typing asks
    /// the model. A thread kept behind root search is not active.
    var isAnswerActive: Bool { isQuickAIPresented }

    private func rankLauncherMatches() -> [LauncherSearchResult] {
        // A local answer under the input row stands in for the rows until
        // the next keystroke, as v1.3.0's answer block did.
        if pendingHouseChoice != nil, !hasPendingAttachment, !isAnswerActive, inputMode == nil {
            return houseChoiceItems.map(LauncherSearchResult.item)
        }
        guard !hasPendingAttachment, !isAnswerActive, inputMode == nil, rootAnswer == nil else { return [] }
        if catalogScope != nil {
            return catalogMatches.map(LauncherSearchResult.item)
        }
        guard pendingQuickLinkID == nil else { return [] }
        let roots = LauncherCatalogScope.allCases.map { scope in
            LauncherSearchResult.catalog(scope, count: catalogCount(scope))
        }
        guard let query = rootLauncherQuery else {
            guard input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let favourites = emptyQueryFavourites
            let ask = LauncherSearchResult.item(askAIItem(query: ""))
            let ordered = favourites.contains { $0.id == ask.id } ? favourites + roots : favourites + [ask] + roots
            return Array(ordered.prefix(Self.maxLauncherRows))
        }
        let signals = learnedSignals(query: query, scope: LauncherUsageStore.rootScope)
        let hidden = hiddenLauncherItemIDs()
        let foldedQuery = FuzzyMatcher.fold(query)
        var scored: [(LauncherSearchResult, Int)] = []

        // Ask AI is always in the list. Its base score follows the shape of
        // the text; pins, aliases, and learning add to it like any other row.
        let ask = askAIItem(query: query)
        var askScore = AskAIRanker.baseScore(for: query)
        let askAlias = launcherItemAlias(for: ask)
        if !askAlias.isEmpty, FuzzyMatcher.fold(askAlias) == foldedQuery { askScore += 12_000 }
        askScore += LauncherRanker.boost(for: signals[ask.id]) + pinBoost(ask)
        scored.append((.item(ask), askScore))

        for root in roots {
            guard case .catalog(let scope, _) = root else { continue }
            let best = scope.aliases.compactMap { alias in
                matchScore(foldedQuery: foldedQuery, title: scope.title, alias: alias)
            }.max()
            guard let best else { continue }
            scored.append((root, best + LauncherRanker.boost(for: signals[root.id])))
        }
        for (application, score) in scoredApplications(
            foldedQuery: foldedQuery,
            signals: signals,
            hiddenIDs: hidden
        ) {
            scored.append((.application(application), score))
        }
        for item in systemCommands + folderItems + snippets + quickLinks + settingsDestinationItems {
            // A hidden row is gone from search even when an alias, pin, or
            // learned abbreviation still points at it.
            guard !hidden.contains(item.id) else { continue }
            guard let score = matchScore(
                foldedQuery: foldedQuery,
                title: item.title,
                alias: launcherItemAlias(for: item),
                keywords: item.kind == .command || item.kind == .folder ? item.keywords : ""
            ) else { continue }
            scored.append((.item(item), score + LauncherRanker.boost(for: signals[item.id]) + pinBoost(item)))
        }
        // A web address typed in full opens in the Quick Link browser. The
        // item id carries a stable content digest, not the address itself, so
        // nothing that records identifiers — learned ranking, the interaction
        // journal — ever sees what was typed.
        if let url = TypedURLDetector.url(from: query) {
            let item = LauncherCatalogItem(
                kind: .quickLink,
                itemID: "typed:" + StableIdentifier.make(url.absoluteString),
                title: "Open " + (url.host ?? url.absoluteString),
                detail: url.absoluteString,
                value: url.absoluteString
            )
            scored.append((.item(item), 13_000))
        }
        // Math, conversions, dates, and system facts answer inline, above everything.
        if let answer = localAnswer(for: query) {
            scored.append((.item(Self.answerItem(RootAnswer(question: query, answer: answer))), 14_000))
        } else if let translation = inlineTranslation, InlineTranslationQuery.parse(query) == translation.query {
            // A whole language name reads as a request to translate; a
            // prefix ("time in japan") sits just under Ask AI.
            let score = translation.query.namesLanguageExactly ? 13_500 : AskAIRanker.promptScore - 50
            scored.append((.item(Self.inlineTranslationItem(translation)), score))
        }
        var ranked = scored
            .sorted { lhs, rhs in
                lhs.1 == rhs.1
                    ? Self.displayTitle(lhs.0).localizedCaseInsensitiveCompare(Self.displayTitle(rhs.0)) == .orderedAscending
                    : lhs.1 > rhs.1
            }
            .map(\.0)
        let askID = LauncherSearchResult.item(ask).id
        let unboostedSingleWord = AskAIRanker.baseScore(for: query) == AskAIRanker.wordScore
            && askScore == AskAIRanker.wordScore
        if unboostedSingleWord {
            ranked.removeAll { $0.id == askID }
            ranked = Array(ranked.prefix(Self.maxLauncherRows - 1))
            ranked.append(.item(ask))
        } else if ranked.count > Self.maxLauncherRows {
            if let position = ranked.firstIndex(where: { $0.id == askID }), position >= Self.maxLauncherRows {
                // Keep the row reachable: it takes the last visible slot.
                ranked.remove(at: position)
                ranked.insert(.item(ask), at: Self.maxLauncherRows - 1)
            }
            ranked = Array(ranked.prefix(Self.maxLauncherRows))
        }
        return ranked
    }

    /// The inline answer row, and what Return on a root answer does: the
    /// answer as the title, the question as the detail; Return copies.
    static func answerItem(_ answer: RootAnswer) -> LauncherCatalogItem {
        LauncherCatalogItem(
            kind: .answer,
            itemID: "answer",
            title: answer.answer,
            detail: answer.question,
            value: answer.answer,
            keywords: "answer result"
        )
    }

    static func inlineTranslationItem(_ translation: InlineTranslation) -> LauncherCatalogItem {
        let title = switch translation.status {
        case .translating: translation.text.isEmpty ? "Translating…" : translation.text
        case .ready: translation.text
        case .failed: "Translation unavailable"
        }
        return LauncherCatalogItem(
            kind: .answer,
            itemID: LauncherCatalogItem.inlineTranslationItemID,
            title: title,
            detail: "\(translation.query.target.title) · \(translation.query.phrase)",
            value: translation.status == .ready ? translation.text : "",
            keywords: "translate translation"
        )
    }

    /// The footer's context while a local answer is on root search.
    static let rootAnswerContext = "Local answer"

    /// Deterministic answers computed as you type. None of these touch a model.
    func localAnswer(for query: String, allowConversions: Bool = true) -> String? {
        if MathExpressionDetector.isMathExpression(query),
           let value = try? MathCalculator.evaluate(query) {
            return MathCalculator.format(value)
        }
        if allowConversions, let converted = LocalConversionResolver.answer(query) { return converted }
        return SystemFactsResolver.answer(query)
    }

    private func pinBoost(_ item: LauncherCatalogItem) -> Int {
        item.isPinned ? LauncherRanker.pinnedBoost : 0
    }

    /// Most-used root results, shown before the catalog roots on an empty query.
    private var emptyQueryFavourites: [LauncherSearchResult] {
        guard settings.launcherLearningEnabled else { return [] }
        let ids = launcherUsage.topItemIDs(
            scope: LauncherUsageStore.rootScope,
            limit: Self.emptyQueryFavouriteRows * 3
        )
        var favourites: [LauncherSearchResult] = []
        for id in ids where favourites.count < Self.emptyQueryFavouriteRows {
            if let result = rootResult(id: id) { favourites.append(result) }
        }
        return favourites
    }

    private func rootResult(id: String) -> LauncherSearchResult? {
        // A hidden row is never a favourite: an alias, pin, or use count
        // must not resurface it on the empty query.
        let hidden = hiddenLauncherItemIDs()
        guard !hidden.contains(id) else { return nil }
        if id == LauncherCatalogItem(kind: .askAI, itemID: Self.askAIItemID, title: "", detail: "", value: "").id {
            return .item(askAIItem(query: ""))
        }
        if let application = applications.first(where: {
            LauncherSearchResult.application($0).id == id
        }) {
            return .application(application)
        }
        if let item = (systemCommands + folderItems + snippets + quickLinks + settingsDestinationItems).first(where: { $0.id == id }) {
            return .item(item)
        }
        return nil
    }

    static func displayTitle(_ result: LauncherSearchResult) -> String {
        switch result {
        case .application(let application): application.name
        case .catalog(let scope, _): scope.title
        case .item(let item): item.title
        }
    }

    static func displayDetail(_ result: LauncherSearchResult) -> String {
        switch result {
        case .application: "Application"
        case .catalog(let scope, let count):
            count > 0 ? "\(scope.title), \(catalogCountDetail(count))" : scope.title
        case .item(let item): item.detail
        }
    }

    /// "1 item", "12 items"; a zero count is left off by the caller.
    static func catalogCountDetail(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// The trailing type label tells rows apart; when every visible row is
    /// the same kind it only repeats itself.
    var showsRowTypeLabels: Bool {
        Set(launcherMatches.map { LauncherResultRow.typeLabel(for: $0) }).count != 1
    }

    // MARK: - Footer and badges

    struct FooterHint: Equatable, Sendable {
        let label: String
        let keys: [String]
    }

    /// The footer stays visible while a ⌘K pane floats above it, like
    /// Raycast's bottom bar; hiding it made the window jump on every
    /// pane open and close.
    var showsLauncherFooter: Bool { true }

    /// Left side of the footer: where the user is, or which model answers.
    var footerContext: String {
        if catalogScope == .screenshots, screenshotIndexProgress.isRunning {
            return "Reading text \(screenshotIndexProgress.completed)/\(screenshotIndexProgress.total)"
        }
        switch inputMode {
        case .caffeinateUntil: return "Caffeinate Until"
        case .renameChat: return "Rename Chat"
        case .renameClipboard: return "Rename Entry"
        case .snippetArgument:
            return pendingSnippetInsertion.map { "Snippet · \($0.item.title)" } ?? "Snippet"
        case .houseCommandArgument:
            guard let row = pendingHouseCommandText else { return "Command" }
            return "\(row.manifest.name) · \(row.command.title)"
        case nil: break
        }
        if let pendingQuickLink { return pendingQuickLink.title }
        if let catalogScope { return catalogScope.title }
        if pendingImage != nil { return activeModelDisplay }
        if rootAnswer != nil { return Self.rootAnswerContext }
        if !launcherMatches.isEmpty, !input.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Quick Launch"
        }
        return activeModelDisplay
    }

    /// The footer while an item's form is open. The form is the top layer,
    /// so the footer names the form's own keys, not the row's behind it.
    static func footerHints(forForm form: ItemActionForm) -> [FooterHint] {
        let cancel = FooterHint(label: "Cancel", keys: ["esc"])
        switch form {
        case .edit:
            return [FooterHint(label: "Save", keys: ["⌘", "↩"]), cancel]
        case .alias, .hotkey:
            return [FooterHint(label: "Done", keys: ["⌘", "↩"]), cancel]
        }
    }

    /// Right side of the footer: what Return and the main shortcuts do now.
    var footerHints: [FooterHint] {
        // An open form owns the footer: Paste and Copy act on the row behind
        // it, and neither is what Return does while the editor is up.
        if let activeItemActionForm { return Self.footerHints(forForm: activeItemActionForm) }
        if isStreaming { return [FooterHint(label: "Stop", keys: ["esc"])] }
        if hasPendingAttachment {
            var hints = [
                FooterHint(label: "Ask", keys: ["↩"]),
                FooterHint(label: "Remove", keys: ["⌫"]),
            ]
            // Retake is a screenshot's; a file or a link has nothing to retake.
            if !pendingImages.isEmpty || pendingContext != nil {
                hints.append(FooterHint(
                    label: "Retake",
                    keys: ScreenshotKind.window.overlayKeyCaps(shortcuts)
                ))
            }
            return hints
        }
        if let inputMode {
            switch inputMode {
            case .caffeinateUntil:
                return [
                    FooterHint(label: "Caffeinate", keys: ["↩"]),
                    FooterHint(label: "Back", keys: ["⌫"]),
                ]
            case .renameChat, .renameClipboard:
                return [
                    FooterHint(label: "Save", keys: ["↩"]),
                    FooterHint(label: "Back", keys: ["⌫"]),
                ]
            case .houseCommandArgument:
                return [
                    FooterHint(label: "Run", keys: ["↩"]),
                    FooterHint(label: "Back", keys: ["⌫"]),
                ]
            case .snippetArgument:
                let isLast = pendingSnippetInsertion?.arguments.count
                    == (pendingSnippetInsertion?.collected.count ?? 0) + 1
                return [
                    FooterHint(label: isLast ? "Insert" : "Next", keys: ["↩"]),
                    FooterHint(label: "Back", keys: ["⌫"]),
                ]
            }
        }
        if pendingQuickLink != nil {
            return [
                FooterHint(label: "Open", keys: ["↩"]),
                FooterHint(label: "Back", keys: ["⌫"]),
            ]
        }
        if let rootAnswer {
            // Return does what the inline answer row does.
            return [
                FooterHint(label: Self.answerItem(rootAnswer).defaultActionTitle, keys: ["↩"]),
                FooterHint(label: "Clear", keys: ["esc"]),
            ]
        }
        let matches = launcherMatches
        if !matches.isEmpty {
            let index = min(applicationSelectionIndex, matches.count - 1)
            // Primary key and ⌘K only; Copy, Capture, ⇧↩ and ⌫ still work.
            var hints = [FooterHint(label: primaryActionTitle(for: matches[index]), keys: ["↩"])]
            if case .catalog = matches[index] {
                // Roots have no ⌘K actions.
            } else {
                hints.append(FooterHint(label: "Actions", keys: shortcutKeyCaps(for: .commandPalette)))
            }
            return hints
        }
        if !savedPromptMatches.isEmpty {
            return [
                FooterHint(label: "Complete", keys: ["⇥"]),
                FooterHint(label: "Run", keys: ["↩"]),
            ]
        }
        if catalogScope != nil { return [] }
        return [
            FooterHint(label: input.isEmpty ? "Open" : "Ask", keys: ["↩"]),
            FooterHint(label: "Actions", keys: shortcutKeyCaps(for: .commandPalette)),
        ]
    }

    func primaryActionTitle(for result: LauncherSearchResult) -> String {
        switch result {
        case .application: "Open"
        case .catalog: "Browse"
        case .item(let item): item.defaultActionTitle
        }
    }

    /// The global hotkey bound to a launcher row, for its key-cap badge.
    func hotkey(for result: LauncherSearchResult) -> ActionHotkey? {
        switch result {
        case .application(let application):
            return applicationHotkey(for: application)
        case .catalog(let scope, _):
            return scope == .clipboard ? settings.clipboardHistoryHotkey : nil
        case .item(let item):
            return launcherItemHotkey(for: item)
        }
    }

    /// Scope key used when learning from a selection in the current view.
    var learningScope: String {
        catalogScope?.rawValue ?? LauncherUsageStore.rootScope
    }

    /// Remember that the user chose `result` for the current input. `query`
    /// overrides the field for a path that clears it before recording (a
    /// successful app launch), so the mnemonic keeps what was typed.
    func learn(_ result: LauncherSearchResult, query explicitQuery: String? = nil) {
        let query = explicitQuery ?? input
        noteActedQuery(query)
        recordJournal(
            kind: .selectionAccepted,
            scope: learningScope,
            itemID: result.id,
            query: query
        )
        guard settings.launcherLearningEnabled else { return }
        launcherUsage.recordSelection(query: query, scope: learningScope, itemID: result.id)
        launcherRankingVersion += 1
    }

    /// Remember a use that skipped the launcher, such as a global hotkey.
    func learnDirectUse(of item: LauncherCatalogItem) {
        learnDirectUse(itemID: item.id, scope: LauncherUsageStore.rootScope)
    }

    func learnDirectUse(of application: LaunchableApplication) {
        learnDirectUse(
            itemID: LauncherSearchResult.application(application).id,
            scope: LauncherUsageStore.rootScope
        )
    }

    /// One hotkey run of an item that never passed through the launcher.
    /// Journals the review row and, when ranking learning is on, the use count.
    func learnDirectUse(itemID: String, scope: String) {
        noteDirectHotkeyUse(itemID: itemID, scope: scope)
        guard settings.launcherLearningEnabled else { return }
        launcherUsage.recordUse(itemID: itemID, scope: scope)
        launcherRankingVersion += 1
    }

    /// Journal row for a hotkey run with no launcher item to learn against,
    /// such as a saved AI action. Ranking is left untouched.
    /// The hotkey row for a saved action: `action:<uuid>`, the same id a
    /// `savedActionRun` row carries.
    func noteDirectHotkeyUse(ofAction action: SavedPrompt) {
        noteDirectHotkeyUse(itemID: "action:\(action.id.uuidString)")
    }

    func noteDirectHotkeyUse(
        itemID: String,
        scope: String = LauncherUsageStore.rootScope
    ) {
        recordJournal(kind: .directHotkeyUse, scope: scope, itemID: itemID)
    }

    /// Journal row for a feature that has no launcher row: kind and a stable
    /// id only (`feature:<name>`, `action:<uuid>`, `command:<id>`), never
    /// the text, selection, answer or prompt it worked on.
    func noteFeatureUse(_ kind: InteractionJournalEventKind, itemID: String) {
        recordJournal(kind: kind, itemID: itemID)
    }

    /// The app's wiring from Type to Click to the journal. AppDelegate and the
    /// tests both call this, so a test exercises the real path.
    func journalFeatureUse(of controller: TypeToClickController) {
        controller.onTargetUsed = { [weak self] in
            self?.noteFeatureUse(.typeToClickUsed, itemID: "feature:type-to-click")
        }
    }

    /// The app's wiring from the Translator window to the journal.
    func journalFeatureUse(of model: TranslatorModel) {
        model.onTranslationRun = { [weak self] in
            self?.noteFeatureUse(.translatorRun, itemID: "feature:translator")
        }
    }

    func forgetLearnedRanking() {
        launcherUsage.reset()
        launcherRankingVersion += 1
        applicationSelectionIndex = 0
    }

    /// Call after an alias or hotkey edit so cached rankings pick it up.
    func invalidateLauncherRanking() {
        launcherRankingVersion += 1
    }

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

    /// The submit Tab started, kept so a test can await it.
    @ObservationIgnored var tabSubmitTask: Task<Void, Never>?

    /// The submit Return started from the Quick AI composer, kept so a test
    /// can await it and a second Return cannot race the first.
    @ObservationIgnored var composerSubmitTask: Task<Void, Never>?

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

    // MARK: - Fallback Commands

    /// Return on unmatched root-search text. `nil` is the empty fallback list:
    /// nothing runs and the typed text stays a search.
    func runRootFallback(_ identifier: String?) async {
        guard let identifier else {
            requestInputFocus()
            return
        }
        await runFallbackCommand(identifier, text: input)
    }

    /// Runs one configured Fallback Command with the text the user typed.
    /// Tab is never part of this: `handleTab()` always opens Quick AI.
    func runFallbackCommand(_ identifier: String, text: String) async {
        if identifier == FallbackCommandID.askAI {
            // The Ask AI row itself, so the learned ranking and the journal
            // see exactly what they saw when the row was the only path.
            await performLauncherResult(.item(askAIItem(query: text)))
            return
        }
        if let promptID = FallbackCommandID.savedPromptUUID(from: identifier) {
            guard let prompt = settings.savedPrompts.first(where: { $0.id == promptID }) else {
                errorMessage = "That fallback command is no longer available."
                requestInputFocus()
                return
            }
            // The same shape `/alias text` has, so the command lane, the model
            // lane, and `{selection}` behave exactly as they do when the alias
            // is typed by hand.
            input = settings.savedPromptPrefix + prompt.alias + " " + text
            inputMode = nil
            await submit()
            return
        }
        if let itemID = FallbackCommandID.commandItemID(from: identifier),
           let item = fallbackCommandItems.first(where: { $0.itemID == itemID }) {
            // AI Chat takes what was typed as the new chat's draft; run as a
            // root row, the text is only the search that found the command.
            if item.value == Self.aiChatCommandID {
                inputMode = nil
                openAIChatWindow(draft: text)
                return
            }
            input = text
            inputMode = nil
            await performLauncherItem(item)
            return
        }
        errorMessage = "That fallback command is no longer available."
        requestInputFocus()
    }

    /// One row of the Fallback Commands card.
    struct FallbackCommandEntry: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
        let systemImage: String
    }

    /// The configured Fallback Commands, in order, resolved against the
    /// commands that still exist.
    var fallbackCommandEntries: [FallbackCommandEntry] {
        settings.fallbackCommandIDs.map(fallbackCommandEntry(for:))
    }

    /// What one identifier names. A command the user later deleted resolves to
    /// a row that says so rather than vanishing silently.
    func fallbackCommandEntry(for identifier: String) -> FallbackCommandEntry {
        if identifier == FallbackCommandID.askAI {
            return FallbackCommandEntry(
                id: identifier,
                title: "Ask AI",
                detail: "Send the text to \(activeModelDisplay)",
                systemImage: "sparkles"
            )
        }
        if let promptID = FallbackCommandID.savedPromptUUID(from: identifier) {
            guard let prompt = settings.savedPrompts.first(where: { $0.id == promptID }) else {
                return FallbackCommandEntry(
                    id: identifier,
                    title: "Missing command",
                    detail: "This saved AI command was deleted. Remove the row.",
                    systemImage: "questionmark.circle"
                )
            }
            return FallbackCommandEntry(
                id: identifier,
                title: prompt.name,
                detail: "Saved AI command \(settings.savedPromptPrefix)\(prompt.alias)",
                systemImage: "text.quote"
            )
        }
        if let itemID = FallbackCommandID.commandItemID(from: identifier),
           let item = fallbackCommandItems.first(where: { $0.itemID == itemID }) {
            return FallbackCommandEntry(
                id: identifier,
                title: item.title,
                detail: item.detail,
                systemImage: item.systemImage
            )
        }
        return FallbackCommandEntry(
            id: identifier,
            title: "Missing command",
            detail: "This command is no longer available. Remove the row.",
            systemImage: "questionmark.circle"
        )
    }

    /// The app's own command catalogs, as the Fallback Commands card offers
    /// them.
    var fallbackCommandItems: [LauncherCatalogItem] { systemCommands }

    /// One command the Fallback Commands card can add.
    struct FallbackCommandChoice: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
    }

    struct FallbackCommandChoiceGroup: Identifiable, Sendable {
        let id: String
        let title: String
        let choices: [FallbackCommandChoice]
    }

    /// Everything the card can add, in groups, minus what it already holds.
    var fallbackCommandChoiceGroups: [FallbackCommandChoiceGroup] {
        let configured = Set(settings.fallbackCommandIDs)
        var groups: [FallbackCommandChoiceGroup] = []
        if !configured.contains(FallbackCommandID.askAI) {
            groups.append(FallbackCommandChoiceGroup(
                id: "askAI",
                title: "Quick AI",
                choices: [FallbackCommandChoice(
                    id: FallbackCommandID.askAI,
                    title: "Ask AI",
                    detail: "Send the text to \(activeModelDisplay)"
                )]
            ))
        }
        let prompts = settings.savedPrompts.compactMap { prompt -> FallbackCommandChoice? in
            let id = FallbackCommandID.savedPrompt(prompt.id)
            guard !configured.contains(id) else { return nil }
            return FallbackCommandChoice(
                id: id,
                title: prompt.name,
                detail: "Saved AI command \(settings.savedPromptPrefix)\(prompt.alias)"
            )
        }
        if !prompts.isEmpty {
            groups.append(FallbackCommandChoiceGroup(
                id: "prompts",
                title: "AI Commands",
                choices: prompts
            ))
        }
        let commands = fallbackCommandItems.compactMap { item -> FallbackCommandChoice? in
            let id = FallbackCommandID.command(item.itemID)
            guard !configured.contains(id) else { return nil }
            return FallbackCommandChoice(id: id, title: item.title, detail: item.detail)
        }
        if !commands.isEmpty {
            groups.append(FallbackCommandChoiceGroup(
                id: "commands",
                title: "Commands",
                choices: commands
            ))
        }
        return groups
    }

    /// Add one command to the end of the Fallback Commands list.
    func addFallbackCommand(_ identifier: String) {
        guard !settings.fallbackCommandIDs.contains(identifier) else { return }
        updateSettings { $0.fallbackCommandIDs.append(identifier) }
    }

    /// Remove one command. Removing the last one is allowed: unmatched text
    /// then runs nothing on Return.
    func removeFallbackCommand(_ identifier: String) {
        updateSettings { settings in
            settings.fallbackCommandIDs.removeAll { $0 == identifier }
        }
    }

    /// Move a command to a new position, used by the card's drag handle and by
    /// its keyboard move buttons.
    func moveFallbackCommand(_ identifier: String, toIndex index: Int) {
        updateSettings { settings in
            guard let from = settings.fallbackCommandIDs.firstIndex(of: identifier) else { return }
            let item = settings.fallbackCommandIDs.remove(at: from)
            settings.fallbackCommandIDs.insert(
                item,
                at: min(max(index, 0), settings.fallbackCommandIDs.count)
            )
        }
    }

    // MARK: - Screenshots

    /// Capture a screenshot and attach it to the next question.
    /// `clearingInput` drops the command text that was typed to reach here;
    /// the overlay shortcut passes `false` so a half-typed question survives.
    @discardableResult
    func attachScreenshot(_ kind: ScreenshotKind, clearingInput: Bool) async -> Bool {
        guard let screenshotService else {
            errorMessage = "Screenshots are not available in this build."
            requestInputFocus()
            return false
        }
        do {
            let attachment = try await screenshotService.capture(
                kind,
                target: selectionTarget,
                ownProcess: ProcessInfo.processInfo.processIdentifier
            )
            pendingImage = attachment
            if kind == .window, let selectionTarget {
                var context = screenAwareness?.readContext(for: selectionTarget)
                    ?? CaptureContext(appName: selectionTarget.applicationName)
                context.hasScreenshot = true
                pendingContext = context
            } else if let selectionTarget {
                pendingContext = CaptureContext(appName: selectionTarget.applicationName, hasScreenshot: true)
            } else {
                pendingContext = nil
            }
            catalogScope = nil
            pendingQuickLinkID = nil
            isActionPalettePresented = false
            isApplicationActionPanePresented = false
            isCatalogActionPanePresented = false
            if clearingInput { input = "" }
            errorMessage = nil
            applicationSelectionIndex = 0
            requestInputFocus()
            return true
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
            return false
        }
    }

    // MARK: - Result actions

    /// Actions available on the answer on screen.
    var resultActions: [ResultAction] {
        // While an answer streams, Continue in pi is the one action: it stops
        // the answer, keeps it, and hands the chat over.
        guard !isStreaming else {
            return piHandoff != nil && !conversationMessages.isEmpty ? [.continueInPi] : []
        }
        let hasAnswer = !output.isEmpty
        // A question the thread holds without an answer (stopped before any
        // text, or a provider error) still offers ⌘R, and the chat actions.
        guard hasAnswer || hasUnansweredTurn else { return [] }
        // Replace Selection is the precise action after a selection transform:
        // it writes back to the originally captured selection (retained across
        // the request). Paste into Previous App is the broader fallback. Both
        // fail safe to Copy with a truthful error when the target is gone.
        var actions: [ResultAction] = []
        if hasAnswer {
            if replaceableSelectionContext != nil { actions.append(.replaceSelection) }
            actions.append(contentsOf: [.pasteBack, .copy])
        }
        if !conversationMessages.isEmpty {
            actions.append(.copyChat)
            if piHandoff != nil { actions.append(.continueInPi) }
        }
        if offersContinueInAIChat { actions.append(.continueInAIChat) }
        if fileOpener != nil, !answerSources.isEmpty { actions.append(.openSource) }
        if hasAnswer {
            actions.append(.saveSnippet)
            if memoryCapture != nil { actions.append(.captureToMemory) }
            actions.append(contentsOf: [.searchWeb, .pasteFormatted])
        }
        actions.append(contentsOf: [.regenerate, .regenerateWithModel, .changeModel])
        if !assistants.isEmpty { actions.append(.changeAssistant) }
        if isQuickAIPresented { actions.append(.tools) }
        actions.append(.newChat)
        if canOpenRecentChats { actions.append(.recentChats) }
        if currentConversation != nil {
            actions += [.renameChat, .pinChat, .deleteChat]
        }
        if history.count > 1 { actions += [.previousChat, .nextChat] }
        // The window reads and copies; it has no app behind it to paste
        // into, and its chat list is the rail, not Recent Chats.
        if isAIChatWindow { actions.removeAll { Self.launcherOnlyResultActions.contains($0) } }
        return actions
    }

    /// Answer actions the AI Chat window leaves out.
    static let launcherOnlyResultActions: Set<ResultAction> = [
        .replaceSelection, .pasteBack, .pasteFormatted, .recentChats, .continueInAIChat,
    ]

    /// `⌘J` hands the chat to the AI Chat window: on the Quick AI surface,
    /// when the app can open the window.
    var offersContinueInAIChat: Bool {
        aiChatOpener != nil && !isAIChatWindow && isQuickAIPresented
    }

    /// Display, search, and VoiceOver use the same state-dependent action.
    func resultActionTitle(_ action: ResultAction) -> String {
        if action == .pinChat, currentConversation?.isPinned == true { return "Unpin Chat" }
        return action.title
    }

    func resultActionSystemImage(_ action: ResultAction) -> String {
        if action == .pinChat, currentConversation?.isPinned == true { return "pin.slash" }
        return action.systemImage
    }

    /// The palette row's second line: the app a destination answer action
    /// targets (so the user never guesses which app receives the output),
    /// the model or tools in use, or what a chat action does to the chat.
    /// Nil falls back to the action's group, "Answer" or "Chat".
    func resultActionDetail(_ action: ResultAction) -> String? {
        switch action {
        case .replaceSelection:
            replaceableSelectionContext.map { "Replace in \($0.target.applicationName)" }
        case .pasteBack:
            selectionTarget.map { "Paste into \($0.applicationName)" }
        case .pasteFormatted:
            selectionTarget.map { "Formatted, into \($0.applicationName)" }
                ?? "Keep headings, lists and links"
        case .changeModel:
            "Using \(activeModelDisplay)"
        case .changeAssistant:
            activeAssistant.map { "Using \($0.name)" } ?? "No assistant"
        case .regenerateWithModel:
            "Run this question again on another model"
        case .openSource:
            answerSources.count == 1
                ? answerSources[0].title
                : "\(answerSources.count) sources"
        case .captureToMemory:
            "Send this answer to recall"
        case .tools:
            chatToolsSummary
        case .continueInPi:
            isStreaming ? "Stop the answer, then open pi" : "New tmux session in Ghostty"
        case .continueInAIChat:
            "Open this chat in its own window"
        // Chat actions say what they do to the chat; one with nothing to
        // add reads "Chat" (`paletteGroup`), never "Answer".
        case .copyChat:
            "The whole chat as text"
        case .newChat:
            "Start over on an empty chat"
        case .recentChats:
            "Pinned and recent chats"
        case .previousChat:
            "The chat before this one"
        case .nextChat:
            "The chat after this one"
        case .renameChat:
            "Give this chat a name"
        case .pinChat:
            currentConversation?.isPinned == true ? "Unpin this chat" : "Keep this chat at the top"
        case .deleteChat:
            "Remove this chat from history"
        default:
            nil
        }
    }

    func performResultAction(_ action: ResultAction) async {
        switch action {
        case .replaceSelection:
            _ = await replaceOutputInCapturedSelection()
        case .pasteBack:
            _ = await pasteOutputToPreviousApp()
        case .pasteFormatted:
            _ = await pasteFormattedOutputToPreviousApp()
        case .copy:
            // The surface stays open; the composer shows the checkmark.
            isActionPalettePresented = false
            copyAnswerOnSurface()
        case .copyChat:
            isActionPalettePresented = false
            copyChatTranscript()
        case .continueInPi:
            await continueInPi()
        case .continueInAIChat:
            isActionPalettePresented = false
            continueInAIChat()
        case .saveSnippet:
            saveOutputAsSnippet()
        case .searchWeb:
            await searchWebForOutput()
        case .regenerate:
            isActionPalettePresented = false
            await regenerateLastAnswer()
        case .regenerateWithModel:
            // `⇧⌘R`: choose first, then answer the same question again.
            openModelChooser(.regenerate)
        case .changeModel:
            // Switching model mid-conversation sends nothing: the next
            // question simply goes to the new model.
            openModelChooser(.change)
        case .changeAssistant:
            // Nothing is sent either: the next question goes to the chat
            // as the picked assistant.
            openAssistantChooser()
        case .newChat:
            isActionPalettePresented = false
            startNewConversation()
        case .recentChats:
            isActionPalettePresented = false
            openRecentChats()
        case .previousChat:
            // History is ordered newest first, so going back in time means
            // moving forward through the array.
            isActionPalettePresented = false
            browseConversations(1)
        case .nextChat:
            isActionPalettePresented = false
            browseConversations(-1)
        case .renameChat:
            guard let id = currentConversation?.id else { return }
            isActionPalettePresented = false
            // The AI Chat window renames in its chat list; the launcher's
            // field becomes the rename field.
            if let chatWindowHost {
                chatWindowHost.beginRenamingChat(id: id)
            } else {
                enterInputMode(.renameChat(id))
            }
        case .pinChat:
            guard let id = currentConversation?.id else { return }
            isActionPalettePresented = false
            togglePinConversation(id: id)
        case .deleteChat:
            guard let id = currentConversation?.id else { return }
            isActionPalettePresented = false
            deleteConversation(id: id)
        case .openSource:
            let sources = answerSources
            if sources.count == 1 {
                await openSource(sources[0])
            } else {
                openActionPaletteSubmenu(.sources)
            }
        case .captureToMemory:
            isActionPalettePresented = false
            await captureAnswerToMemory()
        case .tools:
            openActionPaletteSubmenu(.tools)
        }
    }

    // MARK: - Model chooser

    /// True while the keyboard model chooser is open. ↑↓ move, Return picks,
    /// Escape closes. Opened by `⇧⌘R` and by Change Model.
    var isModelChooserPresented = false {
        didSet { if !isModelChooserPresented { resumeQueuedFollowUp() } }
    }
    /// ⌘K › Change Assistant (`⌥⌘A`): the keyboard list of assistants over
    /// the Quick AI composer. ↑↓ move, Return picks, Escape closes.
    var isAssistantChooserPresented = false {
        didSet { if !isAssistantChooserPresented { resumeQueuedFollowUp() } }
    }
    var assistantChooserIndex = 0
    var modelChooserPurpose: ModelChooserPurpose = .change
    var modelChooserIndex = 0
    var modelChooserOptions: [ModelChooserOption] = []

    /// Opens the chooser for the last answer. Every provider's visible models
    /// are offered, and the row for the model already in use starts selected.
    func openModelChooser(_ purpose: ModelChooserPurpose) {
        let options = modelChooserEntries()
        guard !options.isEmpty else {
            errorMessage = "No model is available. Add a provider in Settings › Models."
            requestInputFocus()
            return
        }
        modelChooserOptions = options
        modelChooserPurpose = purpose
        modelChooserIndex = options.firstIndex { $0.model == activeModelID } ?? 0
        isModelChooserPresented = true
        isAssistantChooserPresented = false
        isCaptureChooserPresented = false
        isActionPalettePresented = false
        closeItemActionPane()
        isApplicationActionPanePresented = false
        isCatalogActionPanePresented = false
        actionQuery = ""
        errorMessage = nil
        requestInputFocus()
    }

    func closeModelChooser() {
        guard isModelChooserPresented else { return }
        isModelChooserPresented = false
        requestInputFocus()
    }

    func moveModelChooserSelection(_ delta: Int) {
        guard !modelChooserOptions.isEmpty else { return }
        modelChooserIndex = ListSelection.wrappedIndex(
            modelChooserIndex,
            by: delta,
            count: modelChooserOptions.count
        )
    }

    /// Return in the open chooser: make the pick active, then regenerate when
    /// the chooser was opened by `⇧⌘R`.
    func runModelChooserSelection() async {
        guard modelChooserOptions.indices.contains(modelChooserIndex) else { return }
        let option = modelChooserOptions[modelChooserIndex]
        let purpose = modelChooserPurpose
        isModelChooserPresented = false
        setActiveModel(providerID: option.providerID, model: option.model)
        switch purpose {
        case .change:
            requestInputFocus()
        case .regenerate:
            await regenerateLastAnswer()
        }
    }

    /// Every row the chooser may offer: each installed provider's visible
    /// models, in provider order.
    func modelChooserEntries() -> [ModelChooserOption] {
        settings.providers.flatMap { provider in
            visibleModels(for: provider).map { model in
                ModelChooserOption(
                    providerID: provider.id,
                    providerName: provider.name,
                    model: model
                )
            }
        }
    }

    /// Change Model, and the model half of `⇧⌘R`: the open chat answers
    /// with this provider and model from here on, and keeps them in history.
    /// Before a chat exists the pick waits for the chat the next question
    /// starts. The Quick AI default in Settings, and the other window, are
    /// left alone. Nothing is sent.
    func setActiveModel(providerID: UUID, model: String) {
        if currentConversation != nil {
            currentConversation?.providerID = providerID
            currentConversation?.model = model
            if !conversationMessages.isEmpty { persistCurrentConversation() }
        } else {
            pendingModelChoice = ChatModelChoice(providerID: providerID, model: model)
        }
        modelRefreshMessage = nil
        noteInteraction()
    }

    // MARK: - Add Context

    /// `⇧⌘A`: the built-in key for Add Context on a chat. Routing and the
    /// hints read the owner's resolved table (`shortcuts`); this is the
    /// built-in value the key tables and the free-key checks name.
    nonisolated static let attachShortcut: KeyShortcut = .commandShift("a")

    /// The attachment menu belongs to the composer, not a chat-list search
    /// or a rename/alias form. Those keep their own keyboard commands.
    var canOpenAttachments: Bool {
        isQuickAIPresented && !isRecentChatsPresented && inputMode == nil
            && !isStreaming
            && !isItemActionPanePresented && activeItemActionForm == nil
    }

    /// True while a chooser with its own search field is up. Those panes
    /// take the keyboard themselves, so the composer behind them must not
    /// pull focus back when a focus request is made.
    var searchablePaneOwningFocus: Bool {
        isAddContextMenuPresented || isCaptureChooserPresented
    }

    /// True while the Add Context menu is open. The same menu opens from the
    /// control left of the composer and from typing `@` in it.
    var isAddContextMenuPresented = false {
        didSet {
            if !isAddContextMenuPresented {
                addContextQuery = ""
                resumeQueuedFollowUp()
            }
        }
    }
    var addContextIndex = 0
    /// Add Context's own search, typed in the pane's own field. It filters
    /// the rows and never touches the composer draft; typing clears the
    /// highlight, as the rail's search does.
    var addContextQuery = "" {
        didSet { if addContextQuery != oldValue { addContextIndex = 0 } }
    }

    /// True while the Clipboard History submenu is open inside Add Context.
    /// Its rows come from the existing clipboard catalog (already filtered
    /// for concealed and transient copies); nothing here captures.
    var isClipboardHistoryOpen = false
    var clipboardHistoryIndex = 0
    /// The submenu's own search, typed in its own field, like Add Context's.
    /// It narrows the catalog rows and never touches the draft.
    var clipboardHistoryQuery = "" {
        didSet { if clipboardHistoryQuery != oldValue { clipboardHistoryIndex = 0 } }
    }

    /// The four capture paths, in the order the menu lists them. The AI
    /// Chat window has no app behind it: Focused Window and Selected Text
    /// read the app that was in front before the window became key, and
    /// leave the menu while no such app is known.
    var addContextOptions: [AddContextEntry] {
        guard isAIChatWindow, selectionTarget == nil else { return AddContextEntry.allCases }
        return AddContextEntry.allCases.filter { !$0.needsPreviousApp }
    }

    func openAddContextMenu() {
        guard !isStreaming else { return }
        isAddContextMenuPresented = true
        isClipboardHistoryOpen = false
        clipboardHistoryQuery = ""
        clipboardHistoryIndex = 0
        addContextQuery = ""
        addContextIndex = 0
        attachmentTray.cancelLinkEntry()
        attachmentTray.finderIsBehind = isFinderBehind
        isModelChooserPresented = false
        isAssistantChooserPresented = false
        isCaptureChooserPresented = false
        isActionPalettePresented = false
        closeItemActionPane()
        errorMessage = nil
        requestInputFocus()
    }

    func toggleAddContextMenu() {
        if isAddContextMenuPresented {
            closeAddContextMenu()
        } else {
            openAddContextMenu()
        }
    }

    func closeAddContextMenu() {
        guard isAddContextMenuPresented else { return }
        isAddContextMenuPresented = false
        isClipboardHistoryOpen = false
        clipboardHistoryQuery = ""
        attachmentTray.cancelLinkEntry()
        requestInputFocus()
    }

    func moveAddContextSelection(_ delta: Int) {
        let options = addContextRows
        guard !options.isEmpty, !attachmentTray.isEnteringLink else { return }
        addContextIndex = ListSelection.wrappedIndex(
            addContextIndex,
            by: delta,
            count: options.count
        )
    }

    /// Return in the open Add Context menu: the highlighted row, or, in the
    /// Link field, the link.
    func runAddContextSelection() async {
        if isClipboardHistoryOpen {
            await runClipboardHistorySelection()
            return
        }
        if attachmentTray.isEnteringLink {
            submitAttachmentLink()
            return
        }
        let options = addContextRows
        guard options.indices.contains(addContextIndex) else { return }
        switch options[addContextIndex] {
        case .capture(let entry):
            await addContext(entry)
        case .file:
            await chooseAttachmentFiles()
        case let row:
            runAddContextRow(row)
        }
    }

    /// Runs one entry through the capture path it already had. The half-typed
    /// question survives: an entry adds context to it, it never replaces it.
    func addContext(_ entry: AddContextEntry) async {
        isAddContextMenuPresented = false
        actionQuery = ""
        let typed = input
        switch entry {
        case .focusedWindow:
            await attachScreenshot(.window, clearingInput: false)
        case .selectedText:
            _ = attachSelectedText()
        case .selectedArea:
            // The capture hid the window; a good one brings it back, as a
            // failed one already did.
            if await attachScreenArea() { overlayPresenter.restoreAfterExternalAction() }
        case .entireScreen:
            await attachScreenshot(.display, clearingInput: false)
        }
        // Selected Text and Selected Area clear the field to make room for a
        // fresh question; from this menu the typed question comes back.
        if input.isEmpty, !typed.isEmpty { input = typed }
        requestInputFocus()
    }

    // MARK: - Capture chooser (⇧⌘S)

    /// `⇧⌘S` opens the compact capture chooser: the four captures only, in
    /// `AddContextEntry.captureChooserOrder` (Selected Text first), never
    /// Files…, Link…, or Finder Selection. ↑↓ move, Return attaches exactly
    /// the highlighted capture, Escape closes. `⇧⌘D` stays the direct
    /// display capture and `⇧⌘A` stays the full Add Context menu.
    /// The composer's `/` palette (`QuickViewModel+SlashCommands`).
    var isSlashCommandPalettePresented = false
    var slashCommandIndex = 0
    /// The skill names listed when the palette opened. Taken once, because
    /// the listing reads a directory.
    @ObservationIgnored var cachedSlashSkillNames: [String] = []

    var isCaptureChooserPresented = false {
        didSet {
            if !isCaptureChooserPresented {
                captureChooserQuery = ""
                resumeQueuedFollowUp()
            }
        }
    }
    var captureChooserIndex = 0
    /// The chooser's own search, typed in its own field. It filters the
    /// captures and leaves the composer draft alone.
    var captureChooserQuery = "" {
        didSet {
            guard captureChooserQuery != oldValue else { return }
            if captureChooserQuery.isEmpty, isCaptureChooserPresented,
               let preferred = captureChooserAllOptions.firstIndex(of: preferredCaptureEntry) {
                captureChooserIndex = preferred
            } else {
                captureChooserIndex = 0
            }
        }
    }
    /// Whether Selected Text is available, read once when the chooser opens
    /// and kept, so no Accessibility or capture work rides a render pass.
    private(set) var captureChooserHasSelection = false

    /// Every capture this surface can run, Selected Text first, before the
    /// search filter. A capture that reads the app behind leaves the list
    /// while no such app is known, so the chooser never advertises a row it
    /// cannot run and every surface keeps at least the two screen captures.
    var captureChooserAllOptions: [AddContextEntry] {
        AddContextEntry.captureChooser(offering: addContextOptions.filter {
            !$0.needsPreviousApp || selectionTarget != nil
        })
    }

    /// The chooser's rows after the search filter, best match first. The
    /// highlight always indexes this list, so the keys and the drawn rows
    /// agree.
    var captureChooserOptions: [AddContextEntry] {
        guard !captureChooserQuery.isEmpty else { return captureChooserAllOptions }
        return Self.rankByQuery(captureChooserAllOptions, query: captureChooserQuery, title: \.title)
    }

    /// Whether the app behind holds selected text, without doing anything
    /// the user can see or has to approve: the selection already captured
    /// for this request, the silent launch snapshot, else the injected
    /// `SelectedTextServicing` seam's own silent read. Tests drive it through
    /// `launchSelection` or a fake service; nothing here prompts for
    /// Accessibility, steals focus, or attaches anything.
    func selectedTextIsAvailableSilently() -> Bool {
        if let cached = selectedTextContext {
            return !cached.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let text = launchSelection?.text,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let target = selectionTarget, let selectedTextService else { return false }
        return selectedTextService.hasSelection(from: target)
    }

    /// The row the chooser highlights: Selected Text when selected text is
    /// available, else Focused Window, else the first capture this surface
    /// offers. Always a row inside `captureChooserOptions`.
    var preferredCaptureEntry: AddContextEntry {
        let options = captureChooserAllOptions
        if captureChooserHasSelection, options.contains(.selectedText) { return .selectedText }
        if options.contains(.focusedWindow) { return .focusedWindow }
        return options.first ?? .selectedArea
    }

    func openCaptureChooser() {
        isModelChooserPresented = false
        isAssistantChooserPresented = false
        isAddContextMenuPresented = false
        isTransformChooserPresented = false
        isActionPalettePresented = false
        closeItemActionPane()
        attachmentTray.cancelLinkEntry()
        errorMessage = nil
        captureChooserQuery = ""
        let options = captureChooserOptions
        guard !options.isEmpty else {
            // Never a silent no-op: the key says why it did nothing.
            errorMessage = "Nothing can be captured from here."
            requestInputFocus()
            return
        }
        captureChooserHasSelection = selectedTextIsAvailableSilently()
        captureChooserIndex = options.firstIndex(of: preferredCaptureEntry) ?? 0
        isCaptureChooserPresented = true
        requestInputFocus()
    }

    func closeCaptureChooser() {
        guard isCaptureChooserPresented else { return }
        isCaptureChooserPresented = false
        requestInputFocus()
    }

    func moveCaptureChooserSelection(_ delta: Int) {
        let options = captureChooserOptions
        guard !options.isEmpty else { return }
        captureChooserIndex = ListSelection.wrappedIndex(
            captureChooserIndex,
            by: delta,
            count: options.count
        )
    }

    /// Return in the open chooser: attach exactly the highlighted capture,
    /// through the same capture paths the Add Context rows use.
    func runCaptureChooserSelection() async {
        let options = captureChooserOptions
        guard !options.isEmpty else {
            // Never a silent no-op, even if the surface changed under the
            // chooser: the key says why it did nothing.
            isCaptureChooserPresented = false
            errorMessage = "Nothing can be captured from here."
            requestInputFocus()
            return
        }
        let entry = options[min(max(captureChooserIndex, 0), options.count - 1)]
        isCaptureChooserPresented = false
        await addContext(entry)
    }

    /// The character that opens Add Context from the composer.
    static let addContextTrigger: Character = "@"

    /// Typing `@` opens the same menu the control does. The `@` is a trigger,
    /// not content, so it is dropped; a `@` inside a word (an address) never
    /// opens the menu. Returns whether it opened.
    @discardableResult
    func addContextTriggerDidChange(_ newValue: String) -> Bool {
        guard !isAddContextMenuPresented,
              !isStreaming,
              !isItemActionPanePresented,
              // In Recent Chats the composer is a search field.
              !isRecentChatsPresented,
              // Only the root and answer composers: inside a catalog search or
              // a typed command an `@` is part of what is being typed.
              catalogScope == nil,
              inputMode == nil,
              pendingQuickLinkID == nil,
              newValue.last == Self.addContextTrigger
        else { return false }
        let head = newValue.dropLast()
        guard head.isEmpty || head.last?.isWhitespace == true else { return false }
        input = String(head)
        openAddContextMenu()
        return true
    }

    /// Save the current result as a new snippet, then open its ⌘K pane so
    /// the title can be edited in place.
    func saveOutputAsSnippet() {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            errorMessage = "There is no result to save yet."
            requestInputFocus()
            return
        }
        guard let launcherCatalog else {
            errorMessage = LauncherCatalogError.creationUnsupported.localizedDescription
            requestInputFocus()
            return
        }
        let prompt = currentConversation?.messages.first(where: { $0.role == .user })?.content
        let title = Self.snippetTitle(from: prompt ?? value)
        do {
            let item = try launcherCatalog.createSnippet(title: title, value: value)
            isActionPalettePresented = false
            actionQuery = ""
            errorMessage = nil
            contextualCatalogItemID = item.id
            isCatalogActionPanePresented = true
            noteInteraction()
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
        }
    }

    /// First line of `text`, trimmed to a short title.
    static func snippetTitle(from text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#*>-• "))
        guard !cleaned.isEmpty else { return "Quick Launch result" }
        return cleaned.count > 48 ? String(cleaned.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : cleaned
    }

    /// Run a web search using the current result as the query.
    func searchWebForOutput() async {
        let query = Self.searchQuery(from: output)
        guard !query.isEmpty else {
            errorMessage = "There is no result to search for yet."
            requestInputFocus()
            return
        }
        isActionPalettePresented = false
        actionQuery = ""
        startNewConversation()
        input = "search the web for \(query)"
        await submit()
    }

    /// First sentence or line of `text`, capped for a search box.
    static func searchQuery(from text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "#*>-• "))
        return String(cleaned.prefix(160))
    }

    /// Folder scanned by "Attach Latest Screenshot"; tests point it elsewhere.
    /// Pointing it somewhere new invalidates the cached scan so the next
    /// catalog entry rescans from disk.
    @ObservationIgnored var screenshotsFolder: URL = LatestScreenshotFinder.screenshotsFolder() {
        didSet {
            if oldValue != screenshotsFolder { lastScreenshotScanAt = nil }
        }
    }
    /// Every directory root the browser scans: the system screenshot folder
    /// first, then the user's extra folders. Only these roots are scanned,
    /// never home, and never recursively. Duplicates are dropped.
    var screenshotFolders: [URL] {
        var roots = [screenshotsFolder]
        for path in settings.screenshotFolders {
            let expanded = (path as NSString).expandingTildeInPath
            guard !expanded.isEmpty,
                  !roots.contains(where: { $0.path == expanded })
            else { continue }
            roots.append(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return roots
    }
    /// When `screenshotFiles` was read from disk; nil until the first scan.
    @ObservationIgnored var lastScreenshotScanAt: Date?
    @ObservationIgnored private var screenshotScanTask: Task<Void, Never>?
    /// A scan this fresh is trusted on catalog entry, so entering costs nothing.
    static let screenshotScanFreshness: TimeInterval = 2

    /// Reads the folder off the main thread and swaps the list in when done.
    /// Repeated calls collapse into the running scan. Keeps the root badge
    /// and a first catalog entry instant: no disk work on the hot path.
    func refreshScreenshotFilesInBackground() {
        guard screenshotScanTask == nil else { return }
        let folder = screenshotsFolder
        let folders = screenshotFolders
        let includeAllMedia = settings.screenshotIncludeAllMedia
        let requestedAt = Date()
        screenshotScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let items = ScreenshotLibrary.items(
                inFolders: folders,
                includeAllMedia: includeAllMedia,
                now: requestedAt
            )
            await MainActor.run { [weak self] in
                self?.applyScreenshotScan(items, from: folder, requestedAt: requestedAt)
            }
        }
    }

    /// Re-runs screenshot OCR after the recognition mode changes, so the
    /// Text recognition control takes effect instead of leaving the first
    /// pass's text cached. The running pass is cancelled first so its stale
    /// results cannot overwrite the new mode's.
    func reindexScreenshotText(mode: ClipboardOCRMode) {
        screenshotTextIndex.cancel()
        screenshotTextIndex.refresh(for: screenshotFiles, mode: mode)
    }

    /// Warms the list when the cached scan is older than the freshness window.
    /// Called whenever the overlay appears, off the keystroke path.
    func warmScreenshotCatalogIfStale() {
        if catalogScope == .screenshots {
            // A rapid capture can arrive inside the cache freshness window.
            // Retained history always refreshes when the overlay reopens.
            refreshScreenshotFilesInBackground()
            return
        }
        if let last = lastScreenshotScanAt, Date().timeIntervalSince(last) < Self.screenshotScanFreshness {
            return
        }
        refreshScreenshotFilesInBackground()
    }

    /// Waits out a running background scan, for tests.
    func waitForScreenshotScanForTesting() async {
        await screenshotScanTask?.value
        screenshotScanTask = nil
    }

    /// Applies a finished background scan. A scan that was requested before
    /// newer data already landed (a synchronous reload on catalog entry, or
    /// a later scan) is dropped: without this, a slow listing taken before
    /// the newest capture would land afterwards and push it off the top.
    func applyScreenshotScan(_ items: [LauncherCatalogItem], from folder: URL, requestedAt: Date) {
        screenshotScanTask = nil
        guard folder == screenshotsFolder else { return }
        if let applied = lastScreenshotScanAt, requestedAt < applied { return }
        let browsedItemID = catalogScope == .screenshots && applicationSelectionIndex > 0
            ? focusedLauncherResult?.id : nil
        screenshotFiles = items
        lastScreenshotScanAt = Date()
        if settings.screenshotTextSearch {
            screenshotTextIndex.refresh(for: items, mode: settings.screenshotOCRMode)
        }
        invalidateLauncherRanking()
        if let browsedItemID {
            // Keep an older capture under the cursor when a new one arrives.
            // Row zero intentionally follows the newest capture for rapid paste.
            applicationSelectionIndex = launcherMatches.firstIndex { $0.id == browsedItemID }
                ?? min(applicationSelectionIndex, max(0, launcherMatches.count - 1))
        }
    }

    /// Send Screen Area to AI: the system selection rectangle, then attach.
    @discardableResult
    func attachScreenArea() async -> Bool {
        guard let screenAwareness else {
            errorMessage = "Screen capture is not available in this build."
            requestInputFocus()
            return false
        }
        prepareForExternalAction?()
        guard let attachment = await screenAwareness.captureArea() else {
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        pendingImage = attachment
        pendingContext = selectionTarget.map { CaptureContext(appName: $0.applicationName, hasScreenshot: true) }
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        input = ""
        errorMessage = nil
        applicationSelectionIndex = 0
        requestInputFocus()
        return true
    }

    /// Send Selected Text to AI: context only, no image.
    @discardableResult
    func attachSelectedText() -> Bool {
        guard let selectionTarget else {
            errorMessage = ScreenshotCaptureError.noPreviousApp.localizedDescription
            requestInputFocus()
            return false
        }
        // An explicit Selected Text capture re-arms the selection read: a
        // prior "remove chip" must not suppress it, and the cached context is
        // refreshed rather than reused.
        selectionRecaptureSuppressed = false
        selectedTextContext = nil
        guard let selected = captureSelectedText(promptForPermission: true)?.text
                .trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty else {
            errorMessage = selectedTextService?.isAccessibilityTrusted == false
                ? "Allow Accessibility in System Settings, then select text and try again."
                : "Nothing is selected in \(selectionTarget.applicationName)."
            requestInputFocus()
            return false
        }
        var context = screenAwareness?.readContext(for: selectionTarget)
            ?? CaptureContext(appName: selectionTarget.applicationName)
        context.selectedText = selected
        context.appText = nil
        context.focusedValue = nil
        pendingContext = context
        // Adding text keeps the images already chosen for this question.
        // An explicit Selected Text capture supersedes the auto-captured
        // launch selection, so the two are never sent twice.
        launchSelection = nil
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        input = ""
        errorMessage = nil
        requestInputFocus()
        return true
    }

    /// Paste Latest Screenshot: newest file straight into the app behind.
    func pasteLatestScreenshot() async {
        guard let url = LatestScreenshotFinder.newestScreenshot(in: screenshotsFolder) else {
            errorMessage = "No screenshot found in \(screenshotsFolder.lastPathComponent)."
            requestInputFocus()
            return
        }
        await pasteImageFile(url)
    }

    /// Copies an image file to the pasteboard and presses ⌘V in the previous app.
    @discardableResult
    func pasteImageFile(_ url: URL) async -> Bool {
        guard pasteboard.writeImageFile(at: url) else {
            errorMessage = "Could not read \(url.lastPathComponent)."
            requestInputFocus()
            return false
        }
        guard let target = selectionTarget, let selectedTextService else {
            markJustCopied()
            errorMessage = "No app was behind Quick Launch. The image was copied instead."
            requestInputFocus()
            return false
        }
        prepareForExternalAction?()
        await Task.yield()
        let outcome = await selectedTextService.pastePasteboardOutcome(to: target)
        if outcome == .clipboardChanged {
            errorMessage = Self.clipboardChangedMessage
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        guard outcome == .pasted else {
            markJustCopied()
            errorMessage = "Could not paste into \(target.applicationName). The image was copied instead."
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        input = ""
        return true
    }

    /// Attach a saved screenshot file to the next question.
    @discardableResult
    func attachScreenshotFile(_ item: LauncherCatalogItem) -> Bool {
        let url = URL(fileURLWithPath: item.value)
        guard let attachment = LatestScreenshotFinder.attachment(for: url) else {
            errorMessage = "Could not read \(url.lastPathComponent)."
            requestInputFocus()
            return false
        }
        learn(.item(item))
        pendingImage = attachment
        pendingContext = CaptureContext(appName: item.title, hasScreenshot: true)
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        input = ""
        errorMessage = nil
        applicationSelectionIndex = 0
        requestInputFocus()
        return true
    }

    /// Attach the newest saved screenshot from the screenshots folder.
    @discardableResult
    func attachLatestScreenshot() -> Bool {
        guard let url = LatestScreenshotFinder.newestScreenshot(in: screenshotsFolder) else {
            errorMessage = "No screenshot found in \(screenshotsFolder.lastPathComponent)."
            requestInputFocus()
            return false
        }
        guard let attachment = LatestScreenshotFinder.attachment(for: url) else {
            errorMessage = "Could not read \(url.lastPathComponent)."
            requestInputFocus()
            return false
        }
        pendingImage = attachment
        // Same attachment card as the other captures: what it is and where
        // it came from.
        pendingContext = selectionTarget.map { CaptureContext(appName: $0.applicationName, hasScreenshot: true) }
        catalogScope = nil
        pendingQuickLinkID = nil
        closeItemActionPane()
        input = ""
        errorMessage = nil
        applicationSelectionIndex = 0
        requestInputFocus()
        return true
    }

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
    private func controlRunningApplication(_ application: LaunchableApplication, action: ItemActionKind) {
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

    // MARK: - Chip selected-text transforms

    /// The compact rewrite actions offered beside the chip. Order and
    /// membership are fixed, so the menu is discoverable and stable; each
    /// entry maps to a saved action by alias, or to the Translator window
    /// (which carries its own target picker rather than hard-coding a
    /// language).
    struct ChipTransformOption: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case saved(UUID)
            case translator
            /// One option of the `{argument}` slot the Transform chooser is
            /// currently filling. The index is into that slot's options.
            case argument(Int)
        }
        let kind: Kind
        let title: String
        let systemImage: String

        var id: String {
            switch kind {
            case .saved(let id): "saved:\(id.uuidString)"
            case .translator: "translator"
            case .argument(let index): "argument:\(index)"
            }
        }
    }

    /// The fixed quick-transform order: alias (or the translator) plus glyph.
    static let chipTransformOrder: [(value: String, image: String)] = [
        ("shorter", "arrow.down.right.and.arrow.up.left"),
        ("bullets", "list.bullet"),
        ("improve", "sparkles"),
        ("tldr", "text.alignleft"),
        ("translate", "character.bubble"),
    ]

    /// The transforms that act on the retained launch selection. Translate
    /// always opens the Translator; the rest resolve to their saved prompt
    /// (so the user's edited name, prompt, and hotkey are honored). Absent
    /// aliases are dropped, so a defunct action simply doesn't appear.
    var chipTransformOptions: [ChipTransformOption] {
        guard selectionTransformSource != nil else { return [] }
        return Self.chipTransformOrder.compactMap { entry in
            if entry.value == "translate" {
                return ChipTransformOption(
                    kind: .translator,
                    title: "Translate",
                    systemImage: entry.image
                )
            }
            guard let action = settings.savedPrompts.first(where: { $0.alias == entry.value }) else {
                return nil
            }
            return ChipTransformOption(
                kind: .saved(action.id),
                title: action.name,
                systemImage: entry.image
            )
        }
    }

    /// Run a transform from the chip menu. Saved actions go through
    /// `performTransform`, which sources from the captured selection snapshot
    /// (not the input field) and previews the result before any write.
    func runChipTransform(_ option: ChipTransformOption) async {
        switch option.kind {
        case .translator:
            openTranslatorWithSelection()
        case .saved(let id):
            guard let action = settings.savedPrompts.first(where: { $0.id == id }) else { return }
            await performTransform(action: action)
        case .argument(let index):
            await chooseTransformArgument(index: index)
        }
    }

    /// Run a quick transform. Always acts on the captured selection snapshot,
    /// never on whatever is typed in the input field, so the rewrite targets
    /// the text the user selected. This is the keyboard-first path for the
    /// Transform chooser and the chip menu.
    func performTransform(action: SavedPrompt) async {
        let label = selectionTransformSourceLabel
        let snapshot = selectionTransformSource
            ?? captureSelectedText(promptForPermission: true)?.text
        guard let snapshot,
              !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            closeActionPalette()
            errorMessage = selectedTextService?.isAccessibilityTrusted == false
                ? "Allow Accessibility in System Settings, then select text and try again."
                : "Select some text first, then run this transform."
            requestInputFocus()
            return
        }
        // One answer at a time: an answer still streaming stops first and
        // keeps what arrived, as Stop does, so the transform never runs a
        // second model request beside it.
        if isStreaming { cancel() }
        isActionPalettePresented = false
        actionQuery = ""
        // A prompt with `{argument …}` slots that offer `options` waits for
        // the chooser; one without collects its defaults and runs at once.
        await beginTransformArguments(action: action, source: snapshot, sourceLabel: label)
    }

    // MARK: - Transform chooser (keyboard-first)

    /// The shortcut that opens/closes the keyboard-first Transform chooser.
    /// `⌘⌥T` (Transform). Deliberately not `⌘⇧D` (owned by the panel's
    /// screenshot-display handler) and not `⌘⇧T` (the translator global
    /// hotkey) — those are consumed before `performShortcut` is reached.
    static let transformChooserShortcut: KeyShortcut = .commandOption("t")

    /// True while the Transform chooser is open (opened by the Transform chip
    /// or its shortcut). ↑↓ move, Return runs, Esc closes. Keyboard-first:
    /// no mouse is needed to reach any transform.
    var isTransformChooserPresented = false {
        didSet { if !isTransformChooserPresented { resumeQueuedFollowUp() } }
    }
    var transformChooserIndex = 0

    /// A saved transform waiting on its `{argument …}` slots. `values` is
    /// positional, matching `slots`; a slot with `options` is offered as a
    /// chooser through the existing Transform chooser pane, and a slot with
    /// only a `default` is filled silently. Nil when nothing is waiting.
    struct PendingTransformArguments: Equatable, Sendable {
        let actionID: UUID
        let alias: String
        let source: String
        /// The source's label ("Clipboard", or an app name), carried to the
        /// review card so an attached source is never attributed to the live
        /// selection.
        let sourceLabel: String?
        let slots: [SnippetArgument]
        var values: [String]
        /// The slot the option chooser is on, or nil.
        var choosing: Int?
        /// The required free-text slot the composer is filling, or nil. A
        /// `{argument …}` with no `default` and no `options` must be typed:
        /// it is never substituted with an empty string.
        var filling: Int?

        var currentSlot: SnippetArgument? {
            guard let choosing, slots.indices.contains(choosing) else { return nil }
            return slots[choosing]
        }

        var fillingSlot: SnippetArgument? {
            guard let filling, slots.indices.contains(filling) else { return nil }
            return slots[filling]
        }
    }

    var pendingTransformArguments: PendingTransformArguments?

    /// The typed text for the required `{argument}` slot the Transform
    /// argument field is asking for. Its own field, so the composer draft is
    /// never touched by an argument.
    var transformArgumentInput = ""

    /// The original text and the proposed result of a `.reviewChanges`
    /// transform, shown before anything is written back.
    ///
    /// `target` is the captured live-selection context the transform actually
    /// ran on, frozen here and set only when the transformed source was that
    /// exact selection. It is nil for a clipboard or otherwise attached
    /// source, so Accept copies the result instead of writing it into an
    /// unrelated app. Accept then runs the same fail-closed live-selection
    /// check as Replace Selection against this frozen target.
    struct PendingTransformReview {
        let original: String
        let proposed: String
        let sourceApp: String?
        let target: SelectedTextContext?
    }

    var pendingTransformReview: PendingTransformReview?

    /// The `{argument}` values collected for the transform about to be
    /// submitted, read once by `prepareRequest` and then cleared. Nil means
    /// the resolved prompt has no argument slots.
    @ObservationIgnored var pendingActionArguments: [String]?

    func openTransformChooser() {
        // A transform is its own model request; it waits for the answer on
        // screen to end, as Add Context does.
        guard !isStreaming, !chipTransformOptions.isEmpty else { return }
        isTransformChooserPresented = true
        transformChooserIndex = 0
        isAssistantChooserPresented = false
        isCaptureChooserPresented = false
        isActionPalettePresented = false
        isApplicationActionPanePresented = false
        isCatalogActionPanePresented = false
        activeItemActionForm = nil
        requestInputFocus()
    }

    func closeTransformChooser() {
        // Closing while filling an argument must drop the abandoned run, or a
        // later Return on a reopened chooser could send it.
        if pendingTransformArguments != nil {
            cancelTransformArguments()
            return
        }
        isTransformChooserPresented = false
        requestInputFocus()
    }

    func toggleTransformChooser() {
        if isTransformChooserPresented { closeTransformChooser() } else { openTransformChooser() }
    }

    func moveTransformChooserSelection(_ delta: Int) {
        let count = transformChooserOptions.count
        guard count > 0 else { return }
        transformChooserIndex = (transformChooserIndex + delta + count) % count
    }

    func runTransformChooserSelection() async {
        let options = transformChooserOptions
        guard options.indices.contains(transformChooserIndex) else { return }
        // Filling an argument: the highlighted option is the value.
        if pendingTransformArguments != nil {
            await chooseTransformArgument(index: transformChooserIndex)
            return
        }
        isTransformChooserPresented = false
        await runChipTransform(options[transformChooserIndex])
    }

    /// Open the Translator with the retained launch selection available to its
    /// "Use selected text" button, so the import survives the focus moving on.
    func openTranslatorWithSelection() {
        input = ""
        errorMessage = nil
        // Hand the retained selection to the presenter seam *before* any
        // dismissal, because dismissing the overlay clears launch-scoped state
        // (and with it `launchSelection`). The presenter passes it to the
        // Translator so "Use selected text" can import it even after focus
        // moves on.
        let retained = selectionTransformSource
        overlayPresenter.openTranslator(retainedSelection: retained)
    }

    func toggleActionPalette() {
        isApplicationActionPanePresented = false
        contextualApplicationID = nil
        isCatalogActionPanePresented = false
        contextualCatalogItemID = nil
        isActionPalettePresented.toggle()
        actionPaletteSubmenu = nil
        actionQuery = ""
        if !isActionPalettePresented { requestInputFocus() }
    }

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

    // MARK: - Quick AI chats

    /// Return on a Chats catalog row: the chat on the Quick AI surface, as
    /// Return in Recent Chats opens it. A stream still running belongs to
    /// the chat being left.
    func continueChatInQuickAI(itemID: String) {
        guard let id = UUID(uuidString: itemID), history.contains(where: { $0.id == id }) else { return }
        if isStreaming { cancel() }
        continueConversation(itemID: itemID)
        openQuickAI()
    }

    func continueConversation(itemID: String) {
        guard let id = UUID(uuidString: itemID) else { return }
        // One chat, one view: a chat the other view has open moves here.
        takeChatFromOtherViews(id)
        closeItemActionPane()
        catalogScope = nil
        inputMode = nil
        loadConversation(id: id)
        lastQuestion = currentConversation?.messages.last(where: { $0.role == .user })?.content
        invalidateLauncherRanking()
        requestInputFocus()
    }

    /// One writer per chat for archive-only metadata. The history is a cache
    /// and the archive is canonical, so writes queue in the order the user
    /// made them and a failure is logged, never hidden.
    private func enqueueArchiveWrite(
        for chatID: UUID,
        _ operation: @escaping @Sendable (ChatArchive) async throws -> Void
    ) {
        let previous = archiveWriteChain[chatID]
        archiveWriteChain[chatID] = Task { [chatArchive] in
            await previous?.value
            guard let chatArchive else { return }
            do {
                try await operation(chatArchive)
            } catch {
                AppLog.persistence.error(
                    "Chat archive write failed for \(chatID.uuidString): \(error.localizedDescription)"
                )
            }
        }
    }

    func togglePinConversation(id: UUID) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].isPinned.toggle()
        if currentConversation?.id == id { currentConversation?.isPinned = history[index].isPinned }
        let pinned = history[index].isPinned
        saveHistory()
        invalidateLauncherRanking()
        // The canonical record is the archive; the history is a cache.
        if chatArchive != nil {
            enqueueArchiveWrite(for: id) { archive in
                try await archive.setPinned(id: id.uuidString, isPinned: pinned)
            }
        }
    }

    func renameConversation(id: UUID, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].customTitle = clean.isEmpty ? nil : clean
        if currentConversation?.id == id { currentConversation?.customTitle = history[index].customTitle }
        let custom = history[index].customTitle
        let titleSource = history[index].titleSource
        saveHistory()
        invalidateLauncherRanking()
        if chatArchive != nil {
            enqueueArchiveWrite(for: id) { archive in
                try await archive.rename(id: id.uuidString, customTitle: custom, titleSource: titleSource)
            }
        }
    }

    func deleteConversation(id: UUID) {
        store.deletedChatIDs.insert(id)
        let deleted = history.filter { $0.id == id }
        history.removeAll { $0.id == id }
        if currentConversation?.id == id {
            forgetAttachments(of: deleted + [currentConversation].compactMap { $0 })
        } else {
            forgetAttachments(of: deleted)
        }
        if currentConversation?.id == id { startNewConversation() }
        saveHistory()
        invalidateLauncherRanking()
        applicationSelectionIndex = 0
        // Delete the canonical record: the tombstone stops a late write from
        // recreating the chat. The delete is owed until it lands, so a quit
        // waits for it and a failure is retried; a chat the user deleted must
        // not survive a quit just because a write failed.
        if chatArchive != nil {
            durability?.registerDeletion(id)
        }
    }

    private func saveHistory() {
        // The canonical archive is the authority for what is kept; the legacy
        // file is only a bounded, rebuildable cache once that archive exists.
        // Without one (a legacy fixture) the old switch still bounds this
        // store, because then it is all there is.
        if chatArchive == nil, !settings.historyEnabled { return }
        guard let historyFileURL else { return }
        QuickHistoryStore.save(history, limit: settings.historyLimit, to: historyFileURL)
    }

    /// ⌘[ / ⌘]: move through recent chats, pinned first.
    func browseConversations(_ delta: Int) {
        let ordered = QuickHistoryStore.ordered(history)
        guard !ordered.isEmpty else { return }
        // History is newest first: positive delta goes to older chats
        // (backwards in time), negative to newer ones. With no chat open,
        // either direction lands on the most recent chat first.
        let currentIndex = ordered.firstIndex { $0.id == currentConversation?.id }
        let next = currentIndex.map { ($0 + delta + ordered.count) % ordered.count } ?? 0
        continueConversation(itemID: ordered[next].id.uuidString)
    }

    /// The thread ends on a question with no answer after it: stopped
    /// before any text arrived, or a provider error.
    var hasUnansweredTurn: Bool { conversationMessages.last?.role == .user }

    /// ⌘R: ask the last question again and replace its answer: the answer
    /// that finished, the partial one a Stop kept, or the error a failure
    /// left. Whatever is typed in the composer stays there.
    func regenerateLastAnswer() async {
        refreshOpenChatFromStore()
        guard !isStreaming,
              var conversation = currentConversation,
              let lastUser = conversation.messages.lastIndex(where: { $0.role == .user })
        else { return }
        let question = conversation.messages[lastUser].content
        let replaced = Array(conversation.messages[lastUser...])
        let previousOutput = output
        let previousError = threadError
        conversation.messages.removeSubrange(lastUser...)
        currentConversation = conversation
        output = ""
        threadError = nil
        // The turn is asked with the attachments it had: its references,
        // read from the session store (pictures included).
        reaskedAttachments = replaced.first?.attachments
        defer { reaskedAttachments = nil }
        await submit(text: question, reasksTurn: true)
        // The ask never went out (no provider, no key): the thread is left
        // as it was, and the bottom line says why.
        if currentConversation?.id == conversation.id,
           currentConversation?.messages.count == conversation.messages.count {
            currentConversation?.messages.append(contentsOf: replaced)
            output = previousOutput
            threadError = previousError
        }
    }

    /// Retry under a failed turn: `⌘R`, from the control.
    func retryFailedTurn() {
        guard retryTask == nil, !isStreaming else { return }
        retryTask = Task { @MainActor [weak self] in
            await self?.regenerateLastAnswer()
            self?.retryTask = nil
        }
    }

    /// Turn a clipboard entry into a snippet or a Quick Link, then open the
    /// new item's editor so the title can be fixed right away.
    private func saveClipboardEntry(_ item: LauncherCatalogItem, asLink: Bool) {
        guard let launcherCatalog else {
            errorMessage = LauncherCatalogError.creationUnsupported.localizedDescription
            requestInputFocus()
            return
        }
        do {
            let created: LauncherCatalogItem
            if asLink {
                let host = URL(string: item.value.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "Link"
                created = try launcherCatalog.createQuickLink(title: host, value: item.value)
            } else {
                created = try launcherCatalog.createSnippet(title: Self.snippetTitle(from: item.value), value: item.value)
            }
            errorMessage = nil
            catalogScope = asLink ? .quickLinks : .snippets
            input = ""
            openActionPane(for: .item(created), form: asLink ? .alias : .edit)
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
        }
    }

    private func revealInFinder(_ application: LaunchableApplication) {
        closeItemActionPane()
        input = ""
        overlayPresenter.dismissOverlay()
        workspace.revealInFileViewer([application.url])
    }

    func closeCatalogActionPane() {
        closeItemActionPane()
    }

    // MARK: - Creating and editing snippets and Quicklinks

    /// "Create Snippet": the ⌘K editor opens on a blank snippet. Nothing is
    /// written until Save.
    func beginCreatingSnippet() {
        beginCreating(kind: .snippet)
    }

    /// "Create Quicklink": the same editor, with an address instead of text.
    func beginCreatingQuicklink() {
        beginCreating(kind: .quickLink)
    }

    private func beginCreating(kind: LauncherItemKind) {
        let isSnippet = kind == .snippet
        let draft = LauncherCatalogItem(
            kind: isSnippet ? .snippet : .quickLink,
            itemID: isSnippet ? Self.draftSnippetID : Self.draftQuickLinkID,
            title: "",
            detail: isSnippet ? "New snippet" : "New Quicklink",
            value: ""
        )
        // A create starts from a clean surface, then lands in the catalog the
        // new item belongs to, so Escape leaves the user among its siblings.
        reset([.layers, .mode, .input])
        draftCatalogItem = draft
        catalogScope = isSnippet ? .snippets : .quickLinks
        openActionPane(for: .item(draft), form: .edit)
        errorMessage = nil
    }

    /// Save in the ⌘K editor. A draft is written to the store as a new item;
    /// anything else is updated in place. The store owns validation, so an
    /// empty name or an address that is not a web link reports its own
    /// message and the form stays open.
    @discardableResult
    func commitItemEdit(_ item: LauncherCatalogItem, title: String, value: String) -> Bool {
        guard let launcherCatalog else {
            errorMessage = LauncherCatalogError.creationUnsupported.localizedDescription
            requestInputFocus()
            return false
        }
        do {
            let saved: LauncherCatalogItem
            if isDraftItem(item) {
                saved = item.kind == .quickLink
                    ? try launcherCatalog.createQuickLink(title: title, value: value)
                    : try launcherCatalog.createSnippet(title: title, value: value)
                draftCatalogItem = nil
            } else if item.kind == .quickLink {
                try launcherCatalog.updateQuickLink(item, title: title, value: value)
                saved = launcherCatalog.quickLinks.first { $0.itemID == item.itemID } ?? item
            } else {
                try launcherCatalog.updateSnippet(item, title: title, value: value)
                saved = launcherCatalog.snippets.first { $0.itemID == item.itemID } ?? item
            }
            errorMessage = nil
            contextualCatalogItemID = saved.id
            activeItemActionForm = nil
            invalidateLauncherRanking()
            noteInteraction()
            return true
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
            return false
        }
    }

    @discardableResult
    func deleteQuickLink(_ item: LauncherCatalogItem) -> Bool {
        do {
            try launcherCatalog?.deleteQuickLink(item)
            removeLauncherItemConfiguration(for: item)
            closeCatalogActionPane()
            applicationSelectionIndex = 0
            errorMessage = nil
            invalidateLauncherRanking()
            noteInteraction()
            return true
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
            return false
        }
    }

    // MARK: - Snippet placeholders

    /// Raycast-style placeholders live inside the snippet's own text, so an
    /// insertion expands them here: `{clipboard}` through the pasteboard
    /// seam, `{date}` and `{time}` from this view model's clock, and
    /// `{argument}` from what the user types when asked. A snippet with no
    /// placeholder takes the same path and comes out unchanged.
    func insertSnippet(
        _ item: LauncherCatalogItem,
        mode: SnippetInsertMode,
        dismissingOverlay: Bool = false
    ) async {
        let slots = SnippetPlaceholders.arguments(in: item.value)
        guard slots.isEmpty else {
            enterInputMode(.snippetArgument)
            pendingSnippetInsertion = PendingSnippetInsertion(
                item: item,
                arguments: slots,
                collected: [],
                mode: mode,
                dismissesOverlay: dismissingOverlay
            )
            return
        }
        await finishSnippetInsertion(
            item,
            arguments: [],
            mode: mode,
            dismissingOverlay: dismissingOverlay
        )
    }

    private func finishSnippetInsertion(
        _ item: LauncherCatalogItem,
        arguments: [String],
        mode: SnippetInsertMode,
        dismissingOverlay: Bool
    ) async {
        var expanded = item
        expanded.value = expandSnippet(item.value, arguments: arguments).text
        switch mode {
        case .paste:
            _ = await pasteLauncherItem(expanded)
        case .copy:
            _ = await copyLauncherItem(expanded)
        case .copyAndPaste:
            _ = await copyAndPasteLauncherItem(expanded)
        }
        guard dismissingOverlay else { return }
        input = ""
        overlayPresenter.dismissOverlay()
    }

    /// The pure expansion with this view model's seams filled in: the
    /// clipboard through `PasteboardWriting`, the time through `now`.
    func expandSnippet(_ template: String, arguments: [String] = []) -> SnippetExpansion {
        SnippetPlaceholders.expand(
            template,
            clipboard: pasteboard.readString(),
            now: now(),
            arguments: arguments
        )
    }

    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) -> Bool {
        do {
            try launcherCatalog?.updateSnippet(item, title: title, value: value)
            errorMessage = nil
            contextualCatalogItemID = launcherCatalog?.snippets.first {
                $0.itemID == item.itemID
            }?.id
            activeItemActionForm = nil
            noteInteraction()
            return true
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
            return false
        }
    }

    func deleteSnippet(_ item: LauncherCatalogItem) -> Bool {
        do {
            try launcherCatalog?.deleteSnippet(item)
            removeLauncherItemConfiguration(for: item)
            closeCatalogActionPane()
            applicationSelectionIndex = 0
            errorMessage = nil
            noteInteraction()
            return true
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
            return false
        }
    }

    func launcherItemAlias(for item: LauncherCatalogItem) -> String {
        settings.launcherItemConfiguration(kind: item.kind, itemID: item.itemID)?.alias ?? ""
    }

    func launcherItemHotkey(for item: LauncherCatalogItem) -> ActionHotkey? {
        // Type to Click predates configurable catalog items. Present its one
        // real global hotkey through the same ⌘K editor instead of creating a
        // second, unrelated launcher-item shortcut.
        if item.itemID == "type-to-click.mode" {
            return settings.typeToClickHotkeyEnabled ? settings.typeToClickHotkey : nil
        }
        return settings.launcherItemConfiguration(kind: item.kind, itemID: item.itemID)?.hotkey
    }

    func setLauncherItemAlias(_ alias: String, for item: LauncherCatalogItem) {
        updateLauncherItemConfiguration(kind: item.kind, itemID: item.itemID) { $0.alias = alias }
    }

    func isLauncherItemPinned(_ item: LauncherCatalogItem) -> Bool {
        settings.launcherItemConfiguration(kind: item.kind, itemID: item.itemID)?.isPinned ?? false
    }

    /// `⌘⇧P` on a snippet, quick link, or screenshot. The pin lives in the
    /// item's configuration record beside its alias and hotkey.
    func togglePinLauncherItem(_ item: LauncherCatalogItem) {
        updateLauncherItemConfiguration(kind: item.kind, itemID: item.itemID) { $0.isPinned.toggle() }
        noteInteraction()
    }

    // MARK: - Provider and model routing

    /// The models a picker may offer for one provider: everything it reports
    /// minus the models turned off on Manage Models. The provider's current
    /// model stays listed so the picker can always render what is selected.
    func visibleModels(for provider: InferenceProvider) -> [String] {
        ModelCatalogService.visibleModels(
            for: provider,
            currentModel: modelInUse(for: provider),
            preferences: modelPreferences
        )
    }

    /// The model the Quick AI surface would send to for this provider.
    private func modelInUse(for provider: InferenceProvider) -> String? {
        guard activeProvider?.id == provider.id else { return provider.selectedModel }
        return chatModelOverride(for: provider) ?? provider.selectedModel
    }

    /// Whether this provider and model are the pair the surface would use
    /// right now; a model picker ticks exactly this row.
    func isActiveModel(provider: InferenceProvider, model: String) -> Bool {
        activeProvider?.id == provider.id && modelInUse(for: provider) == model
    }

    func selectModel(providerID: UUID, model: String) {
        settings.select(providerID: providerID, model: model)
        settings.save()
        modelRefreshMessage = nil
    }

    func selectProvider(providerID: UUID) {
        settings.select(providerID: providerID)
        settings.save()
        modelRefreshMessage = nil
    }

    func setCustomModel(providerID: UUID, model: String) {
        guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else {
            return
        }
        settings.selectedProviderID = providerID
        settings.providers[index].selectedModel = model
        settings.save()
        modelRefreshMessage = nil
    }

    @discardableResult
    func addOpenAICompatibleProvider() -> UUID {
        let provider = InferenceProvider(
            name: "Custom OpenAI endpoint",
            kind: .openAICompatible,
            location: .local,
            baseURL: "http://127.0.0.1:8000/v1",
            discovery: .openAI
        )
        settings.providers.append(provider)
        settings.selectedProviderID = provider.id
        settings.save()
        return provider.id
    }

    func removeProvider(id: UUID) {
        guard let provider = settings.providers.first(where: { $0.id == id }),
              !provider.isBuiltIn
        else { return }
        settings.providers.removeAll { $0.id == id }
        if settings.selectedProviderID == id {
            settings.selectedProviderID = settings.providers.first?.id
                ?? InferenceProvider.deepSeekID
        }
        try? APIKeyStore.delete(providerID: id)
        invalidateAPIKeyPresence()
        settings.save()
    }

    func refreshModels(providerID: UUID) async {
        guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
        let provider = settings.providers[index]
        modelRefreshMessage = "Refreshing \(provider.name)…"
        do {
            let models = try await ModelCatalogService().models(
                for: provider,
                apiKey: apiKeyProvider(provider.id)
            )
            // A provider removed while the request was in flight shifts the
            // indices; find it by id again rather than writing the wrong one.
            guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
            settings.providers[index].models = models
            if settings.providers[index].selectedModel.isEmpty ||
                !models.contains(settings.providers[index].selectedModel) {
                // Land on the first model that is still offered, never on one
                // the user turned off on Manage Models.
                settings.providers[index].selectedModel = Self.refreshFallbackModel(
                    for: settings.providers[index], preferences: modelPreferences
                )
            }
            settings.save()
            modelRefreshMessage = models.isEmpty
                ? "No models found"
                : "Found \(models.count) models"
        } catch {
            modelRefreshMessage = error.localizedDescription
        }
    }

    /// The model a refresh falls back to when the recorded one is gone or
    /// blank: the first model that is still offered, never one the user
    /// turned off on Manage Models.
    static func refreshFallbackModel(
        for provider: InferenceProvider,
        preferences: ModelPreferenceStore = .shared
    ) -> String {
        ModelCatalogService.visibleModels(for: provider, preferences: preferences).first ?? ""
    }

    func refreshDetectedModels() async {
        let ids = settings.providers
            .filter { $0.discovery == .lmStudio || $0.discovery == .pi }
            .map(\.id)
        for id in ids { await refreshModels(providerID: id) }
    }

    func resolvedModel(for provider: InferenceProvider, override: String?) -> String? {
        let model = override.flatMap { $0.isEmpty ? nil : $0 } ?? provider.selectedModel
        return model.isEmpty ? nil : model
    }

    /// The service for the selected provider and model, for the Translator
    /// window. Nil when no usable provider is configured.
    func makeCurrentService() -> (any QuickService)? {
        guard let provider = settings.selectedProvider,
              let model = resolvedModel(for: provider, override: nil)
        else { return nil }
        if service == nil, provider.kind == .openAICompatible, provider.location == .cloud,
           (apiKeyProvider(provider.id) ?? "").isEmpty {
            return nil
        }
        return makeService(provider: provider, model: model, chatTools: false)
    }

    /// The system instruction this surface's request carries on `provider`:
    /// the surface prompt, the grounding sentence when the turn carries a
    /// source, and the assistant's message, composed the way the provider
    /// joins them. The attachment budget and the provider body both read this
    /// one function, so the reserve is the instruction the model reads.
    ///
    /// `assistantInstruction` is the chat's assistant message, which the
    /// provider joins in front of the surface instruction. Pass nil when only
    /// the instruction the service itself carries is wanted, since the
    /// assistant travels on the request's own system message.
    func systemInstruction(
        for provider: InferenceProvider,
        grounded: Bool,
        assistantInstruction: String? = nil
    ) -> String {
        ChatContextGate.systemInstruction(
            surfacePrompt: settings.surfaceSystemPrompt(forChat: isAIChatWindow),
            grounded: grounded,
            lane: provider.kind == .commandLine ? .commandLine : .model,
            assistantInstruction: assistantInstruction
        )
    }

    /// `chatTools` offers the chat's memory and skill tools and lets
    /// the chat's toggle decide web search. The Translator passes false: it
    /// gets web search per the setting and nothing else.
    func makeService(
        provider: InferenceProvider,
        model: String,
        chatTools: Bool = true,
        toolOverride: Set<ChatToolKind>? = nil,
        /// A `.textOnly` saved action offers the model no tools at all,
        /// which is derived here rather than through `toolOverride`.
        textOnly: Bool = false,
        /// True when this turn carries a source. The tools are offered
        /// either way now; this adds the sentence that keeps the answer on
        /// the attached material (`ChatContextGate.groundingDirective`).
        grounded: Bool = false,
        attachmentTrim: ContextBudget.Trim = ContextBudget.Trim(),
        roundRecorder: ChatRoundRecorder? = nil
    ) -> (any QuickService)? {
        if let service { return service }
        // One engine, two surfaces: Quick AI carries the direct overlay
        // instruction, AI Chat its conversational one. Providers, tools,
        // history and attachments stay shared; only this default differs,
        // and a custom instruction is used exactly as written. Both lanes
        // compose their instruction through `systemInstruction(for:grounded:)`
        // so the attachment budget measures the same string.
        switch provider.kind {
        case .openAICompatible:
            guard let url = URL(string: provider.baseURL) else { return nil }
            // A source-grounded request passes the gated set; everything
            // else uses the chat's own offered set. A text-only action gets
            // the empty set no matter what the chat offered.
            let tools = textOnly ? [] : (toolOverride ?? self.chatTools)
            // The model gets a search_web tool so it can look things up
            // mid-answer, using the same provider as explicit searches.
            var webSearch: (@Sendable (String) async throws -> String)?
            let webEnabled = chatTools ? tools.contains(.web) : settings.modelWebSearchEnabled
            if webEnabled, let webSearchService {
                let searchProvider = settings.webSearchProvider
                webSearch = { query in try await webSearchService.search(query, provider: searchProvider) }
            }
            let profile = modelPreferences.profile(providerID: provider.id, model: model)
            // The per-round snapshot hook: the model client hands every
            // request body here before it goes out, so a write failure stops
            // the request. Nil for a service that has no archive (the
            // Translator, and every test that injects its own service).
            var beforeRequest: (@Sendable (ProviderRequestRound) async throws -> Void)?
            if let roundRecorder {
                beforeRequest = { round in
                    try await roundRecorder.beforeRequest(round)
                }
            }
            return OpenAICompatibleService(
                baseURL: url,
                modelName: model,
                apiKey: apiKeyProvider(provider.id),
                systemPrompt: systemInstruction(for: provider, grounded: grounded),
                webSearch: webSearch,
                tools: chatTools && !textOnly
                    ? ChatToolbox(
                        enabled: tools,
                        memory: memoryService,
                        skills: skillLibrary
                    )
                    : ChatToolbox(),
                contextBudget: ContextBudget(contextWindow: profile.contextWindow),
                attachmentTrim: attachmentTrim,
                reasoningEffort: profile.reasoningEffort,
                thinkingSupported: profile.supportsReasoningEffort,
                beforeRequest: beforeRequest
            )
        case .commandLine:
            guard let command = provider.command else { return nil }
            return CommandQuickService(
                configuration: command,
                model: model,
                systemPrompt: systemInstruction(for: provider, grounded: grounded)
            )
        }
    }

    // MARK: - Cancel

    /// Stops a stream as Escape does. Returns whether it kept and saved the
    /// stopped answer; a no-text stop returns false and saves nothing.
    @discardableResult
    func cancel() -> Bool {
        var keptStoppedAnswer = false
        // A running command action has no `streamTask`; a model request does.
        // Only claim a cancellation that really happened: the model lane
        // records here, and the command lane records from `runCommandAction`
        // once `ProcessRunner` confirms the child was terminated.
        let wasStreaming = isStreaming
        let cancelledModelRequest = wasStreaming && streamTask != nil
        // Streaming with the question still pending and nothing else running
        // is the enrichment phase (a web search or page read): the submit
        // itself is what is in flight, and the question was never a turn.
        let cancelledEnrichment = wasStreaming && streamTask == nil && commandTask == nil
            && pendingQuestion != nil
        // A send waiting for its chips: the reads stop, the typed text stays.
        cancelAttachmentWait()
        if cancelledModelRequest {
            // Stop keeps the question and what the model said so far, as the
            // turn's answer; `⌘R` asks the same turn again.
            keptStoppedAnswer = keepStoppedAnswer()
            // A stopped answer is terminal in the archive, never left looking
            // like it is still streaming. Registering here, before this
            // method returns, freezes the write and its own retry payload
            // before any quit can await.
            if let conversation = currentConversation,
               let assistantTurnID = currentAssistantTurnID {
                registerTerminalAnswer(
                    conversationID: conversation.id,
                    turnID: assistantTurnID,
                    status: .cancelled,
                    error: "Stopped by the user",
                    text: output.isEmpty ? nil : output,
                    timings: requestTimings(finishedAt: Date()),
                    usage: streamUsage,
                    toolRounds: streamToolRounds.isEmpty ? nil : streamToolRounds
                )
                if keptStoppedAnswer { persistAnsweredConversation() }
            }
        } else {
            discardStreamBuffer()
            output = ""
        }
        // The stopped stream may still end later; from here it writes nothing.
        streamGeneration &+= 1
        inFlightTurn = nil
        streamTask?.cancel()
        streamTask = nil
        commandTask?.cancel()
        commandTask = nil
        // The submit that started the ask (Tab, or Return in the composer)
        // is still awaiting its search; a stopped ask must not go on to
        // call the model when that await returns.
        tabSubmitTask?.cancel()
        tabSubmitTask = nil
        composerSubmitTask?.cancel()
        composerSubmitTask = nil
        queuedFollowUpTask?.cancel()
        queuedFollowUpTask = nil
        isStreaming = false
        streamingStatus = nil
        // A queued follow-up stays in the composer, unsent.
        isFollowUpQueued = false
        liveToolRecords = []
        if cancelledEnrichment {
            pendingQuestion = nil
            // The search line was made for an answer that will not come.
            webSearchNote = nil
            // The question goes back in the composer now, before whatever
            // the caller does next (Recent Chats or root search may clear
            // it), not when the cancelled search returns later.
            restoreEnrichmentInput()
        }
        guard cancelledModelRequest else { return keptStoppedAnswer }
        recordJournal(kind: .aiCancelled, scope: learningScope, detail: "stopped")
        requestInputFocus()
        return keptStoppedAnswer
    }

    // MARK: - Stream buffering

    func appendStreamText(_ text: String) {
        streamBuffer += text
        if output.isEmpty || ContinuousClock.now - lastStreamFlush >= Self.streamFlushInterval {
            flushStreamBuffer()
        } else if streamFlushTask == nil {
            // A pause between tokens must not hide the last few: flush on a timer.
            streamFlushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.streamFlushInterval)
                guard !Task.isCancelled else { return }
                self?.streamFlushTask = nil
                self?.flushStreamBuffer()
            }
        }
    }

    func flushStreamBuffer() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        guard !streamBuffer.isEmpty else { return }
        output += streamBuffer
        streamBuffer = ""
        lastStreamFlush = .now
    }

    func discardStreamBuffer() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        streamBuffer = ""
    }

    // MARK: - Copy

    /// Auto-copy ("Copy the first answer of each chat automatically") takes
    /// only the first answer of a Quick AI chat. A follow-up never replaces
    /// what the user copied since, and the AI Chat window, where a chat runs
    /// long, never copies on its own. `chatHadAnswer` is whether the chat
    /// already showed an answer when this one was asked.
    func autoCopiesAnswer(chatHadAnswer: Bool) -> Bool {
        settings.autoCopy && !isAIChatWindow && !chatHadAnswer
    }

    /// True while the open chat shows an answer: a saved answer turn, or a
    /// local or command answer drawn under the thread.
    var chatShowsAnswer: Bool {
        !output.isEmpty || currentConversation?.messages.contains { $0.role == .assistant } == true
    }

    /// Copies the answer on screen. Every copy of an AI answer (auto-copy,
    /// Copy Answer, the copy a failed paste falls back to) is transient, so
    /// the Clipboard History and other clipboard managers skip it.
    func copyOutput() {
        guard !output.isEmpty else { return }
        pasteboard.writeTransientString(output)
    }

    func copyOutputAndMark() {
        guard !output.isEmpty else { return }
        copyOutput()
        markJustCopied()
    }

    /// Copy Answer on the Quick AI surface: copy, keep the surface open, and
    /// confirm in the composer.
    func copyAnswerOnSurface() {
        guard !output.isEmpty else { return }
        copyOutputAndMark()
        confirmInComposer("Copied")
        requestInputFocus()
    }

    /// Copy Chat (`⌥⌘C`): the whole thread as a labelled transcript, "You:"
    /// for each question and the model's display name for each answer.
    func copyChatTranscript() {
        guard let conversation = currentConversation, !conversation.messages.isEmpty else { return }
        // A chat is AI answers too: transient, as `copyOutput`.
        pasteboard.writeTransientString(conversation.labelledTranscript)
        markJustCopied()
        confirmInComposer("Chat copied")
        requestInputFocus()
    }

    // MARK: - Continue in pi

    /// The start of the pi line when the hand-off stopped an answer.
    static let piStoppedAnswerPrefix = "Answer stopped. "

    /// Continue in pi (`⌥⌘P`): the thread goes to a new pi session in its
    /// own tmux session, and Ghostty opens on it (`PiHandoffService`). The
    /// surface stays open and the thread ends with a line naming the
    /// session. When Ghostty does not open, the session still runs and the
    /// attach command is copied instead. An answer still streaming stops
    /// first and keeps what arrived, as Escape does; pi gets it, and the
    /// line says the answer was stopped.
    func continueInPi() async {
        isActionPalettePresented = false
        guard piHandoff != nil,
              currentConversation?.messages.isEmpty == false,
              !isHandingOffToPi
        else { return }
        let stoppedAnswer = isStreaming
        if stoppedAnswer {
            cancel()
            // The question too, when no text arrived to save it with.
            persistCurrentConversation()
        }
        guard let piHandoff,
              let conversation = currentConversation,
              !conversation.messages.isEmpty
        else { return }
        isHandingOffToPi = true
        defer { isHandingOffToPi = false }
        errorMessage = nil
        let request = PiHandoffRequest(
            title: title(of: conversation),
            markdown: piHandoffMarkdown(for: conversation),
            workingDirectory: nil
        )
        do {
            let result = try await piHandoff.handOff(request)
            noteFeatureUse(.piHandoffWritten, itemID: "feature:pi-handoff")
            // The line belongs to the chat that was handed off.
            if currentConversation?.id == conversation.id {
                let stopped = stoppedAnswer ? Self.piStoppedAnswerPrefix : ""
                if result.openedGhostty {
                    setThreadNotice(
                        stopped + "Opened in pi · tmux session \(result.sessionName)",
                        symbol: Self.piNoticeSymbol
                    )
                } else {
                    // Plumbing the app wrote, not a copy the user keeps.
                    pasteboard.writeTransientString(result.attachCommand)
                    setThreadNotice(
                        stopped + "Started pi in tmux session \(result.sessionName) · "
                            + "Ghostty did not open, attach command copied",
                        symbol: Self.piNoticeSymbol
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        requestInputFocus()
    }

    /// The thread as pi gets it: every answer with its saved tool lines and
    /// sources. A search line still on screen and not yet saved opens the
    /// answer it was made for: the first answer after the newest question.
    func piHandoffMarkdown(for conversation: QuickConversation, date: Date = Date()) -> String {
        var toolLines: [UUID: [String]] = [:]
        if let note = webSearchNote,
           let lastQuestion = conversation.messages.lastIndex(where: { $0.role == .user }),
           let answer = conversation.messages[lastQuestion...].first(where: { $0.role == .assistant }) {
            toolLines[answer.id] = [note]
        }
        let attachments = attachmentStore
        return PiHandoffDocument.markdown(
            title: title(of: conversation),
            modelName: ModelProfile.displayName(forModelID: conversation.model),
            messages: conversation.messages,
            toolLines: toolLines,
            attachmentText: { attachments.text(for: $0)?.text },
            date: date
        )
    }

    /// Shows `message` with a checkmark in the composer for
    /// `composerConfirmationDuration`. A second copy restarts the clock.
    func confirmInComposer(_ message: String) {
        composerConfirmationTask?.cancel()
        composerConfirmation = message
        composerConfirmationTask = Task { @MainActor [weak self, duration = composerConfirmationDuration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.composerConfirmation = nil
        }
    }

    /// Replace the originally captured selection with the current output.
    /// Only ever called by an explicit user action: a saved action that used a
    /// captured selection leaves its result on screen, then the user picks
    /// Replace Selection (here) or Copy. The captured target and text are
    /// retained across the request, so the write goes back to the snapshot the
    /// action ran on, not the app that happens to be frontmost now. Before
    /// writing we re-read the live selection and fail **closed** to Copy: if the
    /// selection changed or cannot be read at all, we never overwrite what we
    /// cannot confirm is the original, and we say so truthfully.
    @discardableResult
    func replaceOutputInCapturedSelection() async -> Bool {
        guard !output.isEmpty else { return false }
        guard let selectedTextService else { return false }
        guard let context = replaceableSelectionContext else {
            copyOutputAndMark()
            errorMessage = "The current answer did not replace a captured selection. The result was copied instead."
            requestInputFocus()
            return false
        }
        return await writeBackValidated(output: output, in: context, service: selectedTextService)
    }

    /// Shared fail-closed write-back: re-reads the live selection and only
    /// writes when it still matches the captured one. Used by both the explicit
    /// Replace Selection action and a custom `.replaceSelection` saved action's
    /// auto-write, so a stale or unreadable selection is never overwritten.
    /// On any failure it copies the output and reports why, truthfully.
    func writeBackValidated(
        output text: String,
        in context: SelectedTextContext?,
        service selectedTextService: any SelectedTextServicing
    ) async -> Bool {
        guard let context, !text.isEmpty else {
            copyOutputAndMark()
            errorMessage = "Could not replace the selection. The result was copied instead."
            requestInputFocus()
            return false
        }
        // Fail closed: if the live selection cannot be read, we cannot confirm
        // it is still the original, so copy instead of risk overwriting it.
        guard let live = selectedTextService.capture(
            from: context.target,
            promptForPermission: false
        ) else {
            copyOutputAndMark()
            errorMessage = "Could not read the current selection in \(context.target.applicationName). The result was copied instead."
            requestInputFocus()
            return false
        }
        if live.text != context.text {
            copyOutputAndMark()
            errorMessage = "The selection changed. The result was copied instead of replacing."
            requestInputFocus()
            return false
        }
        prepareForExternalAction?()
        await Task.yield()
        let outcome = await selectedTextService.replaceOutcome(text, in: context)
        if outcome == .clipboardChanged {
            errorMessage = Self.clipboardChangedMessage
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        guard outcome == .pasted else {
            copyOutputAndMark()
            errorMessage = selectedTextService.isAccessibilityTrusted
                ? "Could not replace the selection in \(context.target.applicationName). The result was copied instead."
                : "Allow Accessibility in System Settings, then try again. The result was copied."
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        overlayPresenter.dismissOverlay()
        return true
    }

    @discardableResult
    func pasteOutputToPreviousApp() async -> Bool {
        guard !output.isEmpty else { return false }
        guard let selectionTarget, let selectedTextService else {
            // Nothing to paste into: copy, as every other failure here does,
            // so the answer is never trapped on screen with no way out.
            copyOutputAndMark()
            errorMessage = "Open Quick Launch from the app where you want to paste. The result was copied instead."
            requestInputFocus()
            return false
        }
        let outcome = await selectedTextService.pasteOutcome(output, to: selectionTarget)
        if outcome == .clipboardChanged {
            errorMessage = Self.clipboardChangedMessage
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        guard outcome == .pasted else {
            copyOutputAndMark()
            errorMessage = "Could not paste into \(selectionTarget.applicationName). The result was copied instead."
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        overlayPresenter.dismissOverlay()
        return true
    }

    /// Paste Formatted Response (`⌃⌘V`): publish the answer's plain, HTML and
    /// RTF representations on the pasteboard and press ⌘V in the app behind.
    ///
    /// The rich path never uses the accessibility insert-at-caret text write,
    /// which only carries a string and would drop the formatting; the
    /// pasteboard plus ⌘V is what preserves it. When the answer is plain prose
    /// with no structure to keep, or a rich representation could not be built,
    /// it falls back to the ordinary plain paste, so the action never fails
    /// just because there was nothing rich to carry. Either way the answer is
    /// on the clipboard first, one manual ⌘V away.
    @discardableResult
    func pasteFormattedOutputToPreviousApp() async -> Bool {
        guard !output.isEmpty else { return false }
        let representation = FormattedPasteBuilder.representation(fromMarkdown: output)
        guard let selectionTarget, let selectedTextService else {
            // Nothing to paste into: publish the rendered text transiently and
            // say so, rather than dropping the answer.
            pasteboard.writeTransientString(representation.plainText)
            markJustCopied()
            errorMessage = "Open Quick Launch from the app where you want to paste. The result was copied instead."
            requestInputFocus()
            return false
        }
        guard representation.prefersRichPaste else {
            // No structure to preserve: the plain path is the honest one.
            let outcome = await selectedTextService.pasteOutcome(representation.plainText, to: selectionTarget)
            if outcome == .clipboardChanged {
                errorMessage = Self.clipboardChangedMessage
                recoverFromExternalActionFailure?()
                requestInputFocus()
                return false
            }
            guard outcome == .pasted else {
                pasteboard.writeTransientString(representation.plainText)
                markJustCopied()
                errorMessage = "Could not paste into \(selectionTarget.applicationName). The result was copied instead."
                recoverFromExternalActionFailure?()
                requestInputFocus()
                return false
            }
            overlayPresenter.dismissOverlay()
            return true
        }
        // The rich types are published transiently so a clipboard manager
        // skips the paste plumbing; ⌘V is the only insertion path here.
        pasteboard.writeTransientFormatted(representation)
        let outcome = await selectedTextService.pastePasteboardOutcome(to: selectionTarget)
        if outcome == .clipboardChanged {
            errorMessage = Self.clipboardChangedMessage
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        guard outcome == .pasted else {
            pasteboard.writeTransientString(representation.plainText)
            markJustCopied()
            errorMessage = "Could not paste into \(selectionTarget.applicationName). The result was copied instead."
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        overlayPresenter.dismissOverlay()
        return true
    }

    /// Shown when a paste was skipped because the user copied something else
    /// first. The answer is not copied over their newer copy.
    static let clipboardChangedMessage =
        "Clipboard changed, so the paste was skipped. The answer is still in Quick Launch."

    /// What Return on an empty composer does with a finished answer: the
    /// Primary Action setting in the launcher; always Copy in the AI Chat
    /// window, which has no app behind it to paste into.
    var primaryAnswerAction: QuickAIPrimaryAction {
        isAIChatWindow ? .copyToClipboard : settings.quickAIPrimaryAction
    }

    /// Return with an empty composer on a finished answer runs the Quick AI
    /// primary action. Automatic copy is untouched: `autoCopy` still decides
    /// what happens the moment an answer arrives.
    func runPrimaryAnswerAction() async {
        guard !output.isEmpty, !isStreaming else { return }
        switch primaryAnswerAction {
        case .pasteToActiveApp:
            // Fails safe: it copies and explains when there is no target.
            _ = await pasteOutputToPreviousApp()
        case .copyToClipboard:
            copyAnswerOnSurface()
        }
    }

    // MARK: - Just-copied flash

    func markJustCopied() {
        justCopiedTask?.cancel()
        justCopied = true
        justCopiedTask = Task { @MainActor [weak self, timeout = justCopiedTimeout] in
            try? await Task.sleep(for: timeout)
            // A second copy cancelled this task and started a new flash: the
            // old task must not clear the new one.
            guard !Task.isCancelled else { return }
            self?.justCopied = false
        }
    }

    /// The save counterpart of `markJustCopied`: a short launcher flash that
    /// a capture landed in the Screenshots folder.
    func markJustSaved() {
        justSavedTask?.cancel()
        justSaved = true
        justSavedTask = Task { @MainActor [weak self, timeout = justCopiedTimeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.justSaved = false
        }
    }

    // MARK: - Clear

    func clearOutput() {
        output = ""
        errorMessage = nil
    }

    /// Which part of the overlay a reset clears. Every "leave", "clear",
    /// or "start over" path goes through `reset(_:)` so nothing is forgotten.
    struct ResetScope: OptionSet, Sendable {
        let rawValue: UInt8
        /// ⌘K pane, palette, sub-form, delete arming, action query.
        static let layers = ResetScope(rawValue: 1 << 0)
        /// Catalog, Quick Link input, input mode.
        static let mode = ResetScope(rawValue: 1 << 1)
        /// Attachments and screen-awareness context.
        static let attachments = ResetScope(rawValue: 1 << 2)
        /// The answer thread: stream, output, conversation, last question.
        static let thread = ResetScope(rawValue: 1 << 3)
        /// Typed text and the selection index.
        static let input = ResetScope(rawValue: 1 << 4)
        static let all: ResetScope = [.layers, .mode, .attachments, .thread, .input]
    }

    func reset(_ scope: ResetScope, cancelingSubmitTasks: Bool = true) {
        // Leaving the surface or clearing the field: a follow-up held behind
        // a layer is not sent when the layers below close.
        if !scope.isDisjoint(with: [.mode, .input]) { isFollowUpQueued = false }
        if scope.contains(.layers) {
            presentedLayer = nil
            actionPaletteSubmenu = nil
            contextualApplicationID = nil
            contextualCatalogItemID = nil
            activeItemActionForm = nil
            deleteArmedItemID = nil
            actionQuery = ""
            clearTransformFlowState()
        }
        if scope.contains(.mode) {
            catalogIdleResetTask?.cancel()
            isQuickAIPresented = false
            isRecentChatsPresented = false
            catalogScope = nil
            pendingQuickLinkID = nil
            inputMode = nil
            pendingSnippetInsertion = nil
            pendingHouseCommandText = nil
            pendingHouseChoice = nil
            draftCatalogItem = nil
        }
        if scope.contains(.attachments) {
            pendingImages.removeAll()
            pendingContext = nil
            attachmentTray.removeAll()
            clearLaunchScopedState()
        }
        if scope.contains(.thread) {
            // A stream still running belongs to the thread being cleared, as
            // do the command and queued-follow-up tasks: a command result
            // must not land in a just-cleared chat. The submit tasks are
            // cancelled too, unless the reset is running inside one (the
            // new-chat path in `stream`).
            streamGeneration &+= 1
            inFlightTurn = nil
            // A clear waiting on this turn goes with the thread it described.
            isTransientClearDeferred = false
            streamTask?.cancel()
            streamTask = nil
            commandTask?.cancel()
            commandTask = nil
            if cancelingSubmitTasks {
                tabSubmitTask?.cancel()
                tabSubmitTask = nil
                composerSubmitTask?.cancel()
                composerSubmitTask = nil
            }
            queuedFollowUpTask?.cancel()
            queuedFollowUpTask = nil
            discardStreamBuffer()
            isStreaming = false
            streamingStatus = nil
            output = ""
            answerSource = .model
            threadError = nil
            isFollowUpQueued = false
            isThreadFollowingBottom = true
            errorMessage = nil
            lastQuestion = nil
            pendingQuestion = nil
            enrichmentSubmittedInput = nil
            webSearchNote = nil
            liveToolRecords = []
            pendingChatTools = nil
            pendingModelChoice = nil
            threadNotice = nil
            replaceableSelectionContext = nil
            clearTransformFlowState()
            currentConversation = nil
            reattachStates = [:]
        }
        if scope.contains(.input) {
            input = ""
            // A local answer is what was typed, answered; it goes with it.
            rootAnswer = nil
            errorMessage = nil
            applicationSelectionIndex = 0
        }
    }

    /// Back to the root surface, like a fresh open. The conversation is
    /// kept so a reopened overlay can still browse to it; only what was on
    /// screen goes.
    ///
    /// A model answer still streaming owns its text until the turn ends.
    /// Clearing here would drop the prefix already shown while the stream
    /// goes on appending, so the saved answer would be its tail alone; the
    /// clear therefore waits for the turn (`runDeferredTransientClear`).
    func clearTransientDisplay() {
        guard !isStreaming else {
            isTransientClearDeferred = true
            return
        }
        performTransientDisplayClear()
    }

    /// A dismissal asked for the surface to be cleared while a model answer
    /// was still streaming. The request keeps the surface as it is until the
    /// turn finishes, then this runs the clear the dismissal asked for.
    var isTransientClearDeferred = false

    /// The reader came back to the panel before the deferred clear ran (the
    /// overlay reopens inside its retention window): the surface stays.
    func cancelDeferredTransientClear() {
        isTransientClearDeferred = false
    }

    /// The turn settled: run a clear a dismissal left waiting. Nothing else
    /// is on screen by then, so this is the ordinary transient clear.
    func runDeferredTransientClear() {
        guard isTransientClearDeferred else { return }
        performTransientDisplayClear()
    }

    private func performTransientDisplayClear() {
        isTransientClearDeferred = false
        reset([.layers, .mode, .attachments, .input])
        clearOutput()
        lastQuestion = nil
    }

    /// Overlay open: offer a clipboard image once per copy. A clipboard the
    /// user already saw (or dismissed) is not re-attached, and a non-image
    /// clipboard never clears an attachment retained for follow-ups.
    func captureImageFromClipboard(from pasteboard: NSPasteboard = .general) {
        // A fresh image belongs in history while browsing a catalog. Offering
        // it as an AI attachment here discarded the retained history panel.
        guard catalogScope == nil else { return }
        guard let fresh = ClipboardImageReader.attachmentIfFresh(from: pasteboard) else { return }
        pendingImage = fresh
        errorMessage = nil
        catalogScope = nil
        pendingQuickLinkID = nil
        applicationSelectionIndex = 0
    }

    /// Backspace: drop the newest attachment; the × button clears all.
    func removePendingImage() {
        if attachmentTray.removeNewest() {
            requestInputFocus()
            return
        }
        if pendingImages.count > 1 {
            pendingImages.removeLast()
            return
        }
        pendingImages.removeAll()
        pendingContext = nil
        requestInputFocus()
    }

    // MARK: - Recent Chats (⌘P)

    /// `⌘P`: the recent chat list in place of the thread, inside the same
    /// Quick AI window. One column; `↑↓` move, `↩` opens, `esc` returns to
    /// the thread. P for past chats: `⌘J` became Open in AI Chat
    /// (Raycast's key) in v1.5.0, and `⌘P` was free in every key table
    /// (`⇧⌘P` is Pin, `⌥⌘P` is Continue in pi). In the AI Chat window the
    /// same key opens the chat list.
    static let recentChatsShortcut: KeyShortcut = .command("p")

    /// Recent Chats has something to list.
    var canOpenRecentChats: Bool { !history.isEmpty || currentConversation != nil }

    /// Opens Recent Chats. The thread, the model, and any attachments are
    /// already in state, so they carry over untouched; this only changes
    /// what is drawn.
    func openRecentChats() {
        guard canOpenRecentChats else {
            errorMessage = "No chats yet. Ask a question first."
            requestInputFocus()
            return
        }
        // The same entry as Tab: a catalog, an input mode, or a Quick Link
        // input steps aside so the composer's Return asks.
        openQuickAI()
        isRecentChatsPresented = true
        isModelChooserPresented = false
        isCaptureChooserPresented = false
        isAddContextMenuPresented = false
        // The composer is the list's search field now; a half-typed
        // follow-up would filter the list, so the list opens on all chats.
        // A queued follow-up leaves the field with it, so it is not queued.
        isFollowUpQueued = false
        input = ""
        recentChatsIndex = currentConversation
            .flatMap { conversation in
                recentChatItems.firstIndex { $0.itemID == conversation.id.uuidString }
            } ?? 0
        requestInputFocus()
    }

    /// Back to the thread. The search text belonged to the list, so it goes
    /// with it rather than becoming a follow-up.
    func closeRecentChats() {
        guard isRecentChatsPresented else { return }
        isRecentChatsPresented = false
        input = ""
        requestInputFocus()
    }

    /// Escape in Recent Chats: typed search text clears first, as in every
    /// catalog, then the list closes.
    private func popRecentChatsLayer() {
        if input.isEmpty {
            closeRecentChats()
        } else {
            input = ""
            recentChatsIndex = 0
            requestInputFocus()
        }
    }

    func toggleRecentChats() {
        if isRecentChatsPresented {
            closeRecentChats()
        } else {
            openRecentChats()
        }
    }

    /// The rows of Recent Chats: the launcher's own chat rows (the Chats
    /// catalog), pinned first, newest next, narrowed by the composer text
    /// while the list is up. `recentChatsIndex` indexes this list, so the
    /// keys and the drawn rows agree.
    var recentChatItems: [LauncherCatalogItem] {
        chatItems(matching: isRecentChatsPresented ? input : "")
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

    /// The composer's text changed on the Quick AI surface. In Recent Chats
    /// it is the search, so typing moves the highlight to the first match
    /// (a search cleared by opening or Escape keeps the highlight it set);
    /// elsewhere a typed `@` opens Add Context.
    func quickAIComposerDidChange(_ newValue: String, allowsContextTrigger: Bool = true) {
        noteInteraction()
        // A queued follow-up cleared from the field is no longer queued.
        if isFollowUpQueued, newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isFollowUpQueued = false
        }
        if isRecentChatsPresented {
            if !newValue.isEmpty { recentChatsIndex = 0 }
        } else {
            if allowsContextTrigger { addContextTriggerDidChange(newValue) }
            // The `/` palette opens on the character and narrows as the
            // name is typed, so it is evaluated on every change, not only
            // on the keystroke that opened it.
            slashCommandTriggerDidChange(newValue)
        }
    }

    func moveRecentChatsSelection(_ delta: Int) {
        let count = recentChatItems.count
        guard count > 0 else { return }
        recentChatsIndex = ListSelection.wrappedIndex(
            recentChatsIndex,
            by: delta,
            count: count
        )
    }

    /// Return in Recent Chats: open the highlighted chat in the thread and
    /// clear the search text. A search with no match keeps the list up.
    func openSelectedRecentChat() {
        let items = recentChatItems
        guard items.indices.contains(recentChatsIndex) else {
            if input.isEmpty { closeRecentChats() }
            return
        }
        // A stream still running belongs to the chat being left.
        if isStreaming { cancel() }
        continueConversation(itemID: items[recentChatsIndex].itemID)
        isRecentChatsPresented = false
        input = ""
        requestInputFocus()
    }

    // MARK: - Collapsed transcript messages

    /// `⌘⇧M`: expand or collapse the newest long message in the transcript,
    /// for a reader who never leaves the composer. The control under the
    /// message carries the same key caps.
    /// `⇧⌘M`: expand or collapse the newest long message in the transcript,
    /// for a reader who never leaves the composer. The control under the
    /// message carries the owner's resolved caps (`shortcutKeyCaps`), so a
    /// rebind reaches both the key and the caps under the message.
    static let transcriptCollapseShortcut: KeyShortcut = .commandShift("m")

    /// Message ids the reader expanded out of the collapsed state. A message
    /// is collapsed when it is long enough and its id is not in here.
    var expandedTranscriptMessageIDs: Set<UUID> = []

    /// What the thread draws for one message. Only a user turn collapses;
    /// an answer always shows in full, as in Raycast.
    func collapseState(for message: QuickMessage) -> MessageCollapseState {
        MessageCollapseState(
            text: message.content,
            isExpanded: expandedTranscriptMessageIDs.contains(message.id),
            collapses: message.role == .user
        )
    }

    /// The newest turn that has a Show more control, the one the keyboard
    /// shortcut acts on. The thread shows every message.
    var keyboardToggleMessageID: UUID? {
        conversationMessages.last { collapseState(for: $0).isCollapsible }?.id
    }

    /// Whether this turn's Show more or Collapse control shows the `⇧⌘M`
    /// key caps: only the turn the key acts on does, so an older pill never
    /// names a key that would fold a different message.
    func showsCollapseShortcut(for message: QuickMessage) -> Bool {
        message.id == keyboardToggleMessageID
    }

    /// Toggles one collapsible turn between collapsed and expanded and asks
    /// the thread to bring its head to the top of the view, so the reader
    /// lands on the start of what opened or next to Show more after it
    /// folds. Returns `false` when the id is not a collapsible turn of the
    /// open conversation.
    @discardableResult
    func toggleTranscriptMessage(_ id: UUID) -> Bool {
        guard let message = conversationMessages.first(where: { $0.id == id }),
              collapseState(for: message).isCollapsible
        else { return false }
        if expandedTranscriptMessageIDs.contains(id) {
            expandedTranscriptMessageIDs.remove(id)
        } else {
            expandedTranscriptMessageIDs.insert(id)
        }
        scrollThread(.messageTop(id))
        noteInteraction()
        return true
    }

    // MARK: - Thread scrolling

    /// Asks the thread to scroll. Moving up (a page, the top, a message's
    /// head) stops following the newest text at once, so a streaming
    /// answer does not pull the reader back before the view has moved;
    /// the bottom starts following again.
    func scrollThread(_ target: ThreadScrollRequest.Target) {
        switch target {
        case .bottom: isThreadFollowingBottom = true
        case .top, .pageUp, .messageTop, .messageOffset: isThreadFollowingBottom = false
        case .pageDown: break
        }
        threadScrollRequest = ThreadScrollRequest(
            target: target,
            revision: (threadScrollRequest?.revision ?? 0) + 1
        )
    }

    /// How far the thread's view last sat from the bottom, as the view
    /// reported it. What the follow rule was decided on; tests read it.
    @ObservationIgnored private(set) var lastThreadDistanceFromBottom: CGFloat?

    /// A new question, or another chat: the thread follows the newest text
    /// again, wherever the reader had scrolled.
    func followThreadBottom() {
        if !isThreadFollowingBottom { isThreadFollowingBottom = true }
    }

    /// The thread's view reported where it sits. When the view moved (the
    /// reader scrolled, or a scroll the thread made landed), within
    /// `threadFollowThreshold` of the bottom it follows the newest text and
    /// further up it stays where the reader is. Text landing under a still
    /// view (`moved` false) changes the distance, never the choice.
    func threadDidScroll(distanceFromBottom: CGFloat, moved: Bool = true) {
        lastThreadDistanceFromBottom = distanceFromBottom
        let follows = distanceFromBottom <= Self.threadFollowThreshold
        // Nothing below the view is always "at the bottom", moved or not: room
        // reserved under a new question can settle without a scroll event.
        guard moved || follows else { return }
        if isThreadFollowingBottom != follows { isThreadFollowingBottom = follows }
    }

    /// The "Latest" chip: the reader scrolled up from a thread with
    /// something below. Clicking it, or `⌘↓`, goes back to the newest text.
    var showsJumpToLatest: Bool {
        guard isQuickAIPresented, !isRecentChatsPresented, !isThreadFollowingBottom else { return false }
        return !conversationMessages.isEmpty || isStreaming || !output.isEmpty
    }

    /// The keys that move the thread from the composer: PageUp and
    /// PageDown, or `⌥↑` and `⌥↓`, by a page; `⌘↑` and `⌘↓` to the top and
    /// the bottom. Only on the thread, with no chooser, card, list, or pane
    /// over it; elsewhere the keys keep their meaning.
    enum ThreadKey: Sendable {
        case up
        case down
        case pageUp
        case pageDown
    }

    @discardableResult
    func handleThreadKey(_ key: ThreadKey, command: Bool, option: Bool) -> Bool {
        guard isQuickAIPresented, !isRecentChatsPresented,
              !isTransformChooserPresented, !isModelChooserPresented, !isAddContextMenuPresented,
              !isActionPalettePresented, !isItemActionPanePresented
        else { return false }
        let target: ThreadScrollRequest.Target
        switch key {
        case .pageUp: target = .pageUp
        case .pageDown: target = .pageDown
        case .up where command: target = .top
        case .down where command: target = .bottom
        case .up where option: target = .pageUp
        case .down where option: target = .pageDown
        case .up, .down: return false
        }
        scrollThread(target)
        return true
    }

    /// Plain `↑` or `↓` in the Quick AI composer, once the question card,
    /// the choosers, and Recent Chats have had their turn. On an empty
    /// composer `↑` puts the last question back in it to edit and send
    /// again, as in Raycast, and `↓` does nothing; with text in the field
    /// both keys are the field's. Chats switch with `⌘[` and `⌘]`.
    @discardableResult
    func handleComposerArrow(_ delta: Int) -> Bool {
        guard isQuickAIPresented, input.isEmpty else { return false }
        if delta < 0 { recallLastQuestion() }
        return true
    }

    /// The last question asked on the surface, as it was typed when this
    /// session knows it, else as the thread holds it.
    var lastAskedQuestion: String? {
        if let lastQuestion, !lastQuestion.isEmpty { return lastQuestion }
        let question = conversationMessages.last { $0.role == .user }?.content
        return question?.isEmpty == false ? question : nil
    }

    private func recallLastQuestion() {
        guard let question = lastAskedQuestion else { return }
        input = question
        requestInputFocus()
    }

    /// The header's model line: opens the model chooser to change the model
    /// for the next message, or closes it when it is already open.
    func toggleModelChooserFromHeader() {
        if isModelChooserPresented {
            closeModelChooser()
        } else {
            openModelChooser(.change)
        }
    }

    // MARK: - Lightweight follow-up history

    /// Whether the next question starts a fresh chat. "Always" and "Never"
    /// are not windows: one starts a new chat every time, the other keeps the
    /// thread until the user starts a new chat by hand. The AI Chat window
    /// is a chat you come back to: a follow-up there always stays in it.
    var shouldStartNewConversation: Bool {
        guard !isAIChatWindow, let conversation = currentConversation else { return false }
        // A picked assistant with nothing asked yet is the chat the next
        // question starts, however long ago it was picked.
        if conversation.messages.isEmpty, conversation.assistantID != nil { return false }
        let updatedAt = conversation.updatedAt
        switch settings.newChatInterval {
        case .always:
            return true
        case .never:
            return false
        case let option:
            guard let minutes = option.minutes else { return false }
            return now().timeIntervalSince(updatedAt) > Double(minutes) * 60
        }
    }

    func loadHistory() {
        // With the canonical archive present the archive is the authority: a
        // legacy "Keep chat history" switch or "Chats to keep" count no
        // longer decides what is read or kept. Their keys stay in the
        // settings blob for rollback, but they gate only the legacy cache.
        if chatArchive != nil {
            loadCanonicalHistory()
            return
        }
        guard settings.historyEnabled, let historyFileURL else {
            history = []
            return
        }
        switch QuickHistoryStore.loadResult(from: historyFileURL) {
        case .loaded(let legacy):
            history = legacy
        case .missing:
            history = []
        case .corrupt:
            // A damaged legacy cache is rollback evidence: never read as
            // empty and never overwritten.
            AppLog.persistence.error("Chat history cache is damaged; keeping it as rollback data.")
            history = []
        }
    }

    /// Reads the canonical archive as the chat list, whatever the legacy
    /// retention settings say.
    private func loadCanonicalHistory() {
        // The legacy file is read once, as a migration source, and never as
        // the authority. A damaged one defers to the archive.
        var legacy: [QuickConversation] = []
        if let historyFileURL, case .loaded(let cached) = QuickHistoryStore.loadResult(from: historyFileURL) {
            legacy = cached
        }
        cutoverToArchive(legacy: legacy)
    }

    /// The one-time cutover to the durable archive. The legacy cache is
    /// backed up for rollback, its chats are imported (idempotent), and the
    /// migration must be clean and verified readable before the archive
    /// becomes the canonical, unbounded list. The legacy file is left in
    /// place and is only ever rewritten as a bounded cache.
    func cutoverToArchive(legacy: [QuickConversation]) {
        guard let chatArchive else { return }
        let appVersion = currentVersion
        let historyFileURL = historyFileURL
        let limit = settings.historyLimit
        Task { [weak self] in
            guard let self else { return }
            do {
                if let historyFileURL {
                    _ = try QuickHistoryStore.backupForRollback(from: historyFileURL)
                }
                let report = await chatArchive.migrate(legacy: legacy, appVersion: appVersion)
                guard report.isClean else {
                    AppLog.persistence.error(
                        "Chat archive migration was not clean: \(report.failures.joined(separator: "; "))"
                    )
                    return
                }
                // Verified readable. Damaged records are surfaced, never
                // silently dropped, and the cache is not rewritten from a
                // partial list.
                let projection = try await chatArchive.projectReadable()
                self.history = QuickHistoryStore.ordered(QuickHistoryStore.droppingRetired(projection.conversations))
                self.archiveDamagedCount = projection.damaged.count
                if projection.damaged.isEmpty, let historyFileURL {
                    QuickHistoryStore.rebuildCache(self.history, limit: limit, to: historyFileURL)
                } else if !projection.damaged.isEmpty {
                    AppLog.persistence.error(
                        "Chat archive has \(projection.damaged.count) unreadable records; the cache was left untouched."
                    )
                }
                AppLog.persistence.info(
                    "Chat archive cutover: \(report.imported) imported, \(report.alreadyPresent) already present, \(projection.conversations.count) canonical"
                )
            } catch {
                AppLog.persistence.error("Chat archive cutover failed: \(error.localizedDescription)")
            }
        }
    }

    func startNewConversation(cancelingSubmitTasks: Bool = true) {
        expandedTranscriptMessageIDs.removeAll()
        reset([.thread, .input], cancelingSubmitTasks: cancelingSubmitTasks)
        requestInputFocus()
    }
    /// Confirmed deletion of every saved chat.
    ///
    /// The view calls this **only** after the user confirms in the delete
    /// alert; it is never inferred from a toggle, never run at startup, and
    /// never runs twice at once. It stops requests that are in flight or still
    /// being prepared first, so nothing prepared before the deletion can write
    /// a chat back into the store, then tombstones and removes every owned
    /// chat and reclaims the bytes no record still references.
    ///
    /// A failure is `savedHistoryOperationError` and the list is left as it
    /// was: the canonical archive preflights every record, so "could not read
    /// one chat" never turns into "deleted everything".
    func clearHistory() {
        guard !isClearingHistory else { return }
        savedHistoryOperationError = nil
        guard let chatArchive else {
            clearLegacyHistory()
            return
        }
        // Nothing prepared or streaming may write into the store we are
        // emptying. `cancel()` also keeps the text that already arrived.
        cancel()
        cancelAttachmentWait()
        isClearingHistory = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await chatArchive.deleteAll()
                if report.isComplete {
                    self.applyClearedHistory()
                    self.savedHistoryOperationError = report.gcIssue.map {
                        "Saved chats were deleted, but their stored files could not all be reclaimed: \($0)"
                    }
                } else {
                    self.savedHistoryOperationError =
                        "Some saved chats could not be deleted (\(report.failedIDs.count)). Nothing else was removed."
                    self.refreshHistoryFromArchive()
                }
            } catch {
                // Fail closed: nothing was deleted, so the list stays.
                self.savedHistoryOperationError = "Could not delete saved chats: \(error.localizedDescription)"
            }
            self.isClearingHistory = false
            self.requestInputFocus()
        }
    }

    /// The legacy store when no canonical archive exists: this is all there
    /// is, and the old retention settings still bound it.
    private func clearLegacyHistory() {
        store.deletedChatIDs.formUnion(history.map(\.id))
        history = []
        // The attachments' text goes with the chats: it lived in memory only.
        attachmentStore.removeAll()
        currentConversation = nil
        if let historyFileURL { QuickHistoryStore.clear(from: historyFileURL) }
        output = ""
        errorMessage = nil
    }

    /// Everything the deletion removed, as the UI now shows it.
    private func applyClearedHistory() {
        store.deletedChatIDs.formUnion(history.map(\.id))
        history = []
        archiveDamagedCount = 0
        attachmentStore.removeAll()
        currentConversation = nil
        if let historyFileURL { QuickHistoryStore.clear(from: historyFileURL) }
        output = ""
        errorMessage = nil
    }

    /// After a partial failure: the list is exactly what the archive still
    /// holds, so the user is not shown a chat that is gone or hidden from one
    /// that is not.
    private func refreshHistoryFromArchive() {
        guard let chatArchive else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let projection = try? await chatArchive.projectReadable() else { return }
            self.history = QuickHistoryStore.ordered(QuickHistoryStore.droppingRetired(projection.conversations))
            self.archiveDamagedCount = projection.damaged.count
        }
    }

    func loadConversation(id: UUID) {
        guard let conversation = history.first(where: { $0.id == id }) else { return }
        loadConversation(conversation)
    }

    /// Puts a chat on the thread: the stored copy (`loadConversation(id:)`),
    /// or the one a hand-off carried when history is off.
    func loadConversation(_ conversation: QuickConversation) {
        currentConversation = conversation
        // A new chat starts from the policy's own decision, not the one
        // chat's override.
        contextOverride = nil
        openChatBase = history.first { $0.id == conversation.id }.map(StoredChatStamp.init)
        expandedTranscriptMessageIDs.removeAll()
        output = conversation.messages.last(where: { $0.role == .assistant })?.content ?? ""
        // The chat answers on its own model (`chatModelChoice`); opening it
        // leaves the Quick AI default and the other window alone.
        pendingModelChoice = nil
        errorMessage = nil
        threadError = nil
        answerSource = .model
        // The finished-search line belongs to the answer it was made for,
        // as does a question that never became a turn, and the hand-off
        // line to the chat it was for.
        webSearchNote = nil
        liveToolRecords = []
        threadNotice = nil
        pendingQuestion = nil
        input = ""
        // Another chat opens where it was left, or on its newest turn.
        if let anchor = threadAnchors.anchor(for: conversation.id),
           conversation.messages.contains(where: { $0.id == anchor.messageID }) {
            isThreadFollowingBottom = false
            openingAnchor = (conversation.id, anchor)
        } else {
            openingAnchor = nil
            threadAnchors.record(nil, for: conversation.id)
            followThreadBottom()
        }
        resumeRetainedAttachments(for: conversation)
    }

    /// Loads a reopened chat's attachment text and images back into the
    /// session store from the durable archive, so a follow-up or a reopen
    /// works without re-reading a source that may have changed. The archive
    /// is the only source here; a role that was never archived stays missing
    /// and is never fetched again.
    func resumeRetainedAttachments(for conversation: QuickConversation) {
        guard chatArchive != nil else { return }
        let refs = conversation.messages.flatMap(\.attachmentRefs)
        let conversationID = conversation.id.uuidString
        Task { [weak self] in
            guard let self, let chatArchive = self.chatArchive else { return }
            // A turn in flight when the app quit is marked interrupted, so it
            // never reads as still streaming in the archive.
            if let record = try? await chatArchive.load(id: conversationID) {
                for turn in record.turns where turn.role == .assistant {
                    let status = turn.request?.status
                    if status == .streaming || status == .pending {
                        do {
                            _ = try await chatArchive.failTurn(
                                conversationID: conversationID,
                                turnID: turn.id,
                                error: "Interrupted before completion",
                                status: .cancelled,
                                text: turn.text.isEmpty ? nil : turn.text
                            )
                        } catch {
                            AppLog.persistence.error(
                                "Chat archive interrupt write failed: \(error.localizedDescription)"
                            )
                        }
                    }
                }
            }
            for ref in refs {
                if self.attachmentStore.isLoaded(ref) { continue }
                do {
                    guard let source = try await chatArchive.retainedSource(
                        conversationID: conversationID,
                        attachmentID: ref.id.uuidString
                    ) else { continue }
                    if source.extractedText != nil {
                        // The versioned extraction artifact: the model text and
                        // the structured document both come from here, never
                        // from the raw UTF-8 blob.
                        if let text = try await chatArchive.retainedText(
                            conversationID: conversationID,
                            attachmentID: ref.id.uuidString
                        ), !text.isEmpty {
                            let document = try await chatArchive.retainedDocument(
                                conversationID: conversationID,
                                attachmentID: ref.id.uuidString
                            )
                            self.attachmentStore.storeText(
                                AttachmentSessionStore.Text(
                                    text: text,
                                    kindLabel: ref.kind.displayName,
                                    notes: [],
                                    extractedDocument: document
                                ),
                                for: ref
                            )
                        } else if !source.damagedRoles.isEmpty {
                            // The envelope is stored but no longer decodes, so
                            // the model text is not there. Say so instead of
                            // letting the attachment resume as absent.
                            AppLog.persistence.error(
                                "Retained extraction is damaged and cannot be resumed: \(ref.kind.displayName)"
                            )
                        }
                    }
                    if ref.kind.isImage, let imageRef = source.normalizedImage {
                        let imageData = try await chatArchive.readArtifact(imageRef)
                        let ext = imageRef.fileExtension?.lowercased()
                        let mime = (ext == "jpg" || ext == "jpeg") ? "image/jpeg" : "image/png"
                        self.attachmentStore.storeImage(
                            QuickImageAttachment(
                                data: imageData,
                                mimeType: mime,
                                pixelWidth: ref.pixelWidth ?? 0,
                                pixelHeight: ref.pixelHeight ?? 0
                            ),
                            for: ref
                        )
                    }
                } catch {
                    // A missing or damaged artifact stays missing: it is never
                    // re-read from the source or re-fetched.
                    AppLog.persistence.error(
                        "Retained attachment could not be read: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func persistCurrentConversation() {
        // The canonical archive keeps every chat whatever the legacy
        // retention settings say. Without one, the old switch bounds the
        // only store there is.
        if chatArchive == nil, !settings.historyEnabled { return }
        guard let local = currentConversation,
              let conversation = conversationToStore(local)
        else { return }
        currentConversation = conversation
        // The canonical in-memory list is never capped; only the on-disk
        // cache is bounded by the "Chats to keep" setting.
        var merged = history.filter { $0.id != conversation.id }
        merged.append(conversation)
        history = QuickHistoryStore.ordered(merged)
        openChatBase = StoredChatStamp(conversation)
        saveHistory()
        syncConversationToArchive(conversation)
    }

    /// The projection of the latest turn into the structured archive. The
    /// question was already committed before Send; this carries the answer and
    /// the chat's current shape. The write is owed until it lands, so a quit
    /// waits for it and a failure is retried instead of logged and forgotten.
    func syncConversationToArchive(_ conversation: QuickConversation) {
        guard chatArchive != nil,
              conversation.messages.contains(where: { $0.role == .assistant })
        else { return }
        durability?.record(conversation, after: archiveCheckpointTask)
    }

    /// Registers the final answer of one turn as a mandatory archive write.
    /// Synchronous on purpose: the caller runs it where the text became final
    /// and before its first suspension, so a quit cannot observe a finished
    /// answer with no debt behind it. A chat the user deleted gets no write.
    @discardableResult
    func registerTerminalAnswer(
        conversationID: UUID,
        turnID: UUID,
        status: RequestStatus,
        error: String? = nil,
        text: String?,
        receipt: RequestReceipt? = nil,
        selection: ModelSelection? = nil,
        timings: RequestTimings,
        usage: TokenUsage?,
        toolRounds: [ToolRound]?,
        rounds: ChatRoundRecorder? = nil
    ) -> Task<Bool, Never>? {
        guard let durability, !store.deletedChatIDs.contains(conversationID) else { return nil }
        return durability.register(
            AnswerTerminalWrite(
                conversationID: conversationID,
                turnID: turnID,
                status: status,
                error: error,
                text: text,
                receipt: receipt,
                selection: selection,
                timings: timings,
                usage: usage,
                toolRounds: toolRounds,
                rounds: rounds,
                checkpointFence: archiveCheckpointTask
            )
        )
    }

    /// The activity revision a quit compares against after its awaits. A
    /// change means work was accepted after the freeze, so the attempt is stale.
    var answerDurabilityRevision: Int { durability?.revision ?? 0 }

    /// True while any accepted submit has not reached its model request yet.
    var isSubmitBeforeStream: Bool { !preStreamSubmitTokens.isEmpty }

    /// Freezes the archive writes this quit owns. Call it after the stop and
    /// before the first await: a late completion can only finish frozen
    /// persistence, never stop a request that started after a refusal.
    func freezeAnswerDurability() -> AnswerDurability.Snapshot {
        durability?.freeze() ?? .empty
    }

    /// Awaits one quit's frozen archive work and reports what is still owed.
    func settleAnswerDurability(_ snapshot: AnswerDurability.Snapshot) async -> AnswerDurability.Verdict {
        guard let durability else { return .durable }
        return await durability.settle(snapshot)
    }

    /// Convenience for callers that freeze and settle in one step.
    @discardableResult
    func flushArchiveForQuit() async -> Bool {
        await settleAnswerDurability(freezeAnswerDurability()) == .durable
    }

    /// Clears the local slash-command refusal (the composer's Send as Text,
    /// `/new`, `/clear`).
    func clearRefusedCommand() { refusedCommandText = nil }

    /// A question that became a turn but could not go out leaves the
    /// thread. `submittedInput` goes back in the composer when given and
    /// the field is empty; `nil` (⌘R) leaves the composer alone.
    func rollbackSubmission(messageID: UUID, restoring submittedInput: String?) {
        currentConversation?.messages.removeAll { $0.id == messageID }
        currentConversation?.updatedAt = Date()
        if let submittedInput, input.isEmpty { input = submittedInput }
    }

    // MARK: - Launch at login

    func applyLaunchAtLogin() {
        let controller = SystemLaunchAtLoginController()
        try? controller.setEnabled(settings.launchAtLogin)
    }

    // MARK: - Install update

    func installUpdate() {
        guard case .updateAvailable(let version) = updateState else { return }
        updateState = .installing(newVersion: version)
        let isHB = FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/quick-launch")
        guard isHB else {
            workspace.open(
                URL(string: "https://github.com/tristan-mcinnis/quick-launch/releases/latest")!
            )
            updateState = .idle
            return
        }

        Task { [weak self, version] in
            let installError: String?
            do {
                let result = try await ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                    arguments: ["upgrade", "quick-launch"]
                )
                installError = result.status == 0
                    ? nil
                    : "Homebrew exited with status \(result.status)"
            } catch {
                installError = error.localizedDescription
            }

            if let installError {
                self?.updateState = .error(message: installError)
            } else {
                self?.updateState = .installed(newVersion: version)
            }
        }
    }

    // MARK: - Manual update check

    func checkForUpdateManual() async {
        updateState = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/tristan-mcinnis/quick-launch/releases/latest")!
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                updateState = .error(message: "Could not parse release info")
                return
            }
            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            await handleUpdateCheck(remoteVersion: latestVersion)
        } catch {
            updateState = .error(message: error.localizedDescription)
        }
    }

    // MARK: - Update check

    func handleUpdateCheck(remoteVersion: String) async {
        if QuickViewModel.isVersionNewer(remoteVersion, than: currentVersion) {
            updateState = .updateAvailable(newVersion: remoteVersion)
        } else {
            updateState = .upToDate
        }
    }

    // MARK: - Version comparison

    nonisolated static func isVersionNewer(_ candidate: String, than current: String) -> Bool {
        let normalize: (String) -> [Int] = { version in
            let stripped = version.hasPrefix("v") ? String(version.dropFirst()) : version
            return stripped.split(separator: ".").compactMap { Int($0) }
        }

        var lhs = normalize(candidate)
        var rhs = normalize(current)

        // Pad shorter array with zeros
        let maxLen = max(lhs.count, rhs.count)
        while lhs.count < maxLen { lhs.append(0) }
        while rhs.count < maxLen { rhs.append(0) }

        for (l, r) in zip(lhs, rhs) {
            if l > r { return true }
            if l < r { return false }
        }
        return false // equal
    }
}


