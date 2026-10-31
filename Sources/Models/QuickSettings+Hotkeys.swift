import Foundation
import AppKit  // for NSEvent.ModifierFlags

// MARK: - Hotkey display and validation

extension QuickSettings {

    /// Human-readable hotkey label, e.g. "\u{2325}Space" for Option+Space.
    var hotkeyDisplayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: hotkeyModifiers)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("\u{2303}") }
        if flags.contains(.option)  { parts.append("\u{2325}") }
        if flags.contains(.shift)   { parts.append("\u{21E7}") }
        if flags.contains(.command) { parts.append("\u{2318}") }
        parts.append(Self.keyName(for: hotkeyKeyCode))
        return parts.joined()
    }

    /// Whether a hotkey combo is valid (must include Ctrl, Option, or Cmd).
    static func isValidHotkey(keyCode: UInt16, modifiers: UInt) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection(.deviceIndependentFlagsMask)
        return flags.contains(.control)
            || flags.contains(.option)
            || flags.contains(.command)
    }

    /// Map key codes to display names.
    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "\u{21A9}"   // Return
        case 48: return "\u{21E5}"   // Tab
        case 51: return "\u{232B}"   // Delete
        case 53: return "\u{238B}"   // Escape
        case 123: return "\u{2190}"  // Left Arrow
        case 124: return "\u{2192}"  // Right Arrow
        case 125: return "\u{2193}"  // Down Arrow
        case 126: return "\u{2191}"  // Up Arrow
        default:
            let letterMap: [UInt16: String] = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
                8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
                16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
                23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
                30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
                37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
                43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
                50: "`",
            ]
            return letterMap[keyCode] ?? "Key\(keyCode)"
        }
    }

    // MARK: In-app shortcut overrides

    /// The stored overrides as a typed table. An id the build no longer knows
    /// is ignored here even if it survives in the blob.
    var shortcutOverrideTable: [ShortcutAction: ActionHotkey] {
        shortcutOverrides.reduce(into: [:]) { table, entry in
            guard let action = ShortcutAction(rawValue: entry.key) else { return }
            table[action] = entry.value.normalized
        }
    }

    /// The live table every router, hint, and menu equivalent reads. Read
    /// through the settings their owner holds, so a rebind redraws every
    /// surface that names it and no store can see another's keys.
    var shortcuts: ShortcutBindings { ShortcutBindings(overrides: shortcutOverrideTable) }

    /// The key an action answers to now: its override, or its built-in key.
    func shortcutHotkey(for action: ShortcutAction) -> ActionHotkey {
        shortcuts.hotkey(for: action)
    }

    /// Whether the action has been rebound away from its built-in key.
    func isShortcutCustomized(_ action: ShortcutAction) -> Bool {
        shortcuts.isCustomized(action)
    }

    /// Why `candidate` may not be bound to `action`, given every other
    /// setting that owns a key. Nil means it may.
    func shortcutConflict(for action: ShortcutAction, candidate: ActionHotkey) -> String? {
        shortcuts.conflict(for: candidate, action: action, settings: self)
    }

    /// A global hotkey setter's own view of the same question: is this
    /// combination already an in-app shortcut? One place, so the launcher,
    /// the clipboard, the translator, Type to Click, a saved action and a
    /// launcher item all refuse the same keys with the same words.
    ///
    /// The main Quick Launch hotkey is checked by `launcherHotkeyConflict`,
    /// which owns the rest of its own cross-checks.
    func inAppShortcutConflictMessage(for hotkey: ActionHotkey) -> String? {
        guard let action = shortcuts.action(matching: hotkey) else { return nil }
        return "This conflicts with \(action.title)."
    }

    /// Every global hotkey a candidate could collide with, except the main
    /// Quick Launch hotkey and the dedicated ones a caller checks itself.
    /// Shared by the in-app conflict check and by the global setters.
    ///
    /// `excludingPrompt` and `excludingItem` are for the two callers that ask
    /// about one entry in a list: without them the entry's own hotkey would
    /// match itself and be reported as a conflict with itself.
    func globalHotkeyConflictMessage(
        for hotkey: ActionHotkey,
        excludingPrompt promptID: UUID? = nil,
        excludingItem itemID: String? = nil
    ) -> String? {
        let hotkey = hotkey.normalized
        if let inApp = inAppShortcutConflictMessage(for: hotkey) { return inApp }
        if hotkey.keyCode == hotkeyKeyCode,
           hotkey.modifiers == NSEvent.ModifierFlags(rawValue: hotkeyModifiers).overlayRelevant.rawValue {
            return "This conflicts with the main Quick Launch hotkey."
        }
        if hotkey == clipboardHistoryHotkey {
            return "This conflicts with the Clipboard History hotkey."
        }
        if hotkey == translatorHotkey {
            return "This conflicts with the Translator hotkey."
        }
        if typeToClickHotkeyEnabled, hotkey == typeToClickHotkey {
            return "This conflicts with the Type to Click hotkey."
        }
        if quickAIHotkeyEnabled, hotkey == quickAIHotkey.normalized {
            return "This conflicts with the Quick AI hotkey."
        }
        if let prompt = savedPrompts.first(where: {
            $0.id != promptID && $0.hotkey?.normalized == hotkey
        }) {
            return "This conflicts with \(prompt.name) quick action."
        }
        if let configuration = launcherItemConfigurations.first(where: {
            $0.itemID != itemID && $0.hotkey?.normalized == hotkey
        }) {
            return "This conflicts with the \(configuration.itemID) launcher hotkey."
        }
        return nil
    }

    /// Why the main Quick Launch hotkey may not be used. It is the one global
    /// hotkey with no conflict function of its own until now: every other
    /// reserved combination was checked, this one was not.
    func launcherHotkeyConflict() -> String? {
        let hotkey = ActionHotkey(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers).normalized
        guard hotkey.isValidShortcut else { return nil }
        if let inApp = inAppShortcutConflictMessage(for: hotkey) { return inApp }
        if hotkey == clipboardHistoryHotkey { return "This conflicts with the Clipboard History hotkey." }
        if hotkey == translatorHotkey { return "This conflicts with the Translator hotkey." }
        if typeToClickHotkeyEnabled, hotkey == typeToClickHotkey {
            return "This conflicts with the Type to Click hotkey."
        }
        if quickAIHotkeyEnabled, hotkey == quickAIHotkey.normalized {
            return "This conflicts with the Quick AI hotkey."
        }
        if let prompt = savedPrompts.first(where: { $0.hotkey?.normalized == hotkey }) {
            return "This conflicts with the \(prompt.name) quick action."
        }
        if let configuration = launcherItemConfigurations.first(where: {
            $0.hotkey?.normalized == hotkey
        }) {
            return "This conflicts with the \(configuration.itemID) launcher hotkey."
        }
        return nil
    }

    /// Rebinds one action. Recording the built-in key, or nil, clears the
    /// override instead of storing a no-op entry, and is never refused: it is
    /// the key the app ships on, and a launcher row may legitimately share it.
    /// Anything else that is not a usable shortcut, or that collides with a
    /// fixed key, another action, or a global hotkey, is refused and the
    /// settings are left alone. Returns the refusal message, if any.
    @discardableResult
    mutating func setShortcut(_ hotkey: ActionHotkey?, for action: ShortcutAction) -> String? {
        guard let hotkey else {
            shortcutOverrides[action.rawValue] = nil
            return nil
        }
        let normalized = hotkey.normalized
        guard normalized.isValidShortcut else { return "Must include Ctrl, Option, or Cmd" }
        if normalized == action.defaultHotkey {
            shortcutOverrides[action.rawValue] = nil
            return nil
        }
        if let conflict = shortcutConflict(for: action, candidate: normalized) {
            return conflict
        }
        shortcutOverrides[action.rawValue] = normalized
        return nil
    }

    /// Back to the built-in key for one action.
    mutating func resetShortcut(_ action: ShortcutAction) {
        shortcutOverrides[action.rawValue] = nil
    }

    /// Back to every built-in key.
    mutating func resetAllShortcuts() {
        shortcutOverrides.removeAll()
    }

    /// The actions the user has rebound.
    var customizedShortcuts: [ShortcutAction] { shortcuts.customized }

    func actionHotkeyConflict(for actionID: UUID) -> String? {
        guard let action = savedPrompts.first(where: { $0.id == actionID }),
              let hotkey = action.hotkey else { return nil }
        // An in-app shortcut first: a saved action that takes one is swallowed
        // by the launcher whenever it is open, which is exactly when it is used.
        if let inApp = inAppShortcutConflictMessage(for: hotkey) { return inApp }
        // Another saved action before the shared checks, so the message names
        // that action instead of saying "a quick action" or, worse, matching
        // this one against itself.
        if let other = savedPrompts.first(where: {
            $0.id != actionID && $0.hotkey?.normalized == hotkey.normalized
        }) {
            return "This conflicts with \(other.name)."
        }
        return globalHotkeyConflictMessage(for: hotkey, excludingPrompt: actionID)
    }

    func launcherItemConfiguration(
        kind: LauncherItemKind,
        itemID: String
    ) -> LauncherItemConfiguration? {
        launcherItemConfigurations.first {
            $0.kind == kind && $0.itemID == itemID
        }
    }

    func launcherItemHotkeyConflict(for configurationID: String) -> String? {
        guard let configuration = launcherItemConfigurations.first(where: {
            $0.id == configurationID
        }), let hotkey = configuration.hotkey else { return nil }

        if let inApp = inAppShortcutConflictMessage(for: hotkey) { return inApp }
        if savedPrompts.contains(where: { $0.hotkey?.normalized == hotkey.normalized }) {
            return "This conflicts with a quick-action hotkey."
        }
        if launcherItemConfigurations.contains(where: {
            $0.id != configurationID && $0.hotkey?.normalized == hotkey.normalized
        }) {
            return "This conflicts with another launcher item."
        }
        return globalHotkeyConflictMessage(for: hotkey, excludingItem: configuration.itemID)
    }

    /// The Translator is global and set beside the launcher hotkey; it checks
    /// the in-app table and every other global key, and excludes itself.
    func translatorHotkeyConflict() -> String? {
        let hotkey = translatorHotkey
        if let inApp = inAppShortcutConflictMessage(for: hotkey) { return inApp }
        if hotkey.keyCode == hotkeyKeyCode,
           hotkey.modifiers == NSEvent.ModifierFlags(rawValue: hotkeyModifiers).overlayRelevant.rawValue {
            return "This conflicts with the main Quick Launch hotkey."
        }
        if hotkey == clipboardHistoryHotkey { return "This conflicts with the Clipboard History hotkey." }
        if typeToClickHotkeyEnabled, hotkey == typeToClickHotkey {
            return "This conflicts with the Type to Click hotkey."
        }
        if quickAIHotkeyEnabled, hotkey.normalized == quickAIHotkey.normalized {
            return "This conflicts with the Quick AI hotkey."
        }
        if savedPrompts.contains(where: { $0.hotkey?.normalized == hotkey.normalized }) {
            return "This conflicts with a quick-action hotkey."
        }
        if launcherItemConfigurations.contains(where: { $0.hotkey?.normalized == hotkey.normalized }) {
            return "This conflicts with a launcher item hotkey."
        }
        return nil
    }

    func typeToClickHotkeyConflict() -> String? {
        guard typeToClickHotkeyEnabled else { return nil }
        let hotkey = typeToClickHotkey
        if let inApp = inAppShortcutConflictMessage(for: hotkey) { return inApp }
        if hotkey.keyCode == hotkeyKeyCode,
           hotkey.modifiers == NSEvent.ModifierFlags(rawValue: hotkeyModifiers).overlayRelevant.rawValue {
            return "This conflicts with the main Quick Launch hotkey."
        }
        if hotkey == clipboardHistoryHotkey { return "This conflicts with the Clipboard History hotkey." }
        if hotkey == translatorHotkey { return "This conflicts with the Translator hotkey." }
        if quickAIHotkeyEnabled, hotkey.normalized == quickAIHotkey.normalized {
            return "This conflicts with the Quick AI hotkey."
        }
        if savedPrompts.contains(where: { $0.hotkey?.normalized == hotkey.normalized }) {
            return "This conflicts with a quick-action hotkey."
        }
        if launcherItemConfigurations.contains(where: {
            $0.itemID != "type-to-click.mode" && $0.hotkey?.normalized == hotkey.normalized
        }) { return "This conflicts with a launcher item hotkey." }
        return nil
    }

    func clipboardHistoryHotkeyConflict() -> String? {
        let hotkey = clipboardHistoryHotkey
        if let inApp = inAppShortcutConflictMessage(for: hotkey) { return inApp }
        if hotkey.keyCode == hotkeyKeyCode,
           hotkey.modifiers == NSEvent.ModifierFlags(rawValue: hotkeyModifiers).overlayRelevant.rawValue {
            return "This conflicts with the main Quick Launch hotkey."
        }
        if hotkey == translatorHotkey {
            return "This conflicts with the Translator hotkey."
        }
        if typeToClickHotkeyEnabled, hotkey == typeToClickHotkey {
            return "This conflicts with the Type to Click hotkey."
        }
        if quickAIHotkeyEnabled, hotkey.normalized == quickAIHotkey.normalized {
            return "This conflicts with the Quick AI hotkey."
        }
        if savedPrompts.contains(where: { $0.hotkey?.normalized == hotkey.normalized }) {
            return "This conflicts with a quick-action hotkey."
        }
        if launcherItemConfigurations.contains(where: { $0.hotkey?.normalized == hotkey.normalized }) {
            return "This conflicts with a launcher item hotkey."
        }
        return nil
    }

    /// The optional direct Quick AI hotkey: off by default, so a disabled one
    /// never conflicts with anything. Enabled, it checks the in-app table and
    /// every other global key, and excludes itself.
    func quickAIHotkeyConflict() -> String? {
        guard quickAIHotkeyEnabled else { return nil }
        let hotkey = quickAIHotkey.normalized
        if let inApp = inAppShortcutConflictMessage(for: hotkey) { return inApp }
        if hotkey.keyCode == hotkeyKeyCode,
           hotkey.modifiers == NSEvent.ModifierFlags(rawValue: hotkeyModifiers).overlayRelevant.rawValue {
            return "This conflicts with the main Quick Launch hotkey."
        }
        if hotkey == clipboardHistoryHotkey.normalized {
            return "This conflicts with the Clipboard History hotkey."
        }
        if hotkey == translatorHotkey.normalized {
            return "This conflicts with the Translator hotkey."
        }
        if typeToClickHotkeyEnabled, hotkey == typeToClickHotkey.normalized {
            return "This conflicts with the Type to Click hotkey."
        }
        if savedPrompts.contains(where: { $0.hotkey?.normalized == hotkey }) {
            return "This conflicts with a quick-action hotkey."
        }
        if launcherItemConfigurations.contains(where: {
            $0.itemID != "type-to-click.mode" && $0.hotkey?.normalized == hotkey
        }) { return "This conflicts with a launcher item hotkey." }
        return nil
    }
}
