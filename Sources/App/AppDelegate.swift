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

    var commandKHandler: (() -> Void)?
    var commandCHandler: (() -> Bool)?
    /// ⌘⇧S captures the previous app's window, ⌘⇧D the display under the pointer.
    var screenshotHandler: ((ScreenshotKind) -> Void)?
    /// Item shortcuts (⌘↩, ⌘E, ⌃X, ⌘⇧A…). Returns true when consumed.
    var shortcutHandler: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?
    /// ⇧↩ translates the typed text. Returns true when consumed.
    var translateHandler: (() -> Bool)?
    /// ⌫ on an empty field pops a layer. Returns true when consumed.
    var backspaceHandler: (() -> Bool)?

    /// Unmodified keys never reach `performKeyEquivalent`; the field editor
    /// eats Backspace before SwiftUI sees it. `sendEvent` sees everything.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.keyCode == 51,
           event.modifierFlags
               .intersection(.deviceIndependentFlagsMask)
               .subtracting([.function, .numericPad, .capsLock]).isEmpty,
           backspaceHandler?() == true {
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        if event.type == .keyDown,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           modifiers == [.command],
           commandCHandler?() == true {
            return true
        }
        if event.type == .keyDown,
           event.charactersIgnoringModifiers?.lowercased() == "k",
           modifiers == [.command] {
            commandKHandler?()
            return true
        }
        if event.type == .keyDown,
           modifiers == [.command, .shift],
           let screenshotHandler,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let kind: ScreenshotKind = key == "s" ? .window : (key == "d" ? .display : nil) {
            screenshotHandler(kind)
            return true
        }
        if event.type == .keyDown,
           modifiers == [.shift],
           event.keyCode == 36 || event.keyCode == 76,
           translateHandler?() == true {
            return true
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
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private(set) var viewModel: QuickViewModel?
    private var panel: NSPanel?
    private var welcomePanel: NSPanel?
    private var settingsPanel: NSPanel?
    private var globalHotKey: GlobalHotKey?
    private var clipboardHistoryHotKey: GlobalHotKey?
    private var translatorHotKey: GlobalHotKey?
    private var translatorPanel: TranslatorPanel?
    private var translatorModel: TranslatorModel?
    private var actionHotKeys: [UUID: GlobalHotKey] = [:]
    private var launcherItemHotKeys: [String: GlobalHotKey] = [:]
    private var localMonitor: Any?
    private var mouseMonitor: Any?
    private var statusItem: NSStatusItem?
    private var overlayClearTask: Task<Void, Never>?
    /// Pending delayed shrink of the overlay panel; growth cancels it.
    private var panelShrinkTask: Task<Void, Never>?
    private var overlayRetentionID: UUID?

    private let selectedTextService = SelectedTextService()
    private let applicationCatalog = ApplicationCatalogService()
    private let launcherCatalog = TunaCatalogService()
    private let clipboardHistory = ClipboardHistoryStore()
    private let colorHistory = ColorHistoryStore()
    private let colorSampler = ScreenColorSampler()
    private let webSearchService = SearXNGSearchService()
    private let vaultSearchService = SSHVaultSearchService()
    private let screenHistoryStore = try? SQLiteScreenHistoryStore()
    private let coastLegacyReader = CoastLegacyReader()
    private lazy var screenHistoryCoastImporter: ScreenHistoryCoastImportService? = {
        guard let screenHistoryStore else { return nil }
        return ScreenHistoryCoastImportService(
            reader: coastLegacyReader,
            store: screenHistoryStore,
            legacyContentRootURL: coastLegacyReader.contentRootURL
        )
    }()
    private lazy var screenHistoryRetirementReviewer: ScreenHistoryRetirementReviewService? = {
        guard let screenHistoryStore else { return nil }
        return ScreenHistoryRetirementReviewService(sampler: screenHistoryStore)
    }()
    private let screenHistorySoakReceipt = try? ScreenHistorySoakReceiptService()
    private let screenHistoryCoastFreezeReceipt = try? ScreenHistoryCoastFreezeReceiptService()
    private let screenHistoryVaultSaver = ScreenHistoryVaultSaveService()
    private let screenHistorySecurityChecker = FileVaultScreenHistorySecurityChecker()
    private lazy var screenHistoryCaptureSink: ScreenHistorySegmentedCaptureSink? = {
        guard let screenHistoryStore,
              let writer = try? AVFoundationScreenHistoryMediaSegmentWriter(
                  mediaRootURL: SQLiteScreenHistoryStore.defaultMediaDirectoryURL()
              )
        else { return nil }
        return ScreenHistorySegmentedCaptureSink(
            store: screenHistoryStore,
            writer: writer
        )
    }()
    private lazy var screenHistoryCaptureService: ScreenHistoryCaptureService? = {
        guard let screenHistoryCaptureSink else { return nil }
        return ScreenHistoryCaptureService(
            frameSource: ScreenCaptureKitHistoryFrameSource(),
            activityReader: SystemScreenHistoryActivityReader(),
            textRecognizer: VisionScreenHistoryTextRecognizer(),
            sink: screenHistoryCaptureSink,
            securityChecker: screenHistorySecurityChecker
        )
    }()
    private let pageReader = WebPageReader()
    private let windowManager = WindowManager()
    private let agentSessions = AgentSessionWatcher(folders: AgentSessionWatcher.defaultFolders())
    private let powerSources = PowerSourceMonitor()
    private lazy var caffeinateManager = CaffeinateManager(
        assertion: PowerAssertion(),
        watcher: agentSessions,
        power: powerSources
    )
    private let launcherUsage = LauncherUsageStore(fileURL: LauncherUsageStore.defaultFileURL())
    private let screenshotService = ScreenshotCaptureService()
    private let screenAwareness = ScreenAwarenessService()
    private let screenshotTextIndex = ScreenshotTextIndex(storeURL: ScreenshotTextIndex.defaultStoreURL())
    private let doubleTapMonitor = ModifierDoubleTapMonitor()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let maintenance = ScreenHistoryMaintenanceCommand.parse(CommandLine.arguments) {
            runMaintenanceCommand(maintenance)
            return
        }
        let vm = QuickViewModel(
            selectedTextService: selectedTextService,
            applicationCatalog: applicationCatalog,
            launcherCatalog: launcherCatalog,
            clipboardHistory: clipboardHistory,
            colorHistory: colorHistory,
            colorSampler: colorSampler,
            webSearchService: webSearchService,
            vaultSearchService: vaultSearchService,
            screenHistoryStore: screenHistoryStore,
            coastLegacyReader: coastLegacyReader,
            screenHistoryCaptureService: screenHistoryCaptureService,
            screenHistoryVaultSaver: screenHistoryVaultSaver,
            screenHistoryCoastImporter: screenHistoryCoastImporter,
            screenHistoryRetirementReviewer: screenHistoryRetirementReviewer,
            screenHistorySoakReceipt: screenHistorySoakReceipt,
            screenHistoryCoastFreezeReceipt: screenHistoryCoastFreezeReceipt,
            pageReader: pageReader,
            windowManager: windowManager,
            caffeinateManager: caffeinateManager,
            launcherUsage: launcherUsage,
            screenshotService: screenshotService,
            screenAwareness: screenAwareness,
            screenshotTextIndex: screenshotTextIndex,
            currentVersion: Bundle.main.shortVersion
        )
        self.viewModel = vm

        Task { @MainActor [weak self] in
            await self?.bootstrap(viewModel: vm)
        }
    }

    private func runMaintenanceCommand(_ command: ScreenHistoryMaintenanceCommand) {
        Task { [weak self] in
            guard let self else { Darwin.exit(1) }
            var missing: [String] = []
            if screenHistoryStore == nil { missing.append("store") }
            if screenHistoryCoastImporter == nil { missing.append("importer") }
            if screenHistoryRetirementReviewer == nil { missing.append("reviewer") }
            guard missing.isEmpty,
                  let store = screenHistoryStore,
                  let importer = screenHistoryCoastImporter,
                  let reviewer = screenHistoryRetirementReviewer else {
                FileHandle.standardError.write(
                    Data("Screen History maintenance is unavailable: \(missing.joined(separator: ", ")).\n".utf8)
                )
                Darwin.exit(1)
            }
            let freezeReceipt: ScreenHistoryCoastFreezeReceiptService
            do {
                freezeReceipt = try screenHistoryCoastFreezeReceipt
                    ?? ScreenHistoryCoastFreezeReceiptService()
            } catch {
                FileHandle.standardError.write(
                    Data("Screen History freeze receipt failed to initialize: \(String(describing: error)).\n".utf8)
                )
                Darwin.exit(1)
            }
            do {
                let runner = ScreenHistoryMaintenanceRunner(
                    store: store,
                    importer: importer,
                    freezeReceipt: freezeReceipt,
                    reviewer: reviewer
                )
                let receipt: ScreenHistoryMaintenanceReceipt
                switch command {
                case .prepareImport:
                    receipt = try await runner.prepareImport(
                        policy: QuickSettings.load().screenHistoryMigrationPolicy
                    )
                }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                var data = try encoder.encode(receipt)
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data("Screen History maintenance failed: \(String(describing: error))\n".utf8)
                )
                Darwin.exit(1)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayClearTask?.cancel()
        globalHotKey?.invalidate()
        clipboardHistoryHotKey?.invalidate()
        translatorHotKey?.invalidate()
        clipboardHistory.stopMonitoring()
        actionHotKeys.values.forEach { $0.invalidate() }
        actionHotKeys.removeAll()
        launcherItemHotKeys.values.forEach { $0.invalidate() }
        launcherItemHotKeys.removeAll()
        if let monitor = localMonitor  { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseMonitor  { NSEvent.removeMonitor(monitor) }
        caffeinateManager.releaseForQuit()
        Task { await screenHistoryCaptureService?.stop() }
    }

    // MARK: - Bootstrap

    private func bootstrap(viewModel: QuickViewModel) async {
        // a. Load settings from UserDefaults
        var settings = QuickSettings.load()
        // Ambient capture needs one explicit Start in the visible Screen
        // History settings on every launch. A persisted value is not consent
        // to restart recording in the background.
        settings.screenHistoryCaptureConfirmed = false
        viewModel.settings = settings
        // Stored colors are written in whichever notation settings ask for.
        colorHistory.preferredFormat = settings.colorFormat
        await viewModel.prepareScreenHistoryCaptureForBootstrap()
        await viewModel.applyScreenHistoryRetention()
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
            forName: .translatorSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.registerTranslatorHotkey() }
        }
        registerTranslatorHotkey()

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
        // action or explicitly refreshes/checks from Settings.

        // Warm what the first keystrokes will need, off the hotkey path.
        AppIconCache.prewarm(paths: applicationCatalog.applications.map(\.url.path))
        applicationCatalog.loadAlternateNames()
        // Screenshots list for the root badge and an instant catalog entry.
        viewModel.refreshScreenshotFilesInBackground()
    }

    // MARK: - Panel construction

    private func makePanel(viewModel: QuickViewModel) -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: QuickViewModel.panelWidth,
                height: PanelSizing.inputHeight
            ),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.commandKHandler = { [weak viewModel] in
            viewModel?.handleCommandK()
        }
        panel.commandCHandler = { [weak viewModel] in
            guard let viewModel, viewModel.catalogScope != nil else { return false }
            viewModel.copySelectedLauncherItem()
            return true
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
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
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
            width: QuickViewModel.panelWidth,
            height: PanelSizing.inputHeight
        )
        panel.contentViewController = hostingController

        // Center on the display that contains the pointer.
        if let screen = screenContainingMouse() {
            let origin = ScreenPlacement.panelOrigin(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                panelWidth: QuickViewModel.panelWidth,
                inputHeight: PanelSizing.inputHeight
            )
            panel.setFrame(
                NSRect(
                    x: origin.x,
                    y: origin.y,
                    width: QuickViewModel.panelWidth,
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
        overlayClearTask?.cancel()
        overlayClearTask = nil
        overlayRetentionID = nil
        if captureSelectionTarget {
            viewModel?.rememberSelectionTarget(selectedTextService.currentExternalTarget())
            viewModel?.captureImageFromClipboard()
        }
        applicationCatalog.refreshIfNeeded()
        // Keep the Screenshots badge and first entry honest without ever
        // touching the disk on the keystroke path.
        viewModel?.warmScreenshotCatalogIfStale()
        // Re-center on the screen that currently has the mouse cursor.
        if let screen = screenContainingMouse() {
            let origin = ScreenPlacement.panelOrigin(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                panelWidth: QuickViewModel.panelWidth,
                inputHeight: PanelSizing.inputHeight
            )
            // Keep the input row on the centre line whatever the panel's
            // current height: the frame's top edge is what the eye reads.
            var frame = panel.frame
            frame.origin = NSPoint(x: origin.x, y: origin.y - (frame.height - PanelSizing.inputHeight))
            panel.setFrameOrigin(frame.origin)
        }
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
        viewModel?.isActionPalettePresented = false
        viewModel?.isApplicationActionPanePresented = false
        viewModel?.isCatalogActionPanePresented = false
        viewModel?.contextualApplicationID = nil
        viewModel?.contextualCatalogItemID = nil
        viewModel?.actionQuery = ""
        viewModel?.rememberSelectionTarget(nil)

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
        if viewModel.catalogScope != nil || viewModel.pendingQuickLinkID != nil || viewModel.inputMode != nil {
            viewModel.leaveCatalog()
        }
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
        let modifierFlags = NSEvent.ModifierFlags(rawValue: vm.settings.hotkeyModifiers)

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
        let hotkey = vm.settings.clipboardHistoryHotkey
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
        let hotkey = vm.settings.translatorHotkey
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

    /// The Translator window: opened from ⇧⌘T or the Translate item. Arrives
    /// with the selection of the app behind it; toggles closed on repeat.
    func showTranslator() {
        guard let vm = viewModel else { return }
        if let panel = translatorPanel, panel.isVisible {
            hideTranslator()
            return
        }
        let target = selectedTextService.currentExternalTarget()
        let selected = target.flatMap { selectedTextService.capture(from: $0, promptForPermission: false)?.text }
        let model = translatorModel ?? makeTranslatorModel(for: vm)
        translatorModel = model
        model.prepare(target: target, selectedText: selected)
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
    }

    func hideTranslator() {
        translatorPanel?.orderOut(nil)
    }

    private func makeTranslatorModel(for vm: QuickViewModel) -> TranslatorModel {
        let model = TranslatorModel(
            lastTarget: TranslationTarget.named(vm.settings.lastTranslationTarget) ?? .simplifiedChinese,
            serviceFactory: { [weak vm] in vm?.makeCurrentService() },
            selectedTextService: selectedTextService
        )
        model.onTargetChange = { [weak vm] target in
            vm?.settings.lastTranslationTarget = target.code
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
        panel.contentViewController = NSHostingController(
            rootView: TranslatorView(model: model)
                .preferredColorScheme(viewModel?.settings.appearance.swiftUIColorScheme)
        )
        panel.shortcutHandler = { [weak self, weak model] characters, keyCode, modifiers in
            guard let self, let model else { return false }
            let isReturn = keyCode == 36 || keyCode == 76
            if keyCode == 53, modifiers.isEmpty {
                if model.isTargetPickerPresented {
                    model.isTargetPickerPresented = false
                } else if !model.source.isEmpty {
                    model.clear()
                } else {
                    self.hideTranslator()
                }
                return true
            }
            if isReturn, modifiers == [.command] {
                model.copyTranslation()
                self.hideTranslator()
                return true
            }
            if isReturn, modifiers == [.command, .shift] {
                self.hideTranslator()
                Task { @MainActor in _ = await model.pasteBack() }
                return true
            }
            switch (characters?.lowercased(), modifiers) {
            case ("s", [.command]):
                model.swap()
                return true
            case ("p", [.command]):
                model.isTargetPickerPresented.toggle()
                return true
            case ("v", [.command, .shift]):
                model.useClipboardAsSource()
                return true
            case ("w", [.command]):
                self.hideTranslator()
                return true
            default:
                return false
            }
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
            let flags = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
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
        showOverlay(captureSelectionTarget: false)
        Task { await vm.perform(action: action) }
    }

    private func registerLauncherItemHotkeys() {
        guard let vm = viewModel else { return }
        vm.launcherItemHotkeyRegistrationErrors.removeAll()
        for configuration in vm.settings.launcherItemConfigurations {
            guard let hotkey = configuration.hotkey,
                  vm.settings.launcherItemHotkeyConflict(
                    for: configuration.id
                  ) == nil else { continue }

            let flags = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
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
            vm.pendingQuickLinkID = item.id
            vm.catalogScope = nil
            vm.input = ""
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
        let presentation = ScreenHistoryMenuBarPresentation.make(
            status: viewModel.screenHistoryCaptureStatus
        )
        let shouldShow = viewModel.settings.showMenuBar || presentation.forcesVisibility
        if shouldShow {
            setupStatusItem()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            return
        }

        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.accessibilityName
        )
        button.setAccessibilityLabel(presentation.accessibilityName)
    }

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

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let show = NSMenuItem(
            title: "Open Quick Launch",
            action: #selector(showOverlayFromMenu),
            keyEquivalent: " "
        )
        show.keyEquivalentModifierMask = .control
        show.target = self
        menu.addItem(show)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let caffeinate = NSMenuItem(
            title: viewModel?.isCaffeinating == true ? "Turn Caffeinate Off" : "Turn Caffeinate On",
            action: #selector(toggleCaffeinateFromMenu),
            keyEquivalent: ""
        )
        caffeinate.state = viewModel?.isCaffeinating == true ? .on : .off
        caffeinate.target = self
        menu.addItem(caffeinate)

        menu.addItem(.separator())

        let screenHistory = ScreenHistoryStatusPresentation.make(
            status: viewModel?.screenHistoryCaptureStatus
        )
        let screenHistoryStatus = NSMenuItem(
            title: screenHistory.statusTitle,
            action: nil,
            keyEquivalent: ""
        )
        screenHistoryStatus.isEnabled = false
        menu.addItem(screenHistoryStatus)

        let screenHistoryControl = NSMenuItem(
            title: screenHistory.controlTitle,
            action: #selector(stopScreenHistoryFromMenu),
            keyEquivalent: ""
        )
        screenHistoryControl.isEnabled = screenHistory.controlIsEnabled
        screenHistoryControl.target = self
        menu.addItem(screenHistoryControl)

        let welcome = NSMenuItem(
            title: "Show Welcome Again",
            action: #selector(showWelcomeFromMenu),
            keyEquivalent: ""
        )
        welcome.target = self
        menu.addItem(welcome)

        menu.addItem(.separator())

        let version = NSMenuItem(
            title: "Quick Launch v\(Bundle.main.shortVersion)",
            action: nil,
            keyEquivalent: ""
        )
        version.isEnabled = false
        menu.addItem(version)

        let website = NSMenuItem(
            title: "View Quick Launch on GitHub",
            action: #selector(openWebsite),
            keyEquivalent: ""
        )
        website.target = self
        menu.addItem(website)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Quick Launch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        return menu
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
            _ = viewModel.isApplicationActionPanePresented
            _ = viewModel.isCatalogActionPanePresented
            _ = viewModel.catalogScope
            _ = viewModel.isConversationHistoryPresented
            _ = viewModel.actionQuery
            _ = viewModel.input
            _ = viewModel.pendingImage
            _ = viewModel.activeItemActionForm
            _ = viewModel.deleteArmedItemID
            _ = viewModel.lastQuestion
            _ = viewModel.pendingContext
            _ = viewModel.applicationSelectionIndex
            _ = viewModel.screenshotIndexProgress
            _ = viewModel.screenHistoryCaptureStatus
            // Screen History loads frames asynchronously and can flip into
            // the timeline; both change the row count the window must fit.
            _ = viewModel.screenHistoryShowsTimeline
            _ = viewModel.screenHistoryFrames.count
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
        let total = targetPanelHeight(vm)
        let width = vm.currentPanelWidth
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
                self.applyPanelFrame(
                    height: self.targetPanelHeight(vm),
                    width: vm.currentPanelWidth
                )
            }
        }
    }

    private func applyPanelFrame(height: CGFloat, width: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        guard abs(frame.height - height) > 1 || abs(frame.width - width) > 1 else { return }
        let delta = height - frame.height
        let centreX = frame.midX
        frame.size.height = height
        frame.size.width = width
        frame.origin.x = (centreX - width / 2).rounded()
        frame.origin.y -= delta  // grow down from the top
        if let screen = panel.screen ?? screenContainingMouse() {
            frame = ScreenPlacement.clamped(frame: frame, within: screen.visibleFrame)
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    private func targetPanelHeight(_ vm: QuickViewModel) -> CGFloat {
        let visibleBody = vm.conversationMessages.count > 2
            ? vm.conversationTranscriptText
            : vm.output
        // Base height as if no pane were floating: the launcher list stays
        // fully visible behind the ⌘K pane, so opening or closing a pane
        // does not move the window unless the pane itself needs more room.
        let base = PanelSizing.panelHeight(
            output: visibleBody,
            isStreaming: vm.isStreaming,
            errorMessage: vm.errorMessage,
            suggestionCount: max(vm.launcherMatches.count, vm.savedPromptMatches.count),
            showsResultActions: false,
            hasAttachment: vm.hasPendingAttachment,
            showsFooter: vm.showsLauncherFooter,
            launcherRowCount: vm.launcherMatches.count,
            showsQuestion: (vm.lastQuestion?.isEmpty == false) && !vm.isConversationHistoryPresented,
            gridRows: vm.isGridCatalog
                ? Int((Double(vm.launcherMatches.count) / Double(QuickViewModel.gridColumns)).rounded(.up))
                    + max(0, vm.gridSections.count - 1)
                : 0,
            gridSections: vm.isGridCatalog ? vm.gridSections.count : 0,
            showsDetailPane: vm.showsDetailPane
        )
        var pane: CGFloat?
        if vm.isItemActionPanePresented {
            pane = vm.activeItemActionForm.map(PanelSizing.itemActionFormPaneHeight)
                ?? PanelSizing.itemActionPaneHeight(rows: vm.filteredFocusedItemActions.count)
        } else if vm.isActionPalettePresented {
            pane = PanelSizing.actionPaletteHeight(rows: vm.actionPaletteEntryCount)
        }
        var total = PanelSizing.windowHeight(
            base: base,
            paneHeight: pane,
            paneTop: PanelSizing.inputHeight
                + (vm.hasPendingAttachment ? PanelSizing.attachmentHeight : 0)
        )
        if vm.activeItemActionForm == .screenHistorySave {
            total = max(total, PanelSizing.screenHistorySaveMinimumHeight)
        }
        return total
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

    @objc private func stopScreenHistoryFromMenu() {
        Task { @MainActor [weak viewModel] in
            await viewModel?.pauseScreenHistoryCapture()
        }
    }

    @objc private func openWebsite() {
        if let url = URL(string: "https://github.com/tristan-mcinnis/quick-launch") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Settings panel

    func showSettingsPanel() {
        // Settings is a different job. Get the launcher out of the way.
        if panel?.isVisible == true { hideOverlay() }
        if let existing = settingsPanel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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

        let hostingController = NSHostingController(
            rootView: SettingsView(viewModel: vm)
        )
        panel.contentViewController = hostingController
        self.settingsPanel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
