import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// The optional direct Quick AI hotkey: disabled by default, free when
/// enabled, configurable, and never sending. The Carbon registration itself
/// is behind `QuickAIHotkeyRegistration.decide`, which this suite drives.
@Suite("Quick AI hotkey", .serialized)
@MainActor
struct QuickAIHotkeyTests {

    @Test func disabledByDefaultAndItsKeyIsFree() {
        let settings = QuickSettings()
        #expect(!settings.quickAIHotkeyEnabled)
        #expect(settings.quickAIHotkeyConflict() == nil)

        let key = settings.quickAIHotkey
        #expect(key.isValidShortcut)
        #expect(key == ActionHotkey(keyCode: 49, modifiers: 1_048_576 | 524_288))

        // Free against every other shipped key, when it is enabled.
        var other = QuickSettings()
        other.quickAIHotkeyEnabled = true
        #expect(other.quickAIHotkeyConflict() == nil)
        #expect(key != ActionHotkey(keyCode: other.hotkeyKeyCode, modifiers: other.hotkeyModifiers))
        #expect(key != other.clipboardHistoryHotkey)
        #expect(key != other.translatorHotkey)
        #expect(key != other.typeToClickHotkey)
        for action in ShortcutAction.allCases {
            #expect(key != action.defaultHotkey, "\(action.rawValue) shares the Quick AI key")
        }
        for prompt in other.savedPrompts {
            if let hotkey = prompt.hotkey { #expect(key != hotkey) }
        }
        for item in other.launcherItemConfigurations {
            if let hotkey = item.hotkey { #expect(key != hotkey) }
        }
    }

    @Test func registrationDecisionReadsTheSettingsEachTime() {
        var settings = QuickSettings()
        #expect(QuickAIHotkeyRegistration.decide(settings: settings) == .disabled)

        settings.quickAIHotkeyEnabled = true
        #expect(QuickAIHotkeyRegistration.decide(settings: settings)
            == .register(settings.quickAIHotkey.normalized))

        // A key the launcher already owns is refused, not registered.
        settings.quickAIHotkey = ActionHotkey(
            keyCode: settings.hotkeyKeyCode,
            modifiers: settings.hotkeyModifiers
        )
        guard case .refused(let message) = QuickAIHotkeyRegistration.decide(settings: settings) else {
            Issue.record("expected the launcher key to be refused")
            return
        }
        #expect(message.contains("Quick Launch"))

        // Re-deciding with the same settings is idempotent, and a new key
        // re-registers rather than leaving the old one behind.
        settings.quickAIHotkey = ActionHotkey(
            keyCode: 40,
            modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue
        )
        #expect(QuickAIHotkeyRegistration.decide(settings: settings)
            == .register(settings.quickAIHotkey.normalized))
        #expect(QuickAIHotkeyRegistration.decide(settings: settings)
            == .register(settings.quickAIHotkey.normalized))
    }

    @Test func enabledKeyRoundTripsThroughCodable() throws {
        var settings = QuickSettings()
        settings.quickAIHotkeyEnabled = true
        settings.quickAIHotkey = ActionHotkey(
            keyCode: 40,
            modifiers: NSEvent.ModifierFlags([.command, .control]).rawValue
        )
        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(QuickSettings.self, from: data)
        #expect(back.quickAIHotkeyEnabled)
        #expect(back.quickAIHotkey == settings.quickAIHotkey)
    }

    @Test func aBlobWithoutTheFieldDecodesDisabled() throws {
        // A settings blob written before the direct hotkey existed.
        let data = try JSONEncoder().encode(QuickSettings())
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object.removeValue(forKey: "quickAIHotkey")
        object.removeValue(forKey: "quickAIHotkeyEnabled")
        let decoded = try JSONDecoder().decode(
            QuickSettings.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(!decoded.quickAIHotkeyEnabled)
        #expect(decoded.quickAIHotkey.isValidShortcut)
        #expect(decoded.quickAIHotkeyConflict() == nil)
    }

    @Test func otherGlobalSettersRefuseTheQuickAIKey() {
        var settings = QuickSettings()
        settings.quickAIHotkeyEnabled = true
        let key = settings.quickAIHotkey

        var launcher = QuickSettings()
        launcher.quickAIHotkeyEnabled = true
        launcher.hotkeyKeyCode = key.keyCode
        launcher.hotkeyModifiers = key.modifiers
        #expect(launcher.launcherHotkeyConflict()?.contains("Quick AI") == true)

        var clipboard = QuickSettings()
        clipboard.quickAIHotkeyEnabled = true
        clipboard.clipboardHistoryHotkey = key
        #expect(clipboard.clipboardHistoryHotkeyConflict()?.contains("Quick AI") == true)

        var translator = QuickSettings()
        translator.quickAIHotkeyEnabled = true
        translator.translatorHotkey = key
        #expect(translator.translatorHotkeyConflict()?.contains("Quick AI") == true)

        var typeToClick = QuickSettings()
        typeToClick.quickAIHotkeyEnabled = true
        typeToClick.typeToClickHotkey = key
        #expect(typeToClick.typeToClickHotkeyConflict()?.contains("Quick AI") == true)

        // An in-app rebind may not take it either.
        var inApp = QuickSettings()
        inApp.quickAIHotkeyEnabled = true
        #expect(inApp.setShortcut(key, for: .newChat) == "This conflicts with the Quick AI hotkey.")
    }

    @Test func launcherSavedActionAndTypeToClickKeysAreUnchangedByDefault() {
        // Turning the direct hotkey on and off touches nothing else.
        let settings = QuickSettings()
        #expect(!settings.quickAIHotkeyEnabled)
        #expect(settings.launcherHotkeyConflict() == nil)
        #expect(settings.translatorHotkeyConflict() == nil)
        #expect(settings.typeToClickHotkeyConflict() == nil)
        #expect(settings.clipboardHistoryHotkeyConflict() == nil)
        for prompt in settings.savedPrompts where prompt.hotkey != nil {
            #expect(settings.actionHotkeyConflict(for: prompt.id) == nil)
        }
        for item in settings.launcherItemConfigurations where item.hotkey != nil {
            #expect(settings.launcherItemHotkeyConflict(for: item.id) == nil)
        }
    }

    @Test func directHotkeyOpensQuickAIWithoutSubmitting() {
        let selection = DirectQuickAISelection()
        selection.target = SelectionTarget(processIdentifier: 7, applicationName: "Notes")
        selection.text = "selected words"
        let vm = QuickViewModel(selectedTextService: selection)
        vm.input = "a retained draft"

        vm.presentQuickAIComposerForHotkey()

        #expect(vm.isQuickAIPresented)
        #expect(vm.input == "a retained draft", "the retained draft is kept")
        #expect(vm.launchSelection?.text == "selected words")
        #expect(vm.launchSelection?.appName == "Notes")
        #expect(selection.captureCount == 1)
        // Nothing is sent.
        #expect(vm.composerSubmitTask == nil)
        #expect(!vm.isStreaming)
        #expect(vm.output.isEmpty)
    }

    @Test func directHotkeyWithoutAReadableSelectionStillOpensTheComposer() {
        let selection = DirectQuickAISelection()
        selection.target = nil
        selection.text = nil
        let vm = QuickViewModel(selectedTextService: selection)

        vm.presentQuickAIComposerForHotkey()

        #expect(vm.isQuickAIPresented)
        #expect(vm.launchSelection == nil)
        #expect(vm.composerSubmitTask == nil)
    }
}

/// A selection service for the direct-open tests: it can report a target and
/// a selection, and records how often it was asked to capture.
@MainActor
private final class DirectQuickAISelection: SelectedTextServicing {
    var target: SelectionTarget?
    var text: String?
    private(set) var captureCount = 0

    var isAccessibilityTrusted: Bool { true }

    func currentExternalTarget() -> SelectionTarget? { target }

    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        captureCount += 1
        guard let text else { return nil }
        return SelectedTextContext(target: target, text: text)
    }

    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }

    func paste(_ text: String, to target: SelectionTarget) async -> Bool { true }

    func openAccessibilitySettings() {}
}
