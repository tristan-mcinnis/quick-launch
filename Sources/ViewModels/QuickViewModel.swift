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
    @ObservationIgnored var inlineTranslationTask: Task<Void, Never>?
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
    var houseCommandRows: [HouseCommandRow] = []

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
    @ObservationIgnored var houseCommandWaitTask: Task<Void, Never>?

    @ObservationIgnored var houseCommandRefreshTask: Task<Void, Never>?
    @ObservationIgnored var houseCommandRefreshPending = false
    @ObservationIgnored var houseCommandRefreshForce = false

    /// A snippet or Quicklink being written in the ⌘K editor before it
    /// exists anywhere. It lives only while that form is open; Save writes
    /// it to the store and the real item takes its place.
    var draftCatalogItem: LauncherCatalogItem?

    static let draftSnippetID = "draft.snippet"
    static let draftQuickLinkID = "draft.quicklink"

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
    /// The Keychain the Settings key fields read and write. In memory unless
    /// the app injects `SystemKeychainStore`, for the same reason as
    /// `apiKeyProvider`: a rendered Models pane in a test read real keys.
    @ObservationIgnored let keychain: any KeychainStoring
    /// The production lookup, passed in by `AppDelegate`.
    static let keychainAPIKey: (UUID) -> String? = { APIKeyStore.load(providerID: $0) }
    /// Whether a provider has a key, remembered for this session. The route
    /// resolver runs several times per body pass (`chatDestinationLabel`,
    /// `attachmentRoutingLine`, the pre-send controls), and each check read
    /// the Keychain: a heavy body re-evaluated three times a second produced
    /// hundreds of `SecItemCopyMatching` calls a second and most of the CPU
    /// the app burned. Cleared whenever a key or a provider setting changes.
    @ObservationIgnored var apiKeyPresence: [UUID: Bool] = [:]

    // How long the "just copied" flag stays true after auto-copy.
    @ObservationIgnored var justCopiedTimeout: Duration = .seconds(2)
    /// How long the composer's checkmark stays after a copy on Quick AI.
    @ObservationIgnored var composerConfirmationDuration: Duration = .milliseconds(1500)
    @ObservationIgnored var composerConfirmationTask: Task<Void, Never>?
    @ObservationIgnored var webAnswerTimeout: Duration = .seconds(15)
    @ObservationIgnored var catalogIdleResetDelay: Duration = .seconds(15)
    @ObservationIgnored var justCopiedTask: Task<Void, Never>?
    @ObservationIgnored var justSavedTask: Task<Void, Never>?
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
    @ObservationIgnored var streamFlushTask: Task<Void, Never>?
    @ObservationIgnored var lastStreamFlush = ContinuousClock.now
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
    @ObservationIgnored var archiveWriteChain: [UUID: Task<Void, Never>] = [:]
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
        keychain: (any KeychainStoring)? = nil,
        currentVersion: String = "1.0.0"
    ) {
        self.apiKeyProvider = apiKeyProvider ?? { _ in nil }
        self.keychain = keychain ?? InMemoryKeychainStore()
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

    // MARK: - Add Context

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

    // MARK: - Transform chooser (keyboard-first)

    /// True while the Transform chooser is open (opened by the Transform chip
    /// or its shortcut). ↑↓ move, Return runs, Esc closes. Keyboard-first:
    /// no mouse is needed to reach any transform.
    var isTransformChooserPresented = false {
        didSet { if !isTransformChooserPresented { resumeQueuedFollowUp() } }
    }
    var transformChooserIndex = 0

    var pendingTransformArguments: PendingTransformArguments?

    /// The typed text for the required `{argument}` slot the Transform
    /// argument field is asking for. Its own field, so the composer draft is
    /// never touched by an argument.
    var transformArgumentInput = ""

    var pendingTransformReview: PendingTransformReview?

    /// The `{argument}` values collected for the transform about to be
    /// submitted, read once by `prepareRequest` and then cleared. Nil means
    /// the resolved prompt has no argument slots.
    @ObservationIgnored var pendingActionArguments: [String]?

    // MARK: - Clear

    /// A dismissal asked for the surface to be cleared while a model answer
    /// was still streaming. The request keeps the surface as it is until the
    /// turn finishes, then this runs the clear the dismissal asked for.
    var isTransientClearDeferred = false

    // MARK: - Collapsed transcript messages

    /// Message ids the reader expanded out of the collapsed state. A message
    /// is collapsed when it is long enough and its id is not in here.
    var expandedTranscriptMessageIDs: Set<UUID> = []

    // MARK: - Thread scrolling

    /// How far the thread's view last sat from the bottom, as the view
    /// reported it. What the follow rule was decided on; tests read it.
    @ObservationIgnored var lastThreadDistanceFromBottom: CGFloat?

}
