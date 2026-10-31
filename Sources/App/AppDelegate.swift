import AppKit
import Darwin
import SwiftUI
import HouseDesign

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - Properties

    private(set) var viewModel: QuickViewModel?
    var panel: KeyablePanel?
    var settingsPanel: NSPanel?
    /// The AI Chat window, built on first open.
    var aiChatController: AIChatWindowController?
    var globalHotKey: GlobalHotKey?
    var clipboardHistoryHotKey: GlobalHotKey?
    var translatorHotKey: GlobalHotKey?
    var translatorPanel: TranslatorPanel?
    var translatorModel: TranslatorModel?
    var typeToClickHotKey: GlobalHotKey?
    var typeToClickController: TypeToClickController?
    /// The optional direct Quick AI hotkey (off by default).
    var quickAIHotKey: GlobalHotKey?
    var actionHotKeys: [UUID: GlobalHotKey] = [:]
    var launcherItemHotKeys: [String: GlobalHotKey] = [:]
    var mouseMonitor: Any?
    var statusItem: NSStatusItem?
    private var overlayClearTask: Task<Void, Never>?
    /// The one quit attempt in flight, or the finished one on its way out.
    private var quitAttempts = QuitAttempts()
    /// Pending delayed shrink of the overlay panel; growth cancels it.
    var panelShrinkTask: Task<Void, Never>?
    /// The launcher's top edge, its horizontal centre, and the display it
    /// was anchored on, fixed at show time. Content growth hangs from here;
    /// the search field never moves.
    var panelAnchor: ScreenPlacement.PanelAnchor?
    /// How far a live resize of the Quick AI surface may grow before its
    /// moving edges leave the display, fixed when the drag starts.
    var liveResizeRoom: CGSize?
    private var overlayRetentionID: UUID?

    let selectedTextService = SelectedTextService()
    let applicationCatalog = ApplicationCatalogService()
    let launcherCatalog = LauncherCatalogService()
    let clipboardHistory = ClipboardHistoryStore()
    let webSearchService = WebSearchRouter(
        deepseek: DeepSeekSearchService(
            apiKey: { WebSearchKeys.deepSeek() }
        ),
        tavily: TavilySearchService(
            apiKey: { WebSearchKeys.tavily() }
        ),
        brave: BraveSearchService(
            apiKey: { WebSearchKeys.brave() }
        ),
        bocha: BochaSearchService(
            apiKey: { APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.bochaSearch) }
        ),
        exa: ExaSearchService(
            apiKey: { APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.exaSearch) }
        ),
        hasDeepSeekKey: { !(WebSearchKeys.deepSeek() ?? "").isEmpty },
        hasTavilyKey: { !(WebSearchKeys.tavily() ?? "").isEmpty },
        hasBraveKey: { !(WebSearchKeys.brave() ?? "").isEmpty },
        hasBochaKey: {
            !(APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.bochaSearch) ?? "").isEmpty
        },
        hasExaKey: {
            !(APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.exaSearch) ?? "").isEmpty
        }
    )
    /// The launch probe's answer: which optional tool backends this Mac has.
    var chatBackends: ChatBackendStatus?
    /// The `recall` CLI over the memory notes: the model's memory tools and Capture to Memory.
    let recall = RecallCLI()
    let pageReader = WebPageReader()
    private let windowManager = WindowManager()
    private let agentSessions = AgentSessionWatcher(folders: AgentSessionWatcher.defaultFolders())
    private let powerSources = PowerSourceMonitor()
    private lazy var caffeinateManager = CaffeinateManager(
        assertion: PowerAssertion(),
        watcher: agentSessions,
        power: powerSources
    )
    let launcherUsage = LauncherUsageStore(fileURL: LauncherUsageStore.defaultFileURL())
    let interactionJournal = InteractionJournalStore(
        fileURL: InteractionJournalStore.defaultFileURL()
    )
    let screenshotService = ScreenshotCaptureService()
    let screenAwareness = ScreenAwarenessService()
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
            webSearchService: webSearchService,
            pageReader: pageReader,
            windowManager: windowManager,
            caffeinateManager: caffeinateManager,
            launcherUsage: launcherUsage,
            interactionJournal: interactionJournal,
            screenshotService: screenshotService,
            screenAwareness: screenAwareness,
            screenshotTextIndex: screenshotTextIndex,
            pasteboard: SystemPasteboard(),
            historyFileURL: QuickHistoryStore.defaultFileURL(),
            archiveRootURL: AppPaths.applicationSupportDirectory,
            workspace: SystemWorkspace(),
            runningApplications: SystemRunningApplications(),
            attachmentExtractor: SharedDocumentExtractor(),
            // What every other house app can do, read from the manifests they
            // publish. Without this the catalog is nil, every house-command
            // path returns at its `guard let`, and no row can ever appear —
            // while the tests all pass, because they inject their own.
            houseCommandCatalog: HouseCommandCatalog(),
            apiKeyProvider: QuickViewModel.keychainAPIKey,
            keychain: SystemKeychainStore(),
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
        // and recall are there.
        vm.chatBackendProbe = ChatBackendProbe()
        // The optional recall tool leaves the chat on a Mac that does not
        // have it.
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

        Task { @MainActor [weak self] in
            await self?.bootstrap(viewModel: vm)
        }
    }

    /// How long a quit waits for the chats' archive writes. The installer's
    /// polite quit allows five seconds, so this deadline lands first to leave
    /// room for the refusal to reach the user.
    private static let quitSaveTimeout: Duration = .seconds(2)

    /// A quit stops the chats and lets every owed archive write finish before
    /// the process ends. The archive is what a relaunch reads, so the final
    /// answer, its terminal status and a chat the user deleted must be on
    /// disk. A failed write, a missed deadline, a chat surface that appeared
    /// during the wait, or activity accepted after the freeze refuses the
    /// quit; the app stays open and says why. It never quits on unsaved work.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A repeated ⌘Q coalesces into the running attempt: one reply ends the
        // one pending termination.
        guard let attempt = quitAttempts.begin() else { return .terminateLater }
        // Stop and freeze every chat before the first await. A deadline that
        // fires later can only finish frozen writes, never stop a request
        // started after a refusal.
        let session = QuitSession(controller: aiChatController, launcher: viewModel)
        let frozenController = aiChatController.map(ObjectIdentifier.init)
        let frozenLauncher = viewModel.map(ObjectIdentifier.init)
        Task { @MainActor [weak self] in
            let outcome = await withQuitDeadline(Self.quitSaveTimeout) {
                await session.finish(isStillCurrent: {
                    guard let self else { return false }
                    return self.aiChatController.map(ObjectIdentifier.init) == frozenController
                        && self.viewModel.map(ObjectIdentifier.init) == frozenLauncher
                })
            // A missed deadline is unsaved activity, not a diagnosis.
            } ?? .unsavedActivity
            let saved = outcome.allowsExit
            guard let self, self.quitAttempts.resolve(attempt, saved: saved) else { return }
            NSApp.reply(toApplicationShouldTerminate: saved)
            guard !saved else { return }
            self.reportQuitRefused(outcome)
        }
        return .terminateLater
    }

    /// A quit that could not prove its archive work stays open and says which
    /// kind of work is unfinished, so a retry is possible and nothing is lost
    /// silently. The copy names no cause it cannot see.
    private func reportQuitRefused(_ outcome: QuitOutcome) {
        AppLog.persistence.error("Quit was refused: \(outcome.logDescription).")
        let alert = NSAlert()
        alert.messageText = "Quick Launch did not quit"
        switch outcome {
        case .incompleteDeletion:
            alert.informativeText = "A chat you deleted is not removed from disk yet. Try again before quitting."
        case .activityAfterFreeze:
            alert.informativeText = "Chat activity is still arriving, so it is not saved yet. Try again before quitting."
        case .unsavedActivity, .durable:
            alert.informativeText = "The latest chat activity is not saved yet. Try again before quitting."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The chats stopped and their archive writes finished in
        // `applicationShouldTerminate`. A termination that skipped it (a
        // signal, for example) still stops the streams here; after a normal
        // quit this fallback is not needed and starts no new writes.
        if !quitAttempts.isActive {
            if let aiChatController {
                AIChatWindowController.keepStreamForQuit(aiChatController.model.chat)
            }
            if let viewModel { AIChatWindowController.keepStreamForQuit(viewModel) }
        }
        QuickHistoryStore.waitForPendingWrites()
        overlayClearTask?.cancel()
        globalHotKey?.invalidate()
        clipboardHistoryHotKey?.invalidate()
        translatorHotKey?.invalidate()
        typeToClickHotKey?.invalidate()
        quickAIHotKey?.invalidate()
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
        registerQuickAIHotkey()

        NotificationCenter.default.addObserver(
            forName: .quickAIHotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.registerQuickAIHotkey() }
        }
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

        if !settings.launchAtLoginPromptShown {
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
        // A clear the last dismissal left waiting for its answer is moot: the
        // reader is on the panel again and the answer stays where it is.
        viewModel?.cancelDeferredTransientClear()
        if captureSelectionTarget {
            viewModel?.rememberSelectionTarget(selectedTextService.currentExternalTarget())
            // Capture the background selection before the panel becomes key
            // and steals focus, so ad-hoc Quick AI sees what the user selected.
            if viewModel?.catalogScope == nil {
                viewModel?.captureLaunchSelection()
            }
        }
        // A Quick AI thread kept from the last open shows the chat as the
        // store has it now: the AI Chat window may have added to it,
        // renamed it, or deleted it since.
        viewModel?.refreshOpenChatFromStore()
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
        ShowPathSignpost.panelOrderedFront()
        // Put the caret in the field now so a key typed straight after the
        // hotkey lands in it; the request below stays as the fallback for
        // when the field is not in the hosting view yet.
        if let viewModel, !viewModel.searchablePaneOwningFocus {
            ShowFocus.focusInput(in: panel)
        }
        viewModel?.requestInputFocus()
        // Everything below is not needed to draw the first frame or to gate
        // Send, so it runs after the panel is up. The selection chip is
        // captured above, before the panel took focus.
        if captureSelectionTarget {
            viewModel?.captureImageFromClipboard()
        }
        if let vm = viewModel, vm.settings.clipboardHistoryEnabled {
            clipboardHistory.capture(from: .general, limit: vm.settings.clipboardHistoryLimit)
        }
        applicationCatalog.refreshIfNeeded()
        // Keep the Screenshots badge and first entry honest without ever
        // touching the disk on the keystroke path.
        viewModel?.warmScreenshotCatalogIfStale()
    }

    func hideOverlay() {
        guard let panel else { return }
        ShowPathSignpost.abandon()
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

    func toggleOverlay(fromHotkey: Bool = false) {
        guard let panel else { return }
        if panel.isVisible {
            hideOverlay()
        } else {
            if fromHotkey { ShowPathSignpost.hotkeyReceived(quickAI: false) }
            showOverlay()
        }
    }

    func screenContainingMouse() -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = ScreenPlacement.screenIndex(
            containing: NSEvent.mouseLocation,
            frames: screens.map(\.frame)
        ) else { return nil }
        return screens[index]
    }

    // MARK: - Settings panel

    /// Settings closing: back to a menu-bar app unless AI Chat is still up.
    /// The launcher panel and the AI Chat window have their own closing.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === settingsPanel else { return }
        AppActivation.settleAfterClosing(closing)
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
    func openTranslator(text: String, target: TranslationTarget) {
        showTranslator(retainedSelection: text, target: target)
    }
    func openTypeToClick() { showTypeToClick() }
}
