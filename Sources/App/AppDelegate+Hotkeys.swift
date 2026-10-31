import AppKit
import Darwin
import SwiftUI
import HouseDesign

extension AppDelegate {
    // MARK: - Global hotkey (configurable, default Option+Space)

    func registerGlobalHotkey() {
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
            self?.toggleOverlay(fromHotkey: true)
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

    func configureClipboardHistory() {
        guard let vm = viewModel else { return }
        // Capture policy first, so a capture that lands while the hotkey is
        // being re-registered already honours the source exclusions and OCR
        // setting.
        clipboardHistory.setPolicy(vm.settings.clipboardCapturePolicy)
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

    func registerTranslatorHotkey() {
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

    func registerTypeToClickHotkey() {
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

    /// The optional direct Quick AI hotkey. Off by default; when enabled it
    /// opens the Quick AI composer on the app and selection behind, without
    /// sending. Re-read every settings change, and never leaves a stale
    /// registration behind: the old hotkey is invalidated first.
    func registerQuickAIHotkey() {
        quickAIHotKey?.invalidate()
        quickAIHotKey = nil
        guard let vm = viewModel else { return }
        switch QuickAIHotkeyRegistration.decide(settings: vm.settings) {
        case .disabled:
            vm.quickAIHotkeyRegistrationError = nil
        case .refused(let message):
            vm.quickAIHotkeyRegistrationError = message
        case .register(let hotkey):
            let flags = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
            quickAIHotKey = GlobalHotKey(
                keyCode: UInt32(hotkey.keyCode),
                modifiers: GlobalHotKey.carbonModifiers(from: flags)
            ) { [weak self] in
                self?.showQuickAI()
            }
            vm.quickAIHotkeyRegistrationError = quickAIHotKey == nil
                ? "That shortcut is already used by macOS or another app."
                : nil
        }
    }

    private func showClipboardHistory() {
        guard let vm = viewModel else { return }
        vm.rememberSelectionTarget(selectedTextService.currentExternalTarget())
        vm.enterCatalog(.clipboard)
        showOverlay(captureSelectionTarget: false)
    }

    func registerActionHotkeys() {
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

    func reregisterActionHotkeys() {
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
        vm.noteDirectHotkeyUse(ofAction: action)
        showOverlay(captureSelectionTarget: false)
        Task { await vm.perform(action: action) }
    }

    func registerLauncherItemHotkeys() {
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

    func reregisterLauncherItemHotkeys() {
        launcherItemHotKeys.values.forEach { $0.invalidate() }
        launcherItemHotKeys.removeAll()
        registerLauncherItemHotkeys()
    }
}
