import AppKit
import Foundation

/// The Translator window's own key table. The panel's key handler, the footer
/// hints, the target chip, its tooltip and the source placeholder all read it,
/// so a rebind renames every place at once.
///
/// ⌘P is not here: it opens Recent Chats in Quick AI and the chat list in AI
/// Chat, so the target language is ⌘T. Escape is not here either: it steps
/// back (list, then text, then window), handled by the panel.
enum TranslatorKey: CaseIterable, Equatable, Sendable {
    /// ⌘↩: copy the translation and close.
    case copy
    /// ⇧⌘↩: close and paste the translation into the app behind.
    case pasteBack
    /// ⌘S: swap the source and the translation.
    case swap
    /// ⌘T: open or close the target-language list.
    case target
    /// ⇧⌘V: use the clipboard as the source.
    case useClipboard
    /// ⌘W: close the window.
    case close

    var shortcut: KeyShortcut {
        switch self {
        case .copy: .commandReturn
        case .pasteBack: .commandShiftReturn
        case .swap: .command("s")
        case .target: .command("t")
        case .useClipboard: .commandShift("v")
        case .close: .command("w")
        }
    }

    /// The footer label, or nil for a key the footer does not list.
    var hintLabel: String? {
        switch self {
        case .copy: "Copy"
        case .pasteBack: "Paste back"
        case .swap: "Swap"
        case .target: "Target"
        case .useClipboard, .close: nil
        }
    }

    /// The key this window binds to a key event, if any. `characters` is
    /// `NSEvent.charactersIgnoringModifiers`.
    static func matching(
        characters: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> TranslatorKey? {
        allCases.first {
            $0.shortcut.matches(characters: characters, keyCode: keyCode, modifiers: modifiers)
        }
    }

    /// The tooltip on the target chip: "Change target language (⌘T)".
    static var targetHelp: String {
        "Change target language (\(TranslatorKey.target.shortcut.keyCaps.joined()))"
    }

    /// The empty source field: "Type or paste text. ⇧⌘V uses the clipboard."
    static var sourcePlaceholder: String {
        "Type or paste text. \(TranslatorKey.useClipboard.shortcut.keyCaps.joined()) uses the clipboard."
    }
}

extension TranslatorModel {
    /// The word beside the footer's status dot, as the launcher footer's
    /// context: "Translator", or "Target Language" while the list is open.
    var footerContext: String {
        isTargetPickerPresented ? "Target Language" : "Translator"
    }

    /// The footer's key hints, in the launcher footer's own hint type. They
    /// come from `TranslatorKey`, so the footer names the keys that work.
    var footerHints: [QuickViewModel.FooterHint] {
        if isTargetPickerPresented {
            return [
                QuickViewModel.FooterHint(label: "Choose", keys: KeyShortcut.returnKey.keyCaps),
                QuickViewModel.FooterHint(label: "Back", keys: ["esc"]),
            ]
        }
        let keys = TranslatorKey.allCases.compactMap { key in
            key.hintLabel.map { QuickViewModel.FooterHint(label: $0, keys: key.shortcut.keyCaps) }
        }
        return keys + [QuickViewModel.FooterHint(label: "Close", keys: ["esc"])]
    }
}
