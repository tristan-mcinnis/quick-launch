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

    static func commandOption(_ character: Character) -> KeyShortcut {
        KeyShortcut(
            key: .character(character),
            modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue
        )
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
    /// Runs a launcher command (Screen Awareness captures and the like) from
    /// a catalog's ⌘K list; `commandValue` holds the command item's value.
    case runCommand
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
    case quit
    case forceQuit
    case hide
    case relaunch
    case copyCleanLink
    case showTimeline
    case openMoment
    case saveToVault
    case acceptScreenHistoryReview
    case flagScreenHistoryReview
}

/// One row in the ⌘K pane. The same table drives direct shortcuts from the
/// list, so a key does the same thing whether or not the pane is open.
struct ItemAction: Identifiable, Equatable, Sendable {
    let kind: ItemActionKind
    let title: String
    let systemImage: String
    let shortcut: KeyShortcut?
    var isDestructive: Bool = false
    /// For `.runCommand`: the launcher command's value ("screenshot.window", …).
    var commandValue: String? = nil

    var id: String { kind.rawValue + ":" + (commandValue ?? "") }
}

/// Raycast conventions: Return is the primary action, ⌘↩ the secondary,
/// ⌘E edits, ⌃X deletes, ⌘⇧A and ⌘⇧H configure alias and hotkey.
enum ItemActionCatalog {
    static func actions(
        for result: LauncherSearchResult,
        pasteTarget: String?,
        isRunning: Bool = false
    ) -> [ItemAction] {
        switch result {
        case .catalog:
            return [ItemAction(kind: .primary, title: "Browse", systemImage: "folder", shortcut: .returnKey)]
        case .application:
            var actions = [
                ItemAction(kind: .primary, title: isRunning ? "Switch To" : "Open", systemImage: "arrow.up.forward.app", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Show in Finder", systemImage: "folder", shortcut: .commandReturn),
            ]
            if isRunning {
                actions += [
                    ItemAction(kind: .hide, title: "Hide", systemImage: "eye.slash", shortcut: .commandOption("h")),
                    ItemAction(kind: .quit, title: "Quit", systemImage: "xmark.circle", shortcut: .commandShift("q")),
                    ItemAction(kind: .relaunch, title: "Relaunch", systemImage: "arrow.clockwise.circle", shortcut: .commandShift("r")),
                    ItemAction(kind: .forceQuit, title: "Force Quit", systemImage: "exclamationmark.octagon", shortcut: .commandOption("q"), isDestructive: true),
                ]
            }
            actions += [
                ItemAction(kind: .copyPath, title: "Copy Path", systemImage: "doc.on.doc", shortcut: .commandShift("c")),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
            ]
            return actions
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
                pinAction(for: item),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
                ItemAction(kind: .delete, title: "Delete Snippet", systemImage: "trash", shortcut: .control("x"), isDestructive: true),
            ]
        case .clipboard:
            var actions = [
                ItemAction(kind: .primary, title: pasteTitle, systemImage: "arrow.turn.down.right", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Copy to Clipboard", systemImage: "doc.on.doc", shortcut: .commandReturn),
                ItemAction(kind: .copyAndPaste, title: "Copy & Paste", systemImage: "doc.on.clipboard", shortcut: .commandShiftReturn),
                pinAction(for: item),
                ItemAction(kind: .saveAsSnippet, title: "Save as Snippet", systemImage: "text.badge.plus", shortcut: .commandShift("n")),
            ]
            if looksLikeURL(item.value) {
                actions.append(ItemAction(kind: .saveAsQuickLink, title: "Create Quicklink", systemImage: "link.badge.plus", shortcut: .commandShift("l")))
                if URLCleaner.hasTrackingParameters(item.value) {
                    actions.append(cleanLinkAction)
                }
            }
            actions.append(ItemAction(kind: .delete, title: "Delete Entry", systemImage: "trash", shortcut: .control("x"), isDestructive: true))
            return actions
        case .screenshot:
            return [
                ItemAction(kind: .primary, title: pasteTarget.map { "Paste Image to \($0)" } ?? "Paste Image", systemImage: "arrow.turn.down.right", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Copy Image", systemImage: "doc.on.doc", shortcut: .commandReturn),
                ItemAction(kind: .copyAndPaste, title: "Attach to Question", systemImage: "photo.badge.plus", shortcut: .commandShiftReturn),
                ItemAction(kind: .quickLook, title: "Quick Look", systemImage: "eye", shortcut: .command("y")),
                pinAction(for: item),
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
            var actions = [
                ItemAction(
                    kind: .primary,
                    title: item.requiresInput ? "Enter Input" : "Open Link",
                    systemImage: "link",
                    shortcut: .returnKey
                ),
                ItemAction(kind: .secondary, title: "Copy Link", systemImage: "doc.on.doc", shortcut: .commandReturn),
            ]
            if !item.requiresInput, URLCleaner.hasTrackingParameters(item.value) {
                actions.append(cleanLinkAction)
            }
            if item.itemID.hasPrefix("typed:") { return actions }
            actions += [
                pinAction(for: item),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
            ]
            return actions
        case .command:
            return [
                ItemAction(
                    kind: .primary,
                    title: item.value.hasPrefix("vault.") ? "Search" : "Run",
                    systemImage: item.value.hasPrefix("vault.") ? "magnifyingglass" : "play",
                    shortcut: .returnKey
                ),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
            ]
        case .conversation:
            return [
                ItemAction(kind: .primary, title: "Continue Chat", systemImage: "bubble.left.and.text.bubble.right", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Copy Last Answer", systemImage: "doc.on.doc", shortcut: .commandReturn),
                ItemAction(kind: .edit, title: "Rename Chat", systemImage: "pencil", shortcut: .command("e")),
                pinAction(for: item),
                ItemAction(kind: .delete, title: "Delete Chat", systemImage: "trash", shortcut: .control("x"), isDestructive: true),
            ]
        case .folder:
            var actions = [
                ItemAction(kind: .primary, title: "Open in Finder", systemImage: "folder", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Reveal in Finder", systemImage: "folder.badge.gearshape", shortcut: .commandReturn),
                ItemAction(kind: .copyPath, title: "Copy Path", systemImage: "doc.on.doc", shortcut: .commandShift("c")),
                pinAction(for: item),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
            ]
            if !FolderLocationService.builtIn.contains(where: { $0.id == item.itemID }) {
                actions.append(ItemAction(kind: .delete, title: "Remove Folder", systemImage: "trash", shortcut: .control("x"), isDestructive: true))
            }
            return actions
        case .answer:
            return [
                ItemAction(kind: .primary, title: "Copy Answer", systemImage: "doc.on.doc", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: pasteTitle, systemImage: "arrow.turn.down.right", shortcut: .commandReturn),
                ItemAction(kind: .copyAndPaste, title: "Copy & Paste", systemImage: "doc.on.clipboard", shortcut: .commandShiftReturn),
            ]
        case .screenHistory:
            var actions = [
                ItemAction(kind: .openMoment, title: "Open moment", systemImage: "clock", shortcut: .returnKey),
                ItemAction(kind: .showTimeline, title: "Show timeline", systemImage: "clock.arrow.circlepath", shortcut: .command("y")),
                ItemAction(kind: .secondary, title: "Copy text", systemImage: "doc.on.doc", shortcut: .commandReturn),
            ]
            if item.keywords.contains("has-local-file") {
                actions.append(ItemAction(kind: .revealInFinder, title: "Show in Finder", systemImage: "folder", shortcut: .commandShift("r")))
            }
            actions.append(ItemAction(kind: .saveToVault, title: "Save to Vault", systemImage: "tray.and.arrow.down", shortcut: nil))
            return actions
        case .askAI:
            return [
                ItemAction(kind: .primary, title: "Ask AI", systemImage: "sparkles", shortcut: .returnKey),
                pinAction(for: item),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
            ]
        case .application:
            return []
        }
    }

    static let cleanLinkAction = ItemAction(
        kind: .copyCleanLink,
        title: "Copy Clean Link",
        systemImage: "link.badge.plus",
        shortcut: .commandShift("u")
    )

    /// The same pin on every pinnable kind: `⌘⇧P` toggles it.
    private static func pinAction(for item: LauncherCatalogItem) -> ItemAction {
        ItemAction(
            kind: .pin,
            title: item.isPinned ? "Unpin" : "Pin to Top",
            systemImage: item.isPinned ? "pin.slash" : "pin",
            shortcut: .commandShift("p")
        )
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
    case screenHistorySave
}

/// Actions on an AI answer. One table drives the footer, the ⌘K palette,
/// and the direct keys, like `ItemAction` does for rows. Keys follow
/// Raycast's Quick AI: Return pastes, ⌘N new chat, ⌘R regenerate,
/// ⌘[ and ⌘] browse recent chats.
enum ResultAction: String, CaseIterable, Identifiable, Sendable {
    case pasteBack
    case copy
    case saveSnippet
    case searchWeb
    case regenerate
    case newChat
    case previousChat
    case nextChat
    case renameChat
    case pinChat
    case deleteChat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pasteBack: "Paste Answer Back"
        case .copy: "Copy Answer"
        case .saveSnippet: "Save Answer as Snippet"
        case .searchWeb: "Search the Web for Answer"
        case .regenerate: "Regenerate Answer"
        case .newChat: "New Chat"
        case .previousChat: "Previous Chat"
        case .nextChat: "Next Chat"
        case .renameChat: "Rename Chat"
        case .pinChat: "Pin Chat"
        case .deleteChat: "Delete Chat"
        }
    }

    var systemImage: String {
        switch self {
        case .pasteBack: "arrow.turn.down.right"
        case .copy: "doc.on.doc"
        case .saveSnippet: "text.badge.plus"
        case .searchWeb: "magnifyingglass"
        case .regenerate: "arrow.clockwise"
        case .newChat: "plus.bubble"
        case .previousChat: "chevron.left"
        case .nextChat: "chevron.right"
        case .renameChat: "pencil"
        case .pinChat: "pin"
        case .deleteChat: "trash"
        }
    }

    var shortcut: KeyShortcut {
        switch self {
        case .pasteBack: .commandReturn
        case .copy: .commandShift("c")
        case .saveSnippet: .commandShift("n")
        case .searchWeb: .commandShift("w")
        case .regenerate: .command("r")
        case .newChat: .command("n")
        case .previousChat: .command("[")
        case .nextChat: .command("]")
        case .renameChat: .command("e")
        case .pinChat: .commandShift("p")
        case .deleteChat: .control("x")
        }
    }

    var isDestructive: Bool { self == .deleteChat }
}
