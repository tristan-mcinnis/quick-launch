import AppKit
import Darwin
import SwiftUI

// Borderless panel that can still become key — needed so the TextField
// receives keyboard input. Without the override, a .borderless style mask
// prevents the panel from ever becoming the key window.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    weak var composerModel: QuickViewModel?
    /// The live in-app shortcut table. The panel takes ⌘K and the screenshot
    /// keys before the model sees them, so it has to ask the same table the
    /// model and the hints ask; nil (tests, and any panel built without a view
    /// model) falls back to the built-in keys.
    var bindings: (() -> ShortcutBindings)?
    var commandKHandler: (() -> Void)?
    var commandCHandler: (() -> Bool)?
    /// ⌘⇧S opens the capture chooser, ⌘⇧D captures the display under the pointer.
    var captureChooserHandler: (() -> Void)?
    var screenshotHandler: ((ScreenshotKind) -> Void)?
    /// Item shortcuts (⌘↩, ⌘E, ⌃X, ⌘⇧A…). Returns true when consumed.
    var shortcutHandler: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?
    /// ⇧↩ translates the typed text. Returns true when consumed.
    var translateHandler: (() -> Bool)?
    /// ⌫ on an empty field pops a layer. Returns true when consumed.
    var backspaceHandler: (() -> Bool)?
    /// Escape must work even when a SwiftUI TextField's field editor consumes
    /// cancelOperation before the root view sees `.onKeyPress(.escape)`.
    var escapeHandler: (() -> Bool)?
    /// Plain submit, used when a modified Return has no special meaning.
    var returnHandler: (() -> Void)?

    /// Applies the drag limits for the surface on screen. With limits (the
    /// Quick AI surface) the panel is resizable between them; without
    /// (root search, which is measured) it is not resizable at all, and
    /// the frame follows the content alone. Touches the style mask only
    /// when resizability actually changes.
    func applyUserResizeLimits(_ limits: PanelSizing.ResizeLimits?) {
        if let limits {
            if !styleMask.contains(.resizable) { styleMask.insert(.resizable) }
            if minSize != limits.minimum { minSize = limits.minimum }
            if maxSize != limits.maximum { maxSize = limits.maximum }
        } else {
            if styleMask.contains(.resizable) { styleMask.remove(.resizable) }
            // `setFrame(_:display:)` ignores these; clearing them keeps a
            // stale Quick AI minimum from reaching any other resize path.
            if minSize != .zero { minSize = .zero }
            if maxSize != Self.unlimitedSize { maxSize = Self.unlimitedSize }
        }
    }

    /// AppKit's own default `maxSize` (FLT_MAX in both dimensions).
    static let unlimitedSize = CGSize(
        width: CGFloat(Float.greatestFiniteMagnitude),
        height: CGFloat(Float.greatestFiniteMagnitude)
    )

    /// Unmodified keys never reach `performKeyEquivalent`; the field editor
    /// eats Backspace before SwiftUI sees it. `sendEvent` sees everything.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let editor = firstResponder as? NSTextView {
            // Pinyin and other input methods own Return and Escape until the
            // marked text is committed; no launcher action may steal them.
            if editor.hasMarkedText() {
                super.sendEvent(event)
                return
            }
            if let composerModel, QuickAIComposerEditing.handle(event, editor: editor, model: composerModel) {
                return
            }
        }
        if event.type == .keyDown, event.modifierFlags.overlayRelevant.isEmpty {
            switch VirtualKey(event: event) {
            case .escape where escapeHandler?() == true:
                return
            case .delete where backspaceHandler?() == true:
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let editor = firstResponder as? NSTextView {
            if editor.hasMarkedText(), VirtualKey.isReturn(keyCode: event.keyCode) {
                return super.performKeyEquivalent(with: event)
            }
            if let composerModel, QuickAIComposerEditing.handle(event, editor: editor, model: composerModel) {
                return true
            }
        }
        let modifiers = event.modifierFlags.overlayRelevant
        let shortcuts = bindings?() ?? .defaults
        if event.type == .keyDown,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           modifiers == [.command],
           commandCHandler?() == true {
            return true
        }
        // An accessory app has no Edit menu while the launcher panel is key,
        // so the system never delivers Select All, Copy or Cut to the field
        // editor or to an answer's text view. Route them to the first
        // responder by hand, as the Translator panel does. Paste and undo
        // keep their own composer handlers below.
        if event.type == .keyDown, modifiers == [.command],
           let editor = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                editor.selectAll(nil)
                return true
            case "c":
                editor.copy(nil)
                return true
            case "x" where editor.isEditable:
                editor.cut(nil)
                return true
            default:
                break
            }
        }
        if event.type == .keyDown,
           shortcuts.matches(.commandPalette, keyCode: event.keyCode, modifiers: modifiers) {
            commandKHandler?()
            return true
        }
        if event.type == .keyDown {
            if shortcuts.matches(.attachWindow, keyCode: event.keyCode, modifiers: modifiers),
               let captureChooserHandler {
                captureChooserHandler()
                return true
            }
            if shortcuts.matches(.attachDisplay, keyCode: event.keyCode, modifiers: modifiers),
               let screenshotHandler {
                screenshotHandler(.display)
                return true
            }
        }
        if event.type == .keyDown,
           modifiers == [.shift],
           VirtualKey.isReturn(keyCode: event.keyCode) {
            // ⇧↩ translates when a direction is set; otherwise it submits
            // like a plain Return instead of silently doing nothing.
            if translateHandler?() == true { return true }
            if let returnHandler {
                returnHandler()
                return true
            }
        }
        if event.type == .keyDown,
           !modifiers.isEmpty,
           modifiers != [.shift],
           shortcutHandler?(event.charactersIgnoringModifiers, event.keyCode, modifiers) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - Properties

    private(set) var viewModel: QuickViewModel?
    private var panel: KeyablePanel?
    private var welcomePanel: NSPanel?
    private var settingsPanel: NSPanel?
    /// The AI Chat window, built on first open.
    private var aiChatController: AIChatWindowController?
    /// The Chief of Staff: the `cos` thread, its waiting cards, and its
    /// notices. Quick Launch is its face; `run()` is its root task.
    private var chiefOfStaff: ChiefOfStaffModel?
    private var chiefOfStaffTask: Task<Void, Never>?
    private var globalHotKey: GlobalHotKey?
    private var clipboardHistoryHotKey: GlobalHotKey?
    private var translatorHotKey: GlobalHotKey?
    private var translatorPanel: TranslatorPanel?
    private var translatorModel: TranslatorModel?
    private var typeToClickHotKey: GlobalHotKey?
    private var typeToClickController: TypeToClickController?
    private var actionHotKeys: [UUID: GlobalHotKey] = [:]
    private var launcherItemHotKeys: [String: GlobalHotKey] = [:]
    private var mouseMonitor: Any?
    private var statusItem: NSStatusItem?
    private var overlayClearTask: Task<Void, Never>?
    /// Pending delayed shrink of the overlay panel; growth cancels it.
    private var panelShrinkTask: Task<Void, Never>?
    /// The launcher's top edge, its horizontal centre, and the display it
    /// was anchored on, fixed at show time. Content growth hangs from here;
    /// the search field never moves.
    private var panelAnchor: ScreenPlacement.PanelAnchor?
    /// How far a live resize of the Quick AI surface may grow before its
    /// moving edges leave the display, fixed when the drag starts.
    private var liveResizeRoom: CGSize?
    private var overlayRetentionID: UUID?

    private let selectedTextService = SelectedTextService()
    private let applicationCatalog = ApplicationCatalogService()
    private let launcherCatalog = LauncherCatalogService()
    private let clipboardHistory = ClipboardHistoryStore()
    private let colorHistory = ColorHistoryStore()
    private let colorSampler = ScreenColorSampler()
    private let webSearchService = WebSearchRouter(
        searxng: SearXNGSearchService(),
        tavily: TavilySearchService(
            apiKey: { APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.tavilySearch) }
        ),
        brave: BraveSearchService(
            apiKey: { APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.braveSearch) }
        ),
        bocha: BochaSearchService(
            apiKey: { APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.bochaSearch) }
        ),
        exa: ExaSearchService(
            apiKey: { APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.exaSearch) }
        ),
        hasTavilyKey: {
            !(APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.tavilySearch) ?? "").isEmpty
        },
        hasBraveKey: {
            !(APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.braveSearch) ?? "").isEmpty
        },
        hasBochaKey: {
            !(APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.bochaSearch) ?? "").isEmpty
        },
        hasExaKey: {
            !(APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.exaSearch) ?? "").isEmpty
        }
    )
    private let vaultSearchService = SSHVaultSearchService()
    /// The launch probe's answer: which optional tool backends this Mac has.
    private var chatBackends: ChatBackendStatus?
    /// The `recall` CLI over the memory notes: the model's memory tools and Capture to Memory.
    private let recall = RecallCLI()
    private let pageReader = WebPageReader()
    private let windowManager = WindowManager()
    private let agentSessions = AgentSessionWatcher(folders: AgentSessionWatcher.defaultFolders())
    private let powerSources = PowerSourceMonitor()
    private lazy var caffeinateManager = CaffeinateManager(
        assertion: PowerAssertion(),
        watcher: agentSessions,
        power: powerSources
    )
    private let localSpeechService = LocalSpeechService()
    private let launcherUsage = LauncherUsageStore(fileURL: LauncherUsageStore.defaultFileURL())
    private let interactionJournal = InteractionJournalStore(
        fileURL: InteractionJournalStore.defaultFileURL()
    )
    private let screenshotService = ScreenshotCaptureService()
    private let screenAwareness = ScreenAwarenessService()
    private let screenshotTextIndex = ScreenshotTextIndex(storeURL: ScreenshotTextIndex.defaultStoreURL())
    private let doubleTapMonitor = ModifierDoubleTapMonitor()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Whatever image is already on the clipboard at launch was copied
        // before this run: it is not a fresh copy to offer. Without this,
        // every relaunch attached the same old clipboard image once more.
        ClipboardImageReader.suppressAutoOffer()
        let vm = QuickViewModel(
            selectedTextService: selectedTextService,
            applicationCatalog: applicationCatalog,
            launcherCatalog: launcherCatalog,
            clipboardHistory: clipboardHistory,
            colorHistory: colorHistory,
            colorSampler: colorSampler,
            webSearchService: webSearchService,
            vaultSearchService: vaultSearchService,
            pageReader: pageReader,
            windowManager: windowManager,
            caffeinateManager: caffeinateManager,
            localSpeechService: localSpeechService,
            launcherUsage: launcherUsage,
            interactionJournal: interactionJournal,
            screenshotService: screenshotService,
            screenAwareness: screenAwareness,
            screenshotTextIndex: screenshotTextIndex,
            pasteboard: SystemPasteboard(),
            historyFileURL: QuickHistoryStore.defaultFileURL(),
            archiveRootURL: AppPaths.applicationSupportDirectory,
            attachmentExtractor: SharedDocumentExtractor(),
            // What every other house app can do, read from the manifests they
            // publish. Without this the catalog is nil, every house-command
            // path returns at its `guard let`, and no row can ever appear —
            // while the tests all pass, because they inject their own.
            houseCommandCatalog: HouseCommandCatalog(),
            currentVersion: Bundle.main.shortVersion
        )
        self.viewModel = vm
        vm.overlayPresenter = self
        // Tools inside the chat: memory through `recall`, skills from
        // ~/.claude/skills, and sources opened with /usr/bin/open.
        vm.memoryService = recall
        vm.memoryCapture = recall
        vm.skillLibrary = SkillLibrary()
        vm.fileOpener = OpenCommandFileOpener()
        vm.attachmentFilePicker = SystemAttachmentFilePicker()
        vm.piHandoff = PiHandoffService()
        // Settings › General › Chat asks it whether tmux, pi, Ghostty,
        // recall, and the vault host are there.
        vm.chatBackendProbe = ChatBackendProbe()
        // The optional House tools (recall, the House server) leave the
        // chat on a Mac that does not have them.
        Task { @MainActor [weak self] in
            let status = await ChatBackendProbe().probe()
            guard let self else { return }
            self.chatBackends = status
            self.viewModel?.dropMissingChatBackends(status)
            self.aiChatController?.model.chat.dropMissingChatBackends(status)
        }
        // ⌘J in Quick AI and the "AI Chat" command open the chat window.
        vm.aiChatOpener = { [weak self] handoff in
            guard let self else { return }
            // On the launcher's display, where the keyboard was.
            self.showAIChat(handoff: handoff, on: self.launcherScreen() ?? self.screenContainingMouse())
        }
        startChiefOfStaff(viewModel: vm)

        Task { @MainActor [weak self] in
            await self?.bootstrap(viewModel: vm)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A stream in either view stops and keeps its question and what
        // arrived; the history file is on disk before the process ends.
        aiChatController?.prepareForTermination()
        chiefOfStaffTask?.cancel()
        if let viewModel { AIChatWindowController.keepStreamForQuit(viewModel) }
        QuickHistoryStore.waitForPendingWrites()
        overlayClearTask?.cancel()
        globalHotKey?.invalidate()
        clipboardHistoryHotKey?.invalidate()
        translatorHotKey?.invalidate()
        typeToClickHotKey?.invalidate()
        clipboardHistory.stopMonitoring()
        doubleTapMonitor.stop()
        actionHotKeys.values.forEach { $0.invalidate() }
        actionHotKeys.removeAll()
        launcherItemHotKeys.values.forEach { $0.invalidate() }
        launcherItemHotKeys.removeAll()
        if let monitor = mouseMonitor  { NSEvent.removeMonitor(monitor) }
        caffeinateManager.releaseForQuit()
    }

    // MARK: - Bootstrap

    private func bootstrap(viewModel: QuickViewModel) async {
        // a. Load settings from UserDefaults
        let settings = QuickSettings.load()
        viewModel.settings = settings
        // Stored colors are written in whichever notation settings ask for.
        colorHistory.preferredFormat = settings.colorFormat
        caffeinateManager.onChange = { [weak viewModel] in
            viewModel?.syncCaffeinateState()
        }
        caffeinateManager.isAgentWatchEnabled = settings.caffeinateAgentWatch
        caffeinateManager.batteryCutoff = settings.caffeinateBatteryCutoff
        caffeinateManager.keepsDisplayAwake = settings.caffeinateKeepDisplayAwake
        caffeinateManager.start()
        doubleTapMonitor.onDoubleTap = { [weak self, weak viewModel] in
            guard let self, let viewModel, viewModel.settings.screenAwarenessDoubleTap else { return }
            viewModel.rememberSelectionTarget(self.selectedTextService.currentExternalTarget())
            Task { @MainActor in
                if await viewModel.attachScreenshot(.window, clearingInput: true) {
                    self.showOverlay(captureSelectionTarget: false)
                }
            }
        }
        if settings.screenAwarenessDoubleTap { doubleTapMonitor.start() }
        // Re-assert the intent from before the relaunch; an expired timer is gone.
        if settings.caffeinateEnabled {
            caffeinateManager.setEnabled(true)
        } else if let until = settings.caffeinateUntil, until > Date() {
            caffeinateManager.enable(until: until)
        }
        viewModel.syncCaffeinateState()
        viewModel.settings.save()
        if !settings.customApplicationPaths.isEmpty {
            applicationCatalog.setExtraApplicationPaths(settings.customApplicationPaths)
        }
        viewModel.loadHistory()
        configureClipboardHistory()

        // b. Create NSPanel with OverlayView hosted in NSHostingController
        let panel = makePanel(viewModel: viewModel)
        self.panel = panel
        viewModel.prepareForExternalAction = { [weak self] in
            self?.hideOverlay()
        }
        // A layout picked in the launcher acts on the AI Chat window when
        // that window is the one in front. Resolved on each call, so it is
        // simply absent until the chat window has been built.
        viewModel.ownWindowLayout = OwnWindowLayout { [weak self] in
            self?.aiChatController?.chatWindow
        }
        viewModel.recoverFromExternalActionFailure = { [weak self] in
            self?.showOverlay(captureSelectionTarget: false)
        }

        // c. Register global hotkey (Option+Space by default)
        registerGlobalHotkey()
        registerActionHotkeys()
        registerLauncherItemHotkeys()

        // d. Register local mouse monitor for click-outside dismissal
        registerMouseDismissMonitor()

        // e. Screen capture forces an always-visible, stateful status item.
        // Otherwise the normal menu-bar preference applies.
        syncStatusItemVisibilityAndPresentation(viewModel: viewModel)

        // Listen for Escape / dismiss notifications from OverlayView
        NotificationCenter.default.addObserver(
            forName: .dismissOverlay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hideOverlay() }
        }

        // Re-register hotkey when settings change
        NotificationCenter.default.addObserver(
            forName: .hotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reregisterGlobalHotkey() }
        }

        NotificationCenter.default.addObserver(
            forName: .actionHotkeysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reregisterActionHotkeys() }
        }

        NotificationCenter.default.addObserver(
            forName: .launcherItemHotkeysChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reregisterLauncherItemHotkeys() }
        }

        NotificationCenter.default.addObserver(
            forName: .clipboardHistorySettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.configureClipboardHistory() }
        }

        NotificationCenter.default.addObserver(
            forName: .openTranslator,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.showTranslator() }
        }
        NotificationCenter.default.addObserver(
            forName: .openTypeToClick,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.showTypeToClick() }
        }
        NotificationCenter.default.addObserver(
            forName: .translatorSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.registerTranslatorHotkey() }
        }
        NotificationCenter.default.addObserver(
            forName: .typeToClickSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.registerTypeToClickHotkey()
                self.typeToClickController?.configureContinuation(
                    self.viewModel?.settings.typeToClickContinuation ?? .continuous
                )
            }
        }
        registerTranslatorHotkey()
        registerTypeToClickHotkey()

        NotificationCenter.default.addObserver(
            forName: .screenAwarenessSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self, weak viewModel] _ in
            Task { @MainActor [weak self, weak viewModel] in
                guard let self, let viewModel else { return }
                if viewModel.settings.screenAwarenessDoubleTap { self.doubleTapMonitor.start() } else { self.doubleTapMonitor.stop() }
            }
        }

        // A screenshot command run from a global hotkey needs the panel back.
        NotificationCenter.default.addObserver(
            forName: .presentOverlay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.showOverlay(captureSelectionTarget: false) }
        }

        // Open settings in its own panel (not .sheet — avoids gray corner artifact)
        NotificationCenter.default.addObserver(
            forName: .openSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.showSettingsPanel() }
        }

        // Panel auto-resize: observe viewModel state and grow/shrink the panel
        // to fit the current overlay content.
        startPanelSizeObserver(viewModel: viewModel)

        // f. Show WelcomeOverlayView first so the user sees UI immediately.
        if !settings.hasSeenWelcome {
            showWelcomePanel()
        } else if !settings.launchAtLoginPromptShown {
            // Welcome already seen on a prior launch but login prompt never shown
            // (upgrade path) — show it now.
            promptForLaunchAtLogin(viewModel: viewModel)
        }

        // Provider and network work remain dormant until the user runs an
        // action or explicitly refreshes/checks from Settings. The one
        // exception is the opt-in update check below.
        if settings.checkForUpdatesOnLaunch {
            // Settings › About › Updates: one silent release-tag check at
            // launch. It never installs anything; the About pane owns that.
            Task { @MainActor [weak viewModel] in
                await viewModel?.checkForUpdateSilently()
            }
        }

        // Warm what the first keystrokes will need, off the hotkey path.
        AppIconCache.prewarm(paths: applicationCatalog.applications.map(\.url.path))
        applicationCatalog.loadAlternateNames()
        // Screenshots list for the root badge and an instant catalog entry.
        viewModel.refreshScreenshotFilesInBackground()
    }

    // MARK: - Panel construction

    private func makePanel(viewModel: QuickViewModel) -> KeyablePanel {
        // Not resizable at root search; the Quick AI surface turns resizing
        // on while it is up (`syncPanelResizeLimits`).
        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PanelSizing.panelWidth,
                height: PanelSizing.inputHeight
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // The delegate hears the end of a user's drag on the Quick AI
        // surface and remembers the size.
        panel.delegate = self
        panel.composerModel = viewModel
        panel.bindings = { [weak viewModel] in
            viewModel?.shortcuts ?? .defaults
        }
        panel.commandKHandler = { [weak viewModel] in
            viewModel?.handleCommandK()
        }
        panel.commandCHandler = { [weak viewModel] in
            guard let viewModel, viewModel.catalogScope != nil else { return false }
            viewModel.copySelectedLauncherItem()
            return true
        }
        panel.captureChooserHandler = { [weak viewModel] in
            viewModel?.openCaptureChooser()
        }
        panel.screenshotHandler = { [weak viewModel] kind in
            Task { @MainActor in
                await viewModel?.attachScreenshot(kind, clearingInput: false)
            }
        }
        panel.shortcutHandler = { [weak viewModel] characters, keyCode, modifiers in
            viewModel?.performShortcut(characters: characters, keyCode: keyCode, modifiers: modifiers) ?? false
        }
        panel.translateHandler = { [weak viewModel] in
            guard let viewModel, viewModel.translationDirection != nil else { return false }
            Task { @MainActor in await viewModel.translateInput() }
            return true
        }
        panel.backspaceHandler = { [weak viewModel] in
            viewModel?.popLayerForEmptyBackspace() ?? false
        }
        panel.escapeHandler = { [weak viewModel] in
            viewModel?.handleEscapeKey() ?? false
        }
        panel.appearance = viewModel.settings.appearance.nsAppearance
        panel.returnHandler = { [weak viewModel] in
            Task { @MainActor in await viewModel?.submitResolvingFuzzyAlias() }
        }
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The system drop shadow stands in for `Shadow.panelNear` and
        // `Shadow.panelFar`: a borderless panel clips anything drawn outside
        // its content rect, so drawing both in SwiftUI would need a
        // transparent margin around the panel and new placement maths.
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false   // keep visible across app focus changes
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.worksWhenModal = true

        let hostingController = NSHostingController(
            rootView: OverlayView(viewModel: viewModel)
        )
        hostingController.view.frame = NSRect(
            x: 0,
            y: 0,
            width: PanelSizing.panelWidth,
            height: PanelSizing.inputHeight
        )
        panel.contentViewController = hostingController

        // Center on the display that contains the pointer.
        if let screen = screenContainingMouse() {
            let origin = ScreenPlacement.panelOrigin(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                panelWidth: PanelSizing.panelWidth,
                inputHeight: PanelSizing.inputHeight
            )
            panel.setFrame(
                NSRect(
                    x: origin.x,
                    y: origin.y,
                    width: PanelSizing.panelWidth,
                    height: PanelSizing.inputHeight
                ),
                display: false
            )
        }

        return panel
    }

    // MARK: - Show / Hide / Toggle

    func showOverlay(captureSelectionTarget: Bool = true) {
        guard let panel else { return }
        // The main launcher and Type to Click both own keyboard focus. Never
        // leave the always-on-top search panels stacked above the launcher.
        if typeToClickController?.isActive == true { hideTypeToClick() }
        overlayClearTask?.cancel()
        overlayClearTask = nil
        overlayRetentionID = nil
        if captureSelectionTarget {
            viewModel?.rememberSelectionTarget(selectedTextService.currentExternalTarget())
            // Capture the background selection before the panel becomes key
            // and steals focus, so ad-hoc Quick AI sees what the user selected.
            if viewModel?.catalogScope == nil {
                viewModel?.captureLaunchSelection()
            }
            viewModel?.captureImageFromClipboard()
        }
        if let vm = viewModel, vm.settings.clipboardHistoryEnabled {
            clipboardHistory.capture(from: .general, limit: vm.settings.clipboardHistoryLimit)
        }
        applicationCatalog.refreshIfNeeded()
        // A Quick AI thread kept from the last open shows the chat as the
        // store has it now: the AI Chat window may have added to it,
        // renamed it, or deleted it since.
        viewModel?.refreshOpenChatFromStore()
        // Keep the Screenshots badge and first entry honest without ever
        // touching the disk on the keystroke path.
        viewModel?.warmScreenshotCatalogIfStale()
        // What the other house apps can do right now, read off the main
        // thread. A missing or dead app costs the launcher nothing.
        viewModel?.refreshHouseCommands()
        // Re-center on the screen that currently has the mouse cursor.
        if let screen = screenContainingMouse() {
            let originWidth = viewModel?.currentPanelWidth ?? PanelSizing.panelWidth
            let origin = ScreenPlacement.panelOrigin(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                panelWidth: originWidth,
                inputHeight: PanelSizing.inputHeight
            )
            // Anchor the top edge once: the input row sits on the centre
            // line and stays there while results grow below it. The old
            // "grow down, then clamp" path pushed the search field up the
            // moment the list reached the bottom margin.
            let top = ScreenPlacement.anchoredTop(
                visibleFrame: screen.visibleFrame,
                inputHeight: PanelSizing.inputHeight
            )
            let anchor = ScreenPlacement.PanelAnchor(
                top: top,
                centreX: origin.x + originWidth / 2,
                visibleFrame: screen.visibleFrame
            )
            panelAnchor = anchor
            // A Quick AI surface kept from the last open (the retention
            // window) comes back at its remembered size, held to this
            // display and rising to fit if it is taller than the room under
            // the anchor.
            let quickAISize = viewModel.flatMap { vm in
                vm.isQuickAIPresented
                    ? PanelSizing.quickAIPlacedSize(vm.quickAISize, visibleFrame: screen.visibleFrame)
                    : nil
            }
            // Resolve the destination surface before making the window visible.
            // Reusing the previous frame caused a visible resize on the next
            // Observation pass when entering or reopening a history catalog.
            let size = quickAISize ?? viewModel.map(targetPanelSize) ?? panel.frame.size
            let frame = anchor.frame(
                width: size.width,
                height: size.height,
                current: panel.frame,
                keepsCurrentCentre: false,
                risingToFit: quickAISize != nil
            )
            panel.setFrame(frame, display: false)
        }
        syncPanelResizeLimits()
        panel.appearance = viewModel?.settings.appearance.nsAppearance
        // No fade. The panel appears on the same frame as the hotkey, like
        // Raycast; a fade only adds perceived latency.
        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        viewModel?.requestInputFocus()
    }

    func hideOverlay() {
        guard let panel else { return }
        panel.orderOut(nil)
        // Read the session's outcome while its state is still intact: the
        // resets below clear the query and the answer.
        viewModel?.endInteractionSession()
        viewModel?.reset(.layers)
        viewModel?.rememberSelectionTarget(nil)
        // Dismissal drops the launch-scoped selection so a non-capture reopen
        // never re-attaches a stale selection or writes back to a stale target.
        viewModel?.clearLaunchScopedState()

        overlayClearTask?.cancel()
        guard let viewModel else { return }
        let seconds = max(0, viewModel.settings.reopenRetentionSeconds)
        guard seconds > 0 else {
            Self.resetOverlaySurface(viewModel)
            return
        }
        // The whole surface — catalog, query, selection, answer — survives
        // for the retention window, so a quick reopen lands exactly where
        // the user left off and repeated actions chain without re-typing.
        let retentionID = UUID()
        overlayRetentionID = retentionID
        overlayClearTask = Task { @MainActor [weak self, weak viewModel] in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            guard let self,
                  let viewModel,
                  self.overlayRetentionID == retentionID else { return }
            Self.resetOverlaySurface(viewModel)
            self.overlayClearTask = nil
            self.overlayRetentionID = nil
        }
    }

    /// Back to the root, like a fresh Raycast open.
    private static func resetOverlaySurface(_ viewModel: QuickViewModel) {
        viewModel.clearTransientDisplay()
    }

    func toggleOverlay() {
        guard let panel else { return }
        if panel.isVisible {
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    private func screenContainingMouse() -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = ScreenPlacement.screenIndex(
            containing: NSEvent.mouseLocation,
            frames: screens.map(\.frame)
        ) else { return nil }
        return screens[index]
    }

    // MARK: - Global hotkey (configurable, default Option+Space)

    private func registerGlobalHotkey() {
        guard let vm = viewModel else { return }
        let keyCode = vm.settings.hotkeyKeyCode
        let modifierFlags = NSEvent.ModifierFlags(rawValue: vm.settings.hotkeyModifiers).overlayRelevant

        // The main hotkey had no cross-check before: a combination that an
        // in-app shortcut or another dedicated hotkey owns is refused here,
        // with the same message the Settings row shows.
        if let conflict = vm.settings.launcherHotkeyConflict() {
            globalHotKey?.invalidate()
            globalHotKey = nil
            vm.hotkeyRegistrationError = conflict
            return
        }

        globalHotKey = GlobalHotKey(
            keyCode: UInt32(keyCode),
            modifiers: GlobalHotKey.carbonModifiers(from: modifierFlags)
        ) { [weak self] in
            self?.toggleOverlay()
        }
        vm.hotkeyRegistrationError = globalHotKey == nil
            ? "Unable to register this shortcut. Check that macOS or another app is not using it."
            : nil
    }

    func reregisterGlobalHotkey() {
        globalHotKey?.invalidate()
        globalHotKey = nil
        registerGlobalHotkey()
    }

    private func configureClipboardHistory() {
        guard let vm = viewModel else { return }
        clipboardHistoryHotKey?.invalidate()
        clipboardHistoryHotKey = nil
        if vm.settings.clipboardHistoryEnabled {
            clipboardHistory.startMonitoring(limit: vm.settings.clipboardHistoryLimit)
            registerClipboardHistoryHotkey()
        } else {
            clipboardHistory.stopMonitoring()
        }
    }

    private func registerClipboardHistoryHotkey() {
        guard let vm = viewModel, vm.settings.clipboardHistoryEnabled else { return }
        guard vm.settings.clipboardHistoryHotkeyConflict() == nil else {
            vm.clipboardHistoryHotkeyRegistrationError = vm.settings.clipboardHistoryHotkeyConflict()
            return
        }
        let hotkey = vm.settings.clipboardHistoryHotkey.normalized
        let flags = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
        clipboardHistoryHotKey = GlobalHotKey(
            keyCode: UInt32(hotkey.keyCode),
            modifiers: GlobalHotKey.carbonModifiers(from: flags)
        ) { [weak self] in
            self?.showClipboardHistory()
        }
        vm.clipboardHistoryHotkeyRegistrationError = clipboardHistoryHotKey == nil
            ? "That shortcut is already used by macOS or another app."
            : nil
    }

    private func registerTranslatorHotkey() {
        translatorHotKey?.invalidate()
        translatorHotKey = nil
        guard let vm = viewModel else { return }
        guard vm.settings.translatorHotkeyConflict() == nil else {
            vm.translatorHotkeyRegistrationError = vm.settings.translatorHotkeyConflict()
            return
        }
        let hotkey = vm.settings.translatorHotkey.normalized
        let flags = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
        translatorHotKey = GlobalHotKey(
            keyCode: UInt32(hotkey.keyCode),
            modifiers: GlobalHotKey.carbonModifiers(from: flags)
        ) { [weak self] in
            self?.showTranslator()
        }
        vm.translatorHotkeyRegistrationError = translatorHotKey == nil
            ? "That shortcut is already used by macOS or another app."
            : nil
    }

    private func registerTypeToClickHotkey() {
        typeToClickHotKey?.invalidate()
        typeToClickHotKey = nil
        guard let vm = viewModel else { return }
        guard vm.settings.typeToClickHotkeyConflict() == nil else {
            vm.typeToClickHotkeyRegistrationError = vm.settings.typeToClickHotkeyConflict()
            return
        }
        guard vm.settings.typeToClickHotkeyEnabled else {
            vm.typeToClickHotkeyRegistrationError = nil
            return
        }
        let hotkey = vm.settings.typeToClickHotkey.normalized
        let flags = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
        typeToClickHotKey = GlobalHotKey(
            keyCode: UInt32(hotkey.keyCode),
            modifiers: GlobalHotKey.carbonModifiers(from: flags)
        ) { [weak self] in
            self?.showTypeToClick()
        }
        vm.typeToClickHotkeyRegistrationError = typeToClickHotKey == nil
            ? "That shortcut is already used by macOS or another app."
            : nil
    }

    /// The Translator window: opened from ⇧⌘T or the Translate item. Arrives
    /// with the selection of the app behind it; toggles closed on repeat.
    func showTranslator(retainedSelection handedOffSelection: String? = nil) {
        guard let vm = viewModel else { return }
        if let panel = translatorPanel, panel.isVisible, panel.isKeyWindow {
            // A handoff means the user asked to translate a selection: bring the
            // existing window forward and import it, don't toggle it shut.
            if handedOffSelection != nil {
                translatorModel?.retainLaunchSelection(handedOffSelection)
                panel.makeKey()
                panel.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            hideTranslator()
            return
        }
        let target = selectedTextService.currentExternalTarget()
        let selected = target.flatMap { selectedTextService.capture(from: $0, promptForPermission: false)?.text }
        let model = translatorModel ?? makeTranslatorModel(for: vm)
        translatorModel = model
        // Retain the launch snapshot (handed off before the overlay closed) and
        // fall back to the fresh capture, so "Use selected text" works even
        // when the translator is opened directly (⇧⌘T) and no snapshot exists.
        model.prepare(
            target: target,
            selectedText: handedOffSelection ?? selected,
            retainedSelection: handedOffSelection ?? vm.launchSelection?.text ?? selected
        )
        let panel = translatorPanel ?? makeTranslatorPanel(model: model)
        translatorPanel = panel
        if let screen = screenContainingMouse() {
            let origin = ScreenPlacement.panelOrigin(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                panelWidth: TranslatorView.size.width,
                inputHeight: TranslatorView.size.height
            )
            panel.setFrameOrigin(origin)
        }
        if self.panel?.isVisible == true { hideOverlay() }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        model.requestSourceFocus()
    }

    func hideTranslator() {
        translatorPanel?.orderOut(nil)
    }

    func showTypeToClick() {
        // Toggle normally. A permission message instead uses the next press to
        // recheck access for the same app, as its instructions promise.
        if let controller = typeToClickController, controller.isActive {
            if controller.isAwaitingAccessibilityPermission {
                controller.retryAccessibilityPermission()
            } else if !controller.isCapturingKeyboard {
                // An AX action can activate the controlled app while the
                // transparent panels remain visible. Recover the chain instead
                // of making this press dismiss a mode that is not receiving keys.
                controller.recaptureKeyboard()
            } else {
                controller.dismiss()
            }
            return
        }
        if panel?.isVisible == true { hideOverlay() }
        let controller = typeToClickController ?? TypeToClickController()
        let exitHotkey = viewModel?.settings.typeToClickHotkeyEnabled == true
            ? viewModel?.settings.typeToClickHotkey
            : nil
        controller.configureExitHotkey(exitHotkey)
        controller.configureContinuation(
            viewModel?.settings.typeToClickContinuation ?? .continuous
        )
        typeToClickController = controller
        guard let target = selectedTextService.currentExternalTarget() else {
            controller.presentMessage("No app window found to control")
            return
        }
        controller.start(in: target.processIdentifier)
    }

    func hideTypeToClick() {
        typeToClickController?.dismiss()
    }

    private func makeTranslatorModel(for vm: QuickViewModel) -> TranslatorModel {
        let model = TranslatorModel(
            lastTarget: TranslationTarget.named(vm.settings.lastTranslationTarget) ?? .simplifiedChinese,
            lastSource: TranslationTarget.named(vm.settings.lastTranslationSource),
            serviceFactory: { [weak vm] in vm?.makeCurrentService() },
            selectedTextService: selectedTextService,
            pasteboard: vm.pasteboard
        )
        model.onTargetChange = { [weak vm, weak model] target in
            vm?.settings.lastTranslationTarget = target.code
            if let model { vm?.settings.lastTranslationSource = model.sourceLanguage.code }
            vm?.settings.save()
        }
        model.onCommit = { record in
            TranslationHistoryStore.append(record, to: TranslationHistoryStore.defaultURL())
        }
        return model
    }

    private func makeTranslatorPanel(model: TranslatorModel) -> TranslatorPanel {
        let panel = TranslatorPanel(
            contentRect: NSRect(origin: .zero, size: TranslatorView.size),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.appearance = viewModel?.settings.appearance.nsAppearance
        panel.contentViewController = NSHostingController(
            rootView: TranslatorView(model: model)
                .preferredColorScheme(viewModel?.settings.appearance.swiftUIColorScheme)
        )
        panel.shortcutHandler = { [weak self, weak model] characters, keyCode, modifiers in
            guard let self, let model else { return false }
            if VirtualKey(rawValue: keyCode) == .escape, modifiers.isEmpty {
                if model.isTargetPickerPresented {
                    model.isTargetPickerPresented = false
                } else if !model.source.isEmpty {
                    model.clear()
                } else {
                    self.hideTranslator()
                }
                return true
            }
            // The window's own table; ⌘P is not in it (it is the chat list
            // elsewhere), the target language is ⌘T.
            switch TranslatorKey.matching(characters: characters, keyCode: keyCode, modifiers: modifiers) {
            case .copy:
                model.copyTranslation()
                self.hideTranslator()
            case .pasteBack:
                self.hideTranslator()
                Task { @MainActor in _ = await model.pasteBack() }
            case .swap:
                model.swap()
            case .target:
                model.isTargetPickerPresented.toggle()
            case .useClipboard:
                model.useClipboardAsSource()
            case .close:
                self.hideTranslator()
            case nil:
                return false
            }
            return true
        }
        return panel
    }

    private func showClipboardHistory() {
        guard let vm = viewModel else { return }
        vm.rememberSelectionTarget(selectedTextService.currentExternalTarget())
        vm.enterCatalog(.clipboard)
        showOverlay(captureSelectionTarget: false)
    }

    private func registerActionHotkeys() {
        guard let vm = viewModel else { return }
        for action in vm.settings.savedPrompts {
            guard let hotkey = action.hotkey,
                  vm.settings.actionHotkeyConflict(for: action.id) == nil else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: hotkey.normalized.modifiers)
            let registered = GlobalHotKey(
                keyCode: UInt32(hotkey.keyCode),
                modifiers: GlobalHotKey.carbonModifiers(from: flags)
            ) { [weak self] in
                self?.invokeActionHotkey(actionID: action.id)
            }
            actionHotKeys[action.id] = registered
        }
    }

    private func reregisterActionHotkeys() {
        actionHotKeys.values.forEach { $0.invalidate() }
        actionHotKeys.removeAll()
        registerActionHotkeys()
    }

    private func invokeActionHotkey(actionID: UUID) {
        guard let vm = viewModel,
              let action = vm.settings.savedPrompts.first(where: { $0.id == actionID }) else {
            return
        }
        vm.rememberSelectionTarget(selectedTextService.currentExternalTarget())
        // Capture before activation so the action runs on the user's actual
        // selection, not re-read after the overlay stole focus.
        vm.captureLaunchSelection()
        // A hotkey run is a direct use; the journal keeps its own row and
        // ranking is left alone because a saved action is not a launcher item.
        vm.noteDirectHotkeyUse(itemID: "action:\(action.alias)")
        showOverlay(captureSelectionTarget: false)
        Task { await vm.perform(action: action) }
    }

    private func registerLauncherItemHotkeys() {
        guard let vm = viewModel else { return }
        vm.launcherItemHotkeyRegistrationErrors.removeAll()
        for configuration in vm.settings.launcherItemConfigurations {
            // Type to Click has one canonical optional hotkey. Ignore legacy
            // launcher-item records from before its ⌘K editor was unified.
            guard configuration.itemID != "type-to-click.mode",
                  let hotkey = configuration.hotkey,
                  vm.settings.launcherItemHotkeyConflict(
                    for: configuration.id
                  ) == nil else { continue }

            let flags = NSEvent.ModifierFlags(rawValue: hotkey.normalized.modifiers)
            let registered = GlobalHotKey(
                keyCode: UInt32(hotkey.keyCode),
                modifiers: GlobalHotKey.carbonModifiers(from: flags)
            ) { [weak self] in
                self?.invokeLauncherItemHotkey(configuration)
            }
            if let registered {
                launcherItemHotKeys[configuration.id] = registered
            } else {
                vm.launcherItemHotkeyRegistrationErrors[configuration.id] =
                    "This hotkey is already in use by macOS or another application."
            }
        }
    }

    private func invokeLauncherItemHotkey(_ configuration: LauncherItemConfiguration) {
        guard let vm = viewModel else { return }
        if configuration.kind == .application,
           let application = applicationCatalog.applications.first(where: {
               $0.id == configuration.itemID
           }) {
            vm.learnDirectUse(of: application)
            _ = applicationCatalog.launch(application)
            return
        }
        guard let item = vm.catalogItem(
            kind: configuration.kind,
            itemID: configuration.itemID
        ) else { return }
        vm.learnDirectUse(of: item)
        vm.rememberSelectionTarget(selectedTextService.currentExternalTarget())
        if item.kind == .quickLink, item.requiresInput {
            vm.enterQuickLinkInput(itemID: item.id)
            showOverlay(captureSelectionTarget: false)
        } else {
            Task { await vm.performLauncherItem(item) }
        }
    }

    private func reregisterLauncherItemHotkeys() {
        launcherItemHotKeys.values.forEach { $0.invalidate() }
        launcherItemHotKeys.removeAll()
        registerLauncherItemHotkeys()
    }

    // MARK: - Click-outside dismissal

    private func registerMouseDismissMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let clickPoint = event.locationInWindow
                let screenPoint: NSPoint
                if let window = event.window {
                    screenPoint = window.convertPoint(toScreen: clickPoint)
                } else {
                    screenPoint = clickPoint
                }
                // Ignore clicks in the menu bar region (status item clicks are
                // handled separately by handleStatusItemClick)
                if ScreenPlacement.isInMenuBarRegion(
                    screenPoint,
                    frames: NSScreen.screens.map(\.frame)
                ) {
                    return
                }
                if !panel.frame.contains(screenPoint) {
                    self.hideOverlay()
                }
            }
        }
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.imagePosition = .imageOnly
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    private func syncStatusItemVisibilityAndPresentation(viewModel: QuickViewModel) {
        if viewModel.settings.showMenuBar {
            setupStatusItem()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            return
        }

        guard let button = statusItem?.button else { return }
        // Status item (DESIGN.md): the app-icon glyph as a template image at
        // `Control.statusGlyph`, medium weight; outline idle, `.fill` = on.
        let image = NSImage(
            systemSymbolName: Self.statusGlyphName,
            accessibilityDescription: Self.statusAccessibilityName
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: House.Control.statusGlyph, weight: .medium)
        )
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(Self.statusAccessibilityName)
    }

    /// The status item's one glyph, and what VoiceOver reads for it.
    static let statusGlyphName = "bolt"
    static let statusAccessibilityName = "Quick Launch"

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleOverlay()
            return
        }
        if event.type == .rightMouseUp {
            let menu = buildContextMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            toggleOverlay()
        }
    }

    /// Built on every right-click, so it shows the current hotkey and
    /// Caffeinate state (`StatusMenu`).
    private func buildContextMenu() -> NSMenu {
        StatusMenu.make(
            StatusMenu.State(
                settings: viewModel?.settings ?? QuickSettings(),
                isCaffeinating: viewModel?.isCaffeinating == true,
                hasCaffeinateSession: viewModel?.hasCaffeinateSession == true,
                version: Bundle.main.shortVersion
            ),
            target: self,
            action: #selector(performStatusMenuCommand(_:))
        )
    }

    @objc private func performStatusMenuCommand(_ sender: NSMenuItem) {
        switch StatusMenu.Command(rawValue: sender.tag) {
        case .openQuickLaunch: showOverlayFromMenu()
        case .openAIChat: showAIChatFromMenu()
        case .openSettings: openSettingsFromMenu()
        case .toggleCaffeinate: toggleCaffeinateFromMenu()
        case .showWelcome: showWelcomeFromMenu()
        case .openWebsite: openWebsite()
        case .quit: NSApp.terminate(nil)
        case nil: break
        }
    }

    // MARK: - Panel auto-resize observer

    /// Observe the QuickViewModel reactively (Observation framework) and resize
    /// the panel only when output/isStreaming/errorMessage actually change.
    /// Replaces an earlier 80ms polling loop that kept the menu bar app at
    /// 7-8% CPU even when idle (issue #24).
    private func startPanelSizeObserver(viewModel: QuickViewModel) {
        resizePanelForContent()
        armPanelSizeObserver(viewModel: viewModel)
    }

    private func armPanelSizeObserver(viewModel: QuickViewModel) {
        withObservationTracking { [weak viewModel] in
            guard let viewModel else { return }
            _ = viewModel.output
            _ = viewModel.isStreaming
            _ = viewModel.errorMessage
            _ = viewModel.isActionPalettePresented
            _ = viewModel.isTransformChooserPresented
            // The model chooser and the Add Context menu are inline blocks on
            // the root surface: each one changes the window height. The Quick
            // AI surface (and Recent Chats inside it) is the size the user
            // left it at; nothing on it is measured.
            _ = viewModel.isModelChooserPresented
            _ = viewModel.isAddContextMenuPresented
            _ = viewModel.isQuickAIPresented
            _ = viewModel.isRecentChatsPresented
            // The remembered Quick AI size: a finished drag and Reset
            // Quick AI Size both land here.
            _ = viewModel.quickAISize
            _ = viewModel.modelChooserOptions.count
            _ = viewModel.addContextOptions.count
            _ = viewModel.isApplicationActionPanePresented
            _ = viewModel.isCatalogActionPanePresented
            _ = viewModel.catalogScope
            _ = viewModel.actionQuery
            _ = viewModel.input
            _ = viewModel.pendingImage
            _ = viewModel.activeItemActionForm
            _ = viewModel.deleteArmedItemID
            _ = viewModel.lastQuestion
            _ = viewModel.pendingContext
            _ = viewModel.applicationSelectionIndex
            _ = viewModel.screenshotIndexProgress
            _ = viewModel.screenshotFiles
            _ = viewModel.clipboardEntries
            _ = viewModel.settings.showMenuBar
        } onChange: { [weak self, weak viewModel] in
            Task { @MainActor in
                guard let self, let viewModel else { return }
                self.syncStatusItemVisibilityAndPresentation(viewModel: viewModel)
                self.resizePanelForContent()
                self.armPanelSizeObserver(viewModel: viewModel)
            }
        }
    }

    private func resizePanelForContent() {
        guard let panel, let vm = viewModel else { return }
        // The user is dragging the Quick AI surface's edges: the content
        // must not fight the drag. The size lands when the drag ends
        // (`windowDidEndLiveResize`), and the next pass agrees with it.
        guard !panel.inLiveResize else { return }
        syncPanelResizeLimits()
        // The Quick AI size is held to the display first, so a stored size
        // from a larger display compares equal to the frame the display
        // already capped and is not re-applied on every tick.
        let target = targetPanelSize(vm)
        let total = target.height
        let width = target.width
        let frame = panel.frame
        let needsWidthChange = abs(frame.width - width) > 1
        if total > frame.height + 1 || needsWidthChange {
            // Growth (and width changes) apply on the spot.
            panelShrinkTask?.cancel()
            panelShrinkTask = nil
            applyPanelFrame(height: total, width: width)
        } else if total < frame.height - 1 {
            // Shrinks wait one beat while the panel is visible: transitions
            // pass through short-lived states (submit clears the list before
            // streaming starts), and applying those made the window dip and
            // then grow back. A growth within the beat cancels the shrink.
            guard panel.isVisible else {
                applyPanelFrame(height: total, width: width)
                return
            }
            panelShrinkTask?.cancel()
            panelShrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, let vm = self.viewModel else { return }
                self.panelShrinkTask = nil
                let target = self.targetPanelSize(vm)
                self.applyPanelFrame(height: target.height, width: target.width)
            }
        }
    }

    private func applyPanelFrame(height: CGFloat, width: CGFloat) {
        guard let panel, !panel.inLiveResize else { return }
        var frame = panel.frame
        guard abs(frame.height - height) > 1 || abs(frame.width - width) > 1 else { return }
        let centreX = frame.midX
        if let panelAnchor {
            // Hang from the fixed top edge: only the bottom moves. A Quick
            // AI surface the user sized taller than the room under the
            // anchor rises to fit instead of being cut. Root search (and
            // Quick AI back at 750 × 475) centres on the anchor: a drag of
            // one edge moved the frame's centre, and root must not follow.
            frame = panelAnchor.frame(
                width: width,
                height: height,
                current: frame,
                keepsCurrentCentre: viewModel?.keepsUserSizedFrame == true,
                risingToFit: viewModel?.isQuickAIPresented == true
            )
        } else {
            let delta = height - frame.height
            frame.size.height = height
            frame.size.width = width
            frame.origin.x = (centreX - width / 2).rounded()
            frame.origin.y -= delta  // grow down from the top
            if let screen = panel.screen ?? screenContainingMouse() {
                frame = ScreenPlacement.clamped(frame: frame, within: screen.visibleFrame)
            }
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    /// The drag limits for the surface on screen, on the display the panel
    /// hangs on: the Quick AI range while that surface is up, nil at root
    /// search.
    private var panelResizeLimits: PanelSizing.ResizeLimits? {
        guard let vm = viewModel, let visibleFrame = panelVisibleFrame else { return nil }
        return PanelSizing.userResizeLimits(
            isQuickAIPresented: vm.isQuickAIPresented,
            visibleFrame: visibleFrame
        )
    }

    /// The display the panel hangs on: the anchor's, fixed at show time.
    /// Every Quick AI size and frame decision reads this one display, so
    /// the limits, the drag, and the frame pass never disagree.
    private var panelVisibleFrame: CGRect? {
        guard let panel else { return nil }
        return panelAnchor?.visibleFrame
            ?? (panel.screen ?? screenContainingMouse())?.visibleFrame
    }

    /// The display a live drag happens on: the one the panel is on now (the
    /// user may have moved it there by its background), else the anchor's.
    /// The drag limits stay the anchor's, so a size stored from the drag
    /// always matches the frame the next resize pass would apply.
    private var panelDragVisibleFrame: CGRect? {
        panel?.screen?.visibleFrame ?? panelVisibleFrame
    }

    /// The window size for the surface on screen: the measured root size,
    /// or the Quick AI size held to the display.
    private func targetPanelSize(_ vm: QuickViewModel) -> CGSize {
        let requested = CGSize(width: vm.currentPanelWidth, height: targetPanelHeight(vm))
        guard vm.isQuickAIPresented, let visibleFrame = panelVisibleFrame else { return requested }
        return PanelSizing.quickAIPlacedSize(requested, visibleFrame: visibleFrame)
    }

    /// Resizable between the Quick AI limits while that surface is up, not
    /// resizable at root search.
    private func syncPanelResizeLimits() {
        panel?.applyUserResizeLimits(panelResizeLimits)
    }

    // MARK: - NSWindowDelegate (the launcher panel)

    /// A drag on the Quick AI surface's edges starts: note which edges
    /// move (from where the pointer is) and how far each may go before it
    /// leaves the display. AppKit does not keep a borderless window's edges
    /// off the Dock or the menu bar.
    func windowWillStartLiveResize(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel,
              viewModel?.isQuickAIPresented == true,
              let visibleFrame = panelDragVisibleFrame
        else {
            liveResizeRoom = nil
            return
        }
        let edges = ScreenPlacement.DragEdges(pointer: NSEvent.mouseLocation, frame: panel.frame)
        liveResizeRoom = ScreenPlacement.dragRoom(from: panel.frame, moving: edges, within: visibleFrame)
    }

    /// The drag's last word on size, beside `minSize` and `maxSize`: the
    /// hosting view's own constraints must never carry the surface past
    /// the display or under 750 × 475, and the moving edges stop at the
    /// display's margin. Only a user's drag is clamped; every other resize
    /// (the content's own, AppKit's) passes untouched.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let panel, sender === panel, panel.inLiveResize,
              let limits = panelResizeLimits
        else { return frameSize }
        return limits.clamp(frameSize, room: liveResizeRoom)
    }

    /// A drag on the Quick AI surface's edges ended: fit the frame inside
    /// the display (a backstop for the drag clamp above), then remember the
    /// size, so the next open and the next launch use it. Root search is
    /// never resizable, and the view model ignores a size off the Quick AI
    /// surface anyway.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        liveResizeRoom = nil
        guard let vm = viewModel, vm.isQuickAIPresented else { return }
        var frame = panel.frame
        if let visibleFrame = panelDragVisibleFrame {
            let fitted = ScreenPlacement.clamped(frame: frame, within: visibleFrame)
            if fitted != frame {
                panel.setFrame(fitted, display: true, animate: false)
                frame = fitted
            }
        }
        vm.rememberQuickAISize(frame.size)
    }

    private func targetPanelHeight(_ vm: QuickViewModel) -> CGFloat {
        // Base height as if no pane were floating: the launcher list stays
        // fully visible behind the ⌘K pane, so opening or closing a pane
        // does not move the window unless the pane itself needs more room.
        // The math lives on the view model so the render-proof tests hold
        // the drawn view and the window to the same numbers.
        vm.estimatedWindowHeight
    }

    @objc private func showOverlayFromMenu() {
        showOverlay()
    }

    @objc private func openSettingsFromMenu() {
        showSettingsPanel()
    }

    @objc private func showWelcomeFromMenu() {
        welcomePanel?.orderOut(nil)
        welcomePanel = nil
        showWelcomePanel()
    }

    @objc private func toggleCaffeinateFromMenu() {
        guard let viewModel,
              let item = viewModel.systemCommands.first(where: {
                  $0.itemID == "caffeinate.toggle"
              }) else { return }
        viewModel.performSystemCommand(item)
    }

    @objc private func openWebsite() {
        if let url = URL(string: "https://github.com/tristan-mcinnis/quick-launch") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Settings panel

    /// Settings closing: back to a menu-bar app unless AI Chat is still up.
    /// The launcher panel and the AI Chat window have their own closing.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settingsPanel else { return }
        AppActivation.settleAfterClosing(closing)
    }

    func showSettingsPanel(destination: SettingsDestination? = nil) {
        // Settings is a different job. Get the launcher out of the way.
        if panel?.isVisible == true { hideOverlay() }
        if let existing = settingsPanel, existing.isVisible {
            // A live window is already hosting a view that observes the
            // reveal notification; a not-yet-created one is born on the
            // destination instead.
            if let destination {
                NotificationCenter.default.post(
                    name: .revealSettingsDestination,
                    object: destination
                )
            }
            AppActivation.bringToFront(existing)
            return
        }
        guard let vm = viewModel else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: SettingsView.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quick Launch Settings"
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 2)
        panel.isReleasedWhenClosed = false
        panel.minSize = SettingsView.minimumWindowSize
        // Title bar follows the app's appearance; without this a forced-dark
        // pane sat under a white system title bar.
        panel.appearance = vm.settings.appearance.nsAppearance
        panel.setFrameAutosaveName("QuickLaunch.SettingsWindow")
        // An autosaved frame from an older, narrower layout squeezes the
        // pane until the sidebar and content crop at both window edges.
        let restored = panel.contentRect(forFrameRect: panel.frame).size
        if restored.width < SettingsView.minimumWindowSize.width
            || restored.height < SettingsView.minimumWindowSize.height {
            panel.setContentSize(SettingsView.windowSize)
        }
        panel.center()
        // Closing Settings last hands the menu bar back (`windowWillClose`).
        panel.delegate = self

        let hostingController = NSHostingController(
            rootView: SettingsView(viewModel: vm, initialDestination: destination)
        )
        panel.contentViewController = hostingController
        self.settingsPanel = panel
        AppActivation.bringToFront(panel)
    }

    // MARK: - AI Chat window

    /// Opens the AI Chat window: on the chat Quick AI handed over, or on the
    /// window's chat, the last chat, or a new one. On `screen` when given: a
    /// frame saved on another display moves there, keeping its size.
    func showAIChat(handoff: AIChatHandoff? = nil, on screen: NSScreen? = nil) {
        guard let controller = aiChatWindowController() else { return }
        controller.openingScreen = screen.map(ScreenArea.init)
        controller.model.open(handoff: handoff)
    }

    /// The display the launcher panel was last on (it has just closed for a
    /// hand-off), or nil before it was ever shown.
    private func launcherScreen() -> NSScreen? {
        guard let panel, panelAnchor != nil else { return nil }
        let centre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) }
    }

    /// The window's own view model shares the launcher's store (settings
    /// and chat history) and its services; its composer, thread, stream,
    /// and layers are its own.
    private func aiChatWindowController() -> AIChatWindowController? {
        if let aiChatController { return aiChatController }
        guard let launcher = viewModel else { return nil }
        let chat = QuickViewModel(
            store: launcher.store,
            selectedTextService: selectedTextService,
            applicationCatalog: applicationCatalog,
            launcherCatalog: launcherCatalog,
            webSearchService: webSearchService,
            vaultSearchService: vaultSearchService,
            pageReader: pageReader,
            localSpeechService: localSpeechService,
            launcherUsage: launcherUsage,
            interactionJournal: interactionJournal,
            screenshotService: screenshotService,
            screenAwareness: screenAwareness,
            pasteboard: SystemPasteboard(),
            historyFileURL: QuickHistoryStore.defaultFileURL(),
            archiveRootURL: AppPaths.applicationSupportDirectory,
            attachmentExtractor: SharedDocumentExtractor(),
            currentVersion: Bundle.main.shortVersion
        )
        chat.memoryService = recall
        chat.memoryCapture = recall
        chat.skillLibrary = SkillLibrary()
        chat.fileOpener = OpenCommandFileOpener()
        chat.attachmentFilePicker = SystemAttachmentFilePicker()
        chat.piHandoff = PiHandoffService()
        chat.chiefOfStaff = chiefOfStaff
        chat.chiefOfStaffOpener = launcher.chiefOfStaffOpener
        if let chatBackends { chat.dropMissingChatBackends(chatBackends) }
        let controller = AIChatWindowController(model: AIChatWindowModel(chat: chat), app: self)
        // The chat window lays itself out. Weak, because the controller owns
        // the window and the view model must never own the controller.
        chat.ownWindowLayout = OwnWindowLayout { [weak controller] in controller?.chatWindow }
        aiChatController = controller
        return controller
    }

    // MARK: - Chief of Staff

    /// The Chief of Staff's face is the AI Chat window's pinned
    /// conversation. Quick Launch is its one notification sender, and keeps
    /// `app.alive` fresh so `cos` leaves its own banners alone.
    private func startChiefOfStaff(viewModel vm: QuickViewModel) {
        UserNotificationRouter.shared.install()
        let model = ChiefOfStaffModel(paths: CosPaths.resolve(), notifier: ChiefOfStaffNotifier())
        model.fileOpener = OpenCommandFileOpener()
        model.onOpen = { [weak self] proposalID in self?.showChiefOfStaff(proposalID: proposalID) }
        model.onReply = { [weak self] text in
            guard let self, let controller = self.aiChatWindowController() else { return }
            self.showChiefOfStaff(proposalID: nil)
            controller.model.chat.sendChiefOfStaffReply(text)
        }
        chiefOfStaff = model
        vm.chiefOfStaff = model
        vm.chiefOfStaffOpener = { [weak self] proposalID in
            self?.showChiefOfStaff(proposalID: proposalID)
        }
        chiefOfStaffTask = Task { await model.run() }
    }

    /// The AI Chat window on the pinned conversation, on `proposalID`'s card
    /// when one is named, on the display under the pointer.
    func showChiefOfStaff(proposalID: String?) {
        guard let controller = aiChatWindowController() else { return }
        if panel?.isVisible == true { hideOverlay() }
        controller.openingScreen = screenContainingMouse().map(ScreenArea.init)
        controller.model.openChiefOfStaff(proposalID: proposalID)
    }

    @objc private func showAIChatFromMenu() {
        if panel?.isVisible == true { hideOverlay() }
        showAIChat(on: screenContainingMouse())
    }

    // MARK: - Welcome panel

    func showWelcomePanel() {
        guard let vm = viewModel else { return }
        let welcomePanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        welcomePanel.title = "Welcome"
        welcomePanel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 2)
        welcomePanel.isReleasedWhenClosed = false
        welcomePanel.isOpaque = false
        welcomePanel.backgroundColor = .clear
        welcomePanel.titlebarAppearsTransparent = true
        welcomePanel.titleVisibility = .hidden
        welcomePanel.appearance = vm.settings.appearance.nsAppearance
        welcomePanel.center()

        let hostingController = NSHostingController(
            rootView: WelcomeOverlayView(viewModel: vm, onContinue: { [weak self, weak welcomePanel] in
                Task { @MainActor [weak self, weak welcomePanel] in
                    guard let self else { return }
                    self.viewModel?.settings.hasSeenWelcome = true
                    self.viewModel?.settings.save()
                    welcomePanel?.orderOut(nil)
                    self.welcomePanel = nil
                    // Follow up with the launch-at-login dialog, then show overlay
                    if let vm = self.viewModel, !vm.settings.launchAtLoginPromptShown {
                        self.promptForLaunchAtLogin(viewModel: vm)
                    }
                    self.showOverlay()
                }
            })
        )
        welcomePanel.contentViewController = hostingController
        self.welcomePanel = welcomePanel
        welcomePanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Mirror of apfel-clip's launch-at-login alert — asked once, persisted.
    @MainActor
    private func promptForLaunchAtLogin(viewModel: QuickViewModel) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Start Quick Launch at login?"
        alert.informativeText = "Keep Quick Launch ready in your menu bar every time you sign in. You can change this later in Settings."
        alert.addButton(withTitle: "Enable at Login")
        alert.addButton(withTitle: "Not Now")
        let enable = alert.runModal() == .alertFirstButtonReturn
        viewModel.settings.launchAtLogin = enable
        viewModel.settings.launchAtLoginPromptShown = true
        viewModel.settings.save()
        viewModel.applyLaunchAtLogin()
    }
}

// MARK: - QuickViewModel extensions

extension QuickViewModel {

    // MARK: Silent update check

    /// Fetches latest release tag from GitHub and calls handleUpdateCheck.
    /// Never surfaces errors to the user.
    func checkForUpdateSilently() async {
        guard let url = URL(string: "https://api.github.com/repos/tristan-mcinnis/quick-launch/releases/latest") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String {
                await handleUpdateCheck(remoteVersion: tag)
            }
        } catch {
            // Silent — ignore network errors
        }
    }

}

// MARK: - OverlayPresenting

extension AppDelegate: OverlayPresenting {
    func presentOverlay() { showOverlay(captureSelectionTarget: false) }
    func dismissOverlay() { hideOverlay() }
    func openSettings() { showSettingsPanel() }
    func openSettings(destination: SettingsDestination) {
        showSettingsPanel(destination: destination)
    }
    func openTranslator() { showTranslator() }
    func openTranslator(retainedSelection: String?) { showTranslator(retainedSelection: retainedSelection) }
    func openTypeToClick() { showTypeToClick() }
}
