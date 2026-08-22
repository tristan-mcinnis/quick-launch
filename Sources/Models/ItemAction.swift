import AppKit
import Foundation

/// A keyboard shortcut shown as key caps and matched against key events.
struct KeyShortcut: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        case character(Character)
        case `return`
    }

    let key: Key
    /// `NSEvent.ModifierFlags` raw value, device-independent bits only.
    let modifiers: UInt

    static func command(_ character: Character) -> KeyShortcut {
        KeyShortcut(key: .character(character), modifiers: NSEvent.ModifierFlags.command.rawValue)
    }

    static func commandShift(_ character: Character) -> KeyShortcut {
        KeyShortcut(
            key: .character(character),
            modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
        )
    }

    static func control(_ character: Character) -> KeyShortcut {
        KeyShortcut(key: .character(character), modifiers: NSEvent.ModifierFlags.control.rawValue)
    }

    static let returnKey = KeyShortcut(key: .return, modifiers: 0)
    static let commandReturn = KeyShortcut(key: .return, modifiers: NSEvent.ModifierFlags.command.rawValue)
    static let commandShiftReturn = KeyShortcut(
        key: .return,
        modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )

    var keyCaps: [String] {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var caps: [String] = []
        if flags.contains(.control) { caps.append("\u{2303}") }
        if flags.contains(.option) { caps.append("\u{2325}") }
        if flags.contains(.shift) { caps.append("\u{21E7}") }
        if flags.contains(.command) { caps.append("\u{2318}") }
        switch key {
        case .character(let character): caps.append(String(character).uppercased())
        case .return: caps.append("\u{21A9}")
        }
        return caps
    }

    /// `characters` is `NSEvent.charactersIgnoringModifiers`; `keyCode` 36 is Return.
    func matches(characters: String?, keyCode: UInt16, modifiers flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        guard relevant.rawValue == modifiers else { return false }
        switch key {
        case .return:
            return keyCode == 36 || keyCode == 76
        case .character(let character):
            return characters?.lowercased() == String(character).lowercased()
        }
    }
}

enum ItemActionKind: String, Sendable, CaseIterable {
    /// Return: open, paste, run, or browse.
    case primary
    /// ⌘↩: copy, reveal, or copy link.
    case secondary
    case copyAndPaste
    case edit
    case setAlias
    case setHotkey
    case delete
    case copyPath
    case pin
    case saveAsSnippet
    case saveAsQuickLink
    case revealInFinder
    case quickLook
}

/// One row in the ⌘K pane. The same table drives direct shortcuts from the
/// list, so a key does the same thing whether or not the pane is open.
struct ItemAction: Identifiable, Equatable, Sendable {
    let kind: ItemActionKind
    let title: String
    let systemImage: String
    let shortcut: KeyShortcut?
    var isDestructive: Bool = false

    var id: String { kind.rawValue }
}

/// Raycast conventions: Return is the primary action, ⌘↩ the secondary,
/// ⌘E edits, ⌃X deletes, ⌘⇧A and ⌘⇧H configure alias and hotkey.
enum ItemActionCatalog {
    static func actions(for result: LauncherSearchResult, pasteTarget: String?) -> [ItemAction] {
        switch result {
        case .catalog:
            return [ItemAction(kind: .primary, title: "Browse", systemImage: "folder", shortcut: .returnKey)]
        case .application:
            return [
                ItemAction(kind: .primary, title: "Open", systemImage: "arrow.up.forward.app", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Show in Finder", systemImage: "folder", shortcut: .commandReturn),
                ItemAction(kind: .copyPath, title: "Copy Path", systemImage: "doc.on.doc", shortcut: .commandShift("c")),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
            ]
        case .item(let item):
            return actions(for: item, pasteTarget: pasteTarget)
        }
    }

    private static func actions(for item: LauncherCatalogItem, pasteTarget: String?) -> [ItemAction] {
        let pasteTitle = pasteTarget.map { "Paste to \($0)" } ?? "Paste to Active App"
        switch item.kind {
        case .snippet:
            return [
                ItemAction(kind: .primary, title: pasteTitle, systemImage: "arrow.turn.down.right", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Copy to Clipboard", systemImage: "doc.on.doc", shortcut: .commandReturn),
                ItemAction(kind: .copyAndPaste, title: "Copy & Paste", systemImage: "doc.on.clipboard", shortcut: .commandShiftReturn),
                ItemAction(kind: .edit, title: "Edit Snippet", systemImage: "pencil", shortcut: .command("e")),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
                ItemAction(kind: .delete, title: "Delete Snippet", systemImage: "trash", shortcut: .control("x"), isDestructive: true),
            ]
        case .clipboard:
            var actions = [
                ItemAction(kind: .primary, title: pasteTitle, systemImage: "arrow.turn.down.right", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Copy to Clipboard", systemImage: "doc.on.doc", shortcut: .commandReturn),
                ItemAction(kind: .copyAndPaste, title: "Copy & Paste", systemImage: "doc.on.clipboard", shortcut: .commandShiftReturn),
                ItemAction(
                    kind: .pin,
                    title: item.isPinned ? "Unpin" : "Pin to Top",
                    systemImage: item.isPinned ? "pin.slash" : "pin",
                    shortcut: .commandShift("p")
                ),
                ItemAction(kind: .saveAsSnippet, title: "Save as Snippet", systemImage: "text.badge.plus", shortcut: .commandShift("n")),
            ]
            if looksLikeURL(item.value) {
                actions.append(ItemAction(kind: .saveAsQuickLink, title: "Save as Quick Link", systemImage: "link.badge.plus", shortcut: .commandShift("l")))
            }
            actions.append(ItemAction(kind: .delete, title: "Delete Entry", systemImage: "trash", shortcut: .control("x"), isDestructive: true))
            return actions
        case .screenshot:
            return [
                ItemAction(kind: .primary, title: "Attach to Question", systemImage: "photo.badge.plus", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Copy Image", systemImage: "doc.on.doc", shortcut: .commandReturn),
                ItemAction(kind: .copyAndPaste, title: pasteTarget.map { "Paste Image to \($0)" } ?? "Paste Image", systemImage: "arrow.turn.down.right", shortcut: .commandShiftReturn),
                ItemAction(kind: .quickLook, title: "Quick Look", systemImage: "eye", shortcut: .command("y")),
                ItemAction(kind: .revealInFinder, title: "Reveal in Finder", systemImage: "folder", shortcut: .commandShift("r")),
                ItemAction(kind: .copyPath, title: "Copy File Path", systemImage: "doc.on.clipboard", shortcut: .commandShift("c")),
                ItemAction(kind: .delete, title: "Move to Trash", systemImage: "trash", shortcut: .control("x"), isDestructive: true),
            ]
        case .emoji:
            return [
                ItemAction(kind: .primary, title: pasteTitle, systemImage: "arrow.turn.down.right", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Copy to Clipboard", systemImage: "doc.on.doc", shortcut: .commandReturn),
            ]
        case .quickLink:
            return [
                ItemAction(
                    kind: .primary,
                    title: item.requiresInput ? "Enter Input" : "Open Link",
                    systemImage: "link",
                    shortcut: .returnKey
                ),
                ItemAction(kind: .secondary, title: "Copy Link", systemImage: "doc.on.doc", shortcut: .commandReturn),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
            ]
        case .command:
            return [
                ItemAction(kind: .primary, title: "Run", systemImage: "play", shortcut: .returnKey),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
            ]
        case .application:
            return []
        }
    }

    static func looksLikeURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else { return false }
        return true
    }
}

/// Which sub-form the ⌘K pane shows instead of the action list.
enum ItemActionForm: Equatable, Sendable {
    case edit
    case alias
    case hotkey
}

/// Actions on an AI answer. One table drives the footer, the ⌘K palette,
/// and the direct keys, like `ItemAction` does for rows.
enum ResultAction: String, CaseIterable, Identifiable, Sendable {
    case pasteBack
    case copy
    case saveSnippet
    case searchWeb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pasteBack: "Paste Answer Back"
        case .copy: "Copy Answer"
        case .saveSnippet: "Save Answer as Snippet"
        case .searchWeb: "Search the Web for Answer"
        }
    }

    var systemImage: String {
        switch self {
        case .pasteBack: "arrow.turn.down.right"
        case .copy: "doc.on.doc"
        case .saveSnippet: "text.badge.plus"
        case .searchWeb: "magnifyingglass"
        }
    }

    var shortcut: KeyShortcut {
        switch self {
        case .pasteBack: .commandReturn
        case .copy: .commandShift("c")
        case .saveSnippet: .commandShift("n")
        case .searchWeb: .commandShift("w")
        }
    }
}
