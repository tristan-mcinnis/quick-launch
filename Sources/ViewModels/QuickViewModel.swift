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
    var openingAnchor: (conversationID: UUID, anchor: ThreadScrollAnchor)?
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
    var isHandingOffToPi = false
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
    @ObservationIgnored var composerConfirmationTask: Task<Void, Never>?
    @ObservationIgnored var webAnswerTimeout: Duration = .seconds(15)
    @ObservationIgnored var catalogIdleResetDelay: Duration = .seconds(15)
    @ObservationIgnored private var justCopiedTask: Task<Void, Never>?
    @ObservationIgnored private var justSavedTask: Task<Void, Never>?
    /// A source being opened from the thread or the palette; a second click
    /// replaces it.
    @ObservationIgnored var sourceOpenTask: Task<Void, Never>?
    @ObservationIgnored var catalogIdleResetTask: Task<Void, Never>?

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
    @ObservationIgnored var renameReturnsToRecentChats = false
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
    @ObservationIgnored var selectionTarget: SelectionTarget?
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
    var captureChooserHasSelection = false

    /// Folder scanned by "Attach Latest Screenshot"; tests point it elsewhere.
    /// Pointing it somewhere new invalidates the cached scan so the next
    /// catalog entry rescans from disk.
    @ObservationIgnored var screenshotsFolder: URL = LatestScreenshotFinder.screenshotsFolder() {
        didSet {
            if oldValue != screenshotsFolder { lastScreenshotScanAt = nil }
        }
    }

    /// When `screenshotFiles` was read from disk; nil until the first scan.
    @ObservationIgnored var lastScreenshotScanAt: Date?

    @ObservationIgnored var screenshotScanTask: Task<Void, Never>?

    var updateState: UpdateState = .idle

    /// Where chat history is kept on disk. The app passes the real
    /// `chat-history.json`; nil (the default, and every test) keeps history
    /// in memory only, so a test run never reads, replaces, or deletes the
    /// user's chats.
    let historyFileURL: URL?

    /// The durable, keep-all chat archive. The app passes a real root; nil
    /// (the default, and every test) keeps the archive off, so a test run
    /// never writes to or reads the user's Application Support folder.
    let chatArchive: ChatArchive?

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
    var isClearingHistory = false

    /// Why the last saved-chat operation could not finish. Non-nil is the
    /// honest outcome on screen: the caller must not report success when this
    /// is set. Cleared when a new confirmed operation starts.
    var savedHistoryOperationError: String?

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

    var presentedLayer: PresentedLayer? {
        didSet { if presentedLayer == nil { resumeQueuedFollowUp() } }
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

    var threadScrollRequest: ThreadScrollRequest?

    /// Screenshots waiting to travel with the next question, oldest first.
    var pendingImages: [QuickImageAttachment] = []

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

    var pendingSnippetInsertion: PendingSnippetInsertion?

    /// The submit Tab started, kept so a test can await it.
    @ObservationIgnored var tabSubmitTask: Task<Void, Never>?

    /// The submit Return started from the Quick AI composer, kept so a test
    /// can await it and a second Return cannot race the first.
    @ObservationIgnored var composerSubmitTask: Task<Void, Never>?

    @ObservationIgnored var launcherMatchesCache: (key: String, value: [LauncherSearchResult])?

    /// Bumped whenever learned ranking changes, so the cache cannot go stale.
    @ObservationIgnored var launcherRankingVersion = 0







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

    func saveHistory() {
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
    func saveClipboardEntry(_ item: LauncherCatalogItem, asLink: Bool) {
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

    func revealInFinder(_ application: LaunchableApplication) {
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

    func finishSnippetInsertion(
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
    func popRecentChatsLayer() {
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


