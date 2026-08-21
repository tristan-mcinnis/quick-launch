import AppKit
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
    private var actionHotKeys: [UUID: GlobalHotKey] = [:]
    private var launcherItemHotKeys: [String: GlobalHotKey] = [:]
    private var localMonitor: Any?
    private var mouseMonitor: Any?
    private var statusItem: NSStatusItem?
    private var overlayClearTask: Task<Void, Never>?
    private var overlayRetentionID: UUID?

    private let serverManager = ServerManager()
    private let selectedTextService = SelectedTextService()
    private let applicationCatalog = ApplicationCatalogService()
    private let launcherCatalog = TunaCatalogService()
    private let clipboardHistory = ClipboardHistoryStore()
    private let webSearchService = SearXNGSearchService()

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vm = QuickViewModel(
            selectedTextService: selectedTextService,
            applicationCatalog: applicationCatalog,
            launcherCatalog: launcherCatalog,
            clipboardHistory: clipboardHistory,
            webSearchService: webSearchService,
            currentVersion: Bundle.main.shortVersion
        )
        self.viewModel = vm

        Task { @MainActor [weak self] in
            await self?.bootstrap(viewModel: vm)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayClearTask?.cancel()
        globalHotKey?.invalidate()
        clipboardHistoryHotKey?.invalidate()
        clipboardHistory.stopMonitoring()
        actionHotKeys.values.forEach { $0.invalidate() }
        actionHotKeys.removeAll()
        launcherItemHotKeys.values.forEach { $0.invalidate() }
        launcherItemHotKeys.removeAll()
        if let monitor = localMonitor  { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseMonitor  { NSEvent.removeMonitor(monitor) }
        serverManager.stop()
    }

    // MARK: - Bootstrap

    private func bootstrap(viewModel: QuickViewModel) async {
        // a. Load settings from UserDefaults
        let settings = QuickSettings.load()
        viewModel.settings = settings
        viewModel.settings.save()
        viewModel.loadHistory()
        configureClipboardHistory()

        // b. Create NSPanel with OverlayView hosted in NSHostingController
        let panel = makePanel(viewModel: viewModel)
        self.panel = panel

        // c. Register global hotkey (Option+Space by default)
        registerGlobalHotkey()
        registerActionHotkeys()
        registerLauncherItemHotkeys()

        // d. Register local mouse monitor for click-outside dismissal
        registerMouseDismissMonitor()

        // e. Setup status bar item if settings.showMenuBar
        if settings.showMenuBar {
            setupStatusItem()
        }

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

        // Open settings in its own panel (not .sheet — avoids gray corner artifact)
        NotificationCenter.default.addObserver(
            forName: .openSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.showSettingsPanel() }
        }

        NotificationCenter.default.addObserver(
            forName: .providerChanged,
            object: nil,
            queue: .main
        ) { [weak self, weak viewModel] _ in
            Task { @MainActor [weak self, weak viewModel] in
                guard let self, let viewModel else { return }
                if viewModel.settings.selectedProvider?.kind == .managedApfel {
                    self.startManagedService(for: viewModel)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .managedServiceRequested,
            object: nil,
            queue: .main
        ) { [weak self, weak viewModel] _ in
            Task { @MainActor [weak self, weak viewModel] in
                guard let self, let viewModel else { return }
                self.startManagedService(for: viewModel)
            }
        }

        // Panel auto-resize: observe viewModel state and grow/shrink the panel
        // to fit the current overlay content.
        startPanelSizeObserver(viewModel: viewModel)

        // f. Show WelcomeOverlayView FIRST — before we block on server start
        //    so the user sees UI immediately on first run.
        if !settings.hasSeenWelcome {
            showWelcomePanel()
        } else if !settings.launchAtLoginPromptShown {
            // Welcome already seen on a prior launch but login prompt never shown
            // (upgrade path) — show it now.
            promptForLaunchAtLogin(viewModel: viewModel)
        }

        // Provider and network work remain dormant until the user runs an
        // action or explicitly refreshes/checks from Settings.
    }

    private func startManagedService(for viewModel: QuickViewModel) {
        guard viewModel.service == nil else { return }
        Task { [weak self, weak viewModel] in
            guard let self, let viewModel else { return }
            if let port = await self.serverManager.start() {
                await MainActor.run {
                    viewModel.service = ApfelQuickService(
                        port: port,
                        systemPrompt: viewModel.settings.systemPrompt
                    )
                }
            }
        }
    }

    // MARK: - Panel construction

    private func makePanel(viewModel: QuickViewModel) -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 60),
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
                .frame(width: 620)
        )
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 620, height: 60)
        panel.contentViewController = hostingController

        // Center on the display that contains the pointer.
        if let screen = screenContainingMouse() {
            let width: CGFloat = 620
            let x = screen.frame.midX - width / 2
            let y = screen.frame.maxY - screen.frame.height * 0.35
            panel.setFrame(NSRect(x: x, y: y, width: width, height: 60), display: false)
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
        }
        // Re-center on the screen that currently has the mouse cursor.
        if let screen = screenContainingMouse() {
            let width: CGFloat = 620
            let x = screen.frame.midX - width / 2
            let y = screen.frame.maxY - screen.frame.height * 0.35
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        let shouldAnimate = !panel.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate { panel.alphaValue = 0.88 }
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        viewModel?.requestInputFocus()
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                context.allowsImplicitAnimation = true
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
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
            viewModel.clearTransientDisplay()
            return
        }
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
            viewModel.clearTransientDisplay()
            self.overlayClearTask = nil
            self.overlayRetentionID = nil
        }
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

        if let conflict = QuickSettings.knownSystemHotkeyConflict(
            keyCode: keyCode,
            modifiers: vm.settings.hotkeyModifiers
        ) {
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
            ? "That shortcut is already used by macOS or another app."
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
            _ = applicationCatalog.launch(application)
            return
        }
        guard let item = vm.catalogItem(
            kind: configuration.kind,
            itemID: configuration.itemID
        ) else { return }
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: "bolt.fill",
                accessibilityDescription: "Quick Launch"
            )
            button.imagePosition = .imageOnly
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
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
        } onChange: { [weak self, weak viewModel] in
            Task { @MainActor in
                guard let self, let viewModel else { return }
                self.resizePanelForContent()
                self.armPanelSizeObserver(viewModel: viewModel)
            }
        }
    }

    private func resizePanelForContent() {
        guard let panel, let vm = viewModel else { return }
        let visibleBody = vm.isConversationHistoryPresented
            ? vm.conversationTranscriptText
            : vm.output
        let total = PanelSizing.panelHeight(
            output: visibleBody,
            isStreaming: vm.isStreaming,
            errorMessage: vm.errorMessage,
            actionCount: (vm.isApplicationActionPanePresented || vm.isCatalogActionPanePresented)
                ? 3
                : (vm.isActionPalettePresented ? vm.actionMatches.count : 0),
            suggestionCount: (vm.isActionPalettePresented || vm.isApplicationActionPanePresented || vm.isCatalogActionPanePresented)
                ? 0
                : max(vm.launcherMatches.count, vm.savedPromptMatches.count),
            showsResultActions: !vm.output.isEmpty && !vm.isStreaming
        )
        var frame = panel.frame
        if abs(frame.height - total) > 1 {
            let delta = total - frame.height
            frame.size.height = total
            frame.origin.y -= delta  // grow down from the top
            panel.setFrame(frame, display: true, animate: false)
        }
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

    @objc private func openWebsite() {
        if let url = URL(string: "https://github.com/tristan-mcinnis/quick-launch") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Settings panel

    func showSettingsPanel() {
        if let existing = settingsPanel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let vm = viewModel else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.floating.rawValue) + 2)
        panel.isReleasedWhenClosed = false
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
