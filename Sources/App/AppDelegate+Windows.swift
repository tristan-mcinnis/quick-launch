import AppKit
import Darwin
import SwiftUI
import HouseDesign

extension AppDelegate {
    /// The direct Quick AI hotkey: capture the app and selection behind the
    /// overlay before it takes focus, then open the Quick AI composer on the
    /// retained draft. Nothing is submitted.
    func showQuickAI() {
        guard let vm = viewModel else { return }
        ShowPathSignpost.hotkeyReceived(quickAI: true)
        vm.presentQuickAIComposerForHotkey()
        showOverlay(captureSelectionTarget: false)
    }

    /// The Translator window: opened from ⇧⌘T or the Translate item. Arrives
    /// with the selection of the app behind it; toggles closed on repeat.
    func showTranslator(retainedSelection handedOffSelection: String? = nil, target requestedTarget: TranslationTarget? = nil) {
        guard let vm = viewModel else { return }
        if let requestedTarget {
            let model = translatorModel ?? makeTranslatorModel(for: vm)
            translatorModel = model
            if model.target != requestedTarget { model.setTarget(requestedTarget, remember: false) }
        }
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
        viewModel?.journalFeatureUse(of: controller)
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
            sourceSelection: SourceSelection(code: vm.settings.translationSourceSelection),
            serviceFactory: { [weak vm] in vm?.makeCurrentService() },
            selectedTextService: selectedTextService,
            pasteboard: vm.pasteboard
        )
        vm.journalFeatureUse(of: model)
        model.onLanguagesChange = { [weak vm, weak model] in
            guard let vm, let model else { return }
            vm.settings.lastTranslationTarget = model.target.code
            vm.settings.lastTranslationSource = model.sourceLanguage.code
            vm.settings.translationSourceSelection = model.sourceSelection.code
            vm.settings.save()
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
                if model.languagePicker != nil {
                    model.languagePicker = nil
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
            case .source:
                model.toggleLanguagePicker(.source)
            case .target:
                model.toggleLanguagePicker(.target)
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
        let panel = StandardEditingPanel(
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
    func launcherScreen() -> NSScreen? {
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
            pageReader: pageReader,
            launcherUsage: launcherUsage,
            interactionJournal: interactionJournal,
            screenshotService: screenshotService,
            screenAwareness: screenAwareness,
            pasteboard: SystemPasteboard(),
            historyFileURL: QuickHistoryStore.defaultFileURL(),
            archiveRootURL: AppPaths.applicationSupportDirectory,
            workspace: SystemWorkspace(),
            runningApplications: SystemRunningApplications(),
            attachmentExtractor: SharedDocumentExtractor(),
            apiKeyProvider: QuickViewModel.keychainAPIKey,
            keychain: SystemKeychainStore(),
            currentVersion: Bundle.main.shortVersion
        )
        chat.memoryService = recall
        chat.memoryCapture = recall
        chat.skillLibrary = SkillLibrary()
        chat.fileOpener = OpenCommandFileOpener()
        chat.attachmentFilePicker = SystemAttachmentFilePicker()
        chat.piHandoff = PiHandoffService()
        if let chatBackends { chat.dropMissingChatBackends(chatBackends) }
        let controller = AIChatWindowController(model: AIChatWindowModel(chat: chat), app: self)
        // The chat window lays itself out. Weak, because the controller owns
        // the window and the view model must never own the controller.
        chat.ownWindowLayout = OwnWindowLayout { [weak controller] in controller?.chatWindow }
        aiChatController = controller
        return controller
    }

    @objc func showAIChatFromMenu() {
        if panel?.isVisible == true { hideOverlay() }
        showAIChat(on: screenContainingMouse())
    }

    /// Mirror of apfel-clip's launch-at-login alert — asked once, persisted.
    @MainActor
    func promptForLaunchAtLogin(viewModel: QuickViewModel) {
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
