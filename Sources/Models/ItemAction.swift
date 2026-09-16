import AppKit
import Foundation

/// A keyboard shortcut shown as key caps and matched against key events.
struct KeyShortcut: Equatable, Sendable {
    enum Key: Equatable, Sendable {
        case character(Character)
        case `return`
        /// A recorded key. The Keyboard Shortcuts pane stores key codes, not
        /// characters, because a rebind must not depend on the keyboard
        /// layout; the built-in defaults keep their character form so their
        /// display and their existing tests are unchanged.
        case keyCode(UInt16)
    }

    let key: Key
    /// `NSEvent.ModifierFlags` raw value, device-independent bits only.
    let modifiers: UInt

    init(key: Key, modifiers: UInt) {
        self.key = key
        self.modifiers = modifiers
    }

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

    static func controlCommand(_ character: Character) -> KeyShortcut {
        KeyShortcut(
            key: .character(character),
            modifiers: NSEvent.ModifierFlags([.control, .command]).rawValue
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
        case .keyCode(let keyCode): caps.append(QuickSettings.keyName(for: keyCode))
        }
        return caps
    }

    /// The key as a recorded `ActionHotkey` code, for the tables that answer
    /// by key code. Nil only for a character with no ANSI code.
    var virtualKeyCode: UInt16? {
        switch key {
        case .return: VirtualKey.`return`.rawValue
        case .keyCode(let keyCode): keyCode
        case .character(let character): KeyCodes.code(for: character)
        }
    }

    /// Compact form for labels and accessibility: `⌥⌘←`.
    var displayName: String { keyCaps.joined() }

    /// `characters` is `NSEvent.charactersIgnoringModifiers`; `keyCode` 36 is Return.
    func matches(characters: String?, keyCode: UInt16, modifiers flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.overlayRelevant.rawValue == modifiers else { return false }
        switch key {
        case .return:
            return VirtualKey.isReturn(keyCode: keyCode)
        case .character(let character):
            return characters?.lowercased() == String(character).lowercased()
        case .keyCode(let recorded):
            return keyCode == recorded
        }
    }
}

/// ANSI virtual key codes by character, the inverse of
/// `QuickSettings.keyName(for:)`. One table, so a built-in shortcut that is
/// written as a character and the recorder's key code agree.
enum KeyCodes {
    static let byName: [String: UInt16] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
        "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
        "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "L": 37,
        "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "N": 45, "M": 46, ".": 47, "`": 50, "↩": 36, "⇥": 48, "Space": 49,
        "⌫": 51, "⎋": 53, "←": 123, "→": 124, "↓": 125, "↑": 126,
    ]

    static func code(for character: Character) -> UInt16? {
        byName[String(character).uppercased()]
    }

    /// The character AppKit spells a key code with for a menu item's key
    /// equivalent. Letters, digits, and punctuation use their own character
    /// in lower case, since the modifier mask carries Shift; the named keys
    /// use the private-use range AppKit expects. Nil for a key with no
    /// equivalent, and the menu then shows its item without one.
    static func menuEquivalent(for keyCode: UInt16) -> String? {
        menuCharacters[keyCode]
    }

    private static let menuCharacters: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 36: "\r",
        37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "n", 46: "m", 47: ".", 48: "\t", 49: " ", 50: "`",
        51: "\u{8}", 53: "\u{1B}",
        116: "\u{F72C}", 121: "\u{F72D}",
        123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}",
    ]
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
    /// Copy a picked color in one specific notation; `commandValue` holds the
    /// `ColorFormat` raw value.
    case copyAs
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
    /// `⌘J` on a chat row: that chat moves to the AI Chat window.
    case openInAIChat
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
    /// `bindings` is the owner's resolved in-app table. The launcher's rows
    /// that name a chat key (Rename, Pin, Delete, Open in AI Chat) take their
    /// caps from it, so a rebind moves the row and the key together; the
    /// launcher's own row keys are fixed and do not.
    static func actions(
        for result: LauncherSearchResult,
        pasteTarget: String?,
        isRunning: Bool = false,
        bindings: ShortcutBindings = .defaults
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
            return actions(for: item, pasteTarget: pasteTarget, bindings: bindings)
        }
    }

    private static func actions(
        for item: LauncherCatalogItem,
        pasteTarget: String?,
        bindings: ShortcutBindings
    ) -> [ItemAction] {
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
            let isText = (item.clipboardPayload?.kind ?? .text) == .text
            let isImage = item.clipboardPayload?.kind == .image
            var actions = [
                ItemAction(
                    kind: .primary,
                    title: isImage
                        ? (pasteTarget.map { "Paste Image to \($0)" } ?? "Paste Image")
                        : pasteTitle,
                    systemImage: "arrow.turn.down.right",
                    shortcut: .returnKey
                ),
                ItemAction(kind: .secondary, title: isImage ? "Copy Image" : "Copy to Clipboard", systemImage: "doc.on.doc", shortcut: .commandReturn),
                ItemAction(kind: .copyAndPaste, title: "Copy & Paste", systemImage: "doc.on.clipboard", shortcut: .commandShiftReturn),
                pinAction(for: item),
            ]
            if isText {
                actions.append(ItemAction(kind: .saveAsSnippet, title: "Save as Snippet", systemImage: "text.badge.plus", shortcut: .commandShift("n")))
                if looksLikeURL(item.value) {
                    actions.append(ItemAction(kind: .saveAsQuickLink, title: "Create Quicklink", systemImage: "link.badge.plus", shortcut: .commandShift("l")))
                    if URLCleaner.hasTrackingParameters(item.value) {
                        actions.append(cleanLinkAction)
                    }
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
        case .color:
            var actions = [
                ItemAction(kind: .primary, title: pasteTitle, systemImage: "arrow.turn.down.right", shortcut: .returnKey),
                ItemAction(kind: .secondary, title: "Copy to Clipboard", systemImage: "doc.on.doc", shortcut: .commandReturn),
                ItemAction(kind: .copyAndPaste, title: "Copy & Paste", systemImage: "doc.on.clipboard", shortcut: .commandShiftReturn),
            ]
            // One row per notation, so a color picked as hex is still one
            // keystroke away from `rgb(...)`. ⌘1…⌘4 follow the menu order.
            if let color = PickedColor(hexString: item.itemID) {
                for (index, entry) in color.allStrings.enumerated() {
                    actions.append(ItemAction(
                        kind: .copyAs,
                        title: "Copy \(entry.0.title) · \(entry.1)",
                        systemImage: "number",
                        shortcut: .command(Character("\(index + 1)")),
                        commandValue: entry.0.rawValue
                    ))
                }
            }
            actions += [
                pinAction(for: item),
                ItemAction(kind: .saveAsSnippet, title: "Save as Snippet", systemImage: "text.badge.plus", shortcut: .commandShift("n")),
                ItemAction(kind: .delete, title: "Delete Color", systemImage: "trash", shortcut: .control("x"), isDestructive: true),
            ]
            return actions
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
            // A stored Quicklink gets the same edit and delete a snippet has,
            // on the same keys. A Smart Link keeps the read-only list.
            if item.isEditableQuickLink {
                actions.append(ItemAction(kind: .edit, title: "Edit Quicklink", systemImage: "pencil", shortcut: .command("e")))
            }
            actions += [
                pinAction(for: item),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
            ]
            if item.isEditableQuickLink {
                actions.append(ItemAction(kind: .delete, title: "Delete Quicklink", systemImage: "trash", shortcut: .control("x"), isDestructive: true))
            }
            return actions
        case .command:
            // Caffeinate is one action whose word flips with the effective
            // state, exactly like Pin/Unpin: only Decaffeinate is offered while
            // a sleep assertion is held, only Caffeinate when it is not.
            let caffeinateActive = item.caffeinateIsActive
            return [
                ItemAction(
                    kind: .primary,
                    title: item.caffeinateActionTitle
                        ?? (item.value.hasPrefix("vault.") ? "Search" : "Run"),
                    systemImage: caffeinateActive != nil
                        ? (caffeinateActive == true ? "moon.zzz" : "cup.and.saucer.fill")
                        : (item.value.hasPrefix("vault.") ? "magnifyingglass" : "play"),
                    shortcut: .returnKey
                ),
                ItemAction(kind: .setAlias, title: "Set Alias…", systemImage: "textformat.abc", shortcut: .commandShift("a")),
                ItemAction(kind: .setHotkey, title: "Set Hotkey…", systemImage: "keyboard", shortcut: .commandShift("h")),
            ]
        case .conversation:
            // A chat row's Rename, Pin, Delete, and Open in AI Chat are the
            // chat actions, so they follow a rebind. The key that reaches this
            // row from the list is the same one `performShortcut` matches.
            return [
                ItemAction(kind: .primary, title: "Continue Chat", systemImage: "bubble.left.and.text.bubble.right", shortcut: .returnKey),
                // The same move, title, and key as `⌘J` on the open chat.
                ItemAction(
                    kind: .openInAIChat,
                    title: ResultAction.continueInAIChat.title,
                    systemImage: ResultAction.continueInAIChat.systemImage,
                    shortcut: bindings.keyShortcut(for: .continueInAIChat)
                ),
                ItemAction(kind: .secondary, title: "Copy Last Answer", systemImage: "doc.on.doc", shortcut: .commandReturn),
                ItemAction(kind: .edit, title: "Rename Chat", systemImage: "pencil", shortcut: bindings.keyShortcut(for: .renameChat)),
                pinAction(for: item, shortcut: bindings.keyShortcut(for: .pinChat)),
                ItemAction(kind: .delete, title: "Delete Chat", systemImage: "trash", shortcut: bindings.keyShortcut(for: .deleteChat), isDestructive: true),
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

    /// The same pin on every pinnable kind: `⇧⌘P` toggles it. A chat row
    /// passes its own resolved key; every other kind passes the fixed one.
    private static func pinAction(
        for item: LauncherCatalogItem,
        shortcut: KeyShortcut = .commandShift("p")
    ) -> ItemAction {
        ItemAction(
            kind: .pin,
            title: item.isPinned ? "Unpin" : "Pin to Top",
            systemImage: item.isPinned ? "pin.slash" : "pin",
            shortcut: shortcut
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

    /// Window height the whole overlay must reach while this form is open,
    /// or nil when the form fits inside the default pane budget.
    var minimumWindowHeight: CGFloat? {
        switch self {
        case .edit, .alias, .hotkey: nil
        case .screenHistorySave: ScreenHistorySaveLayout.minimumWindowHeight
        }
    }

    /// ⌘K pane showing this form instead of the list: header 44 + divider + body.
    var minimumPaneHeight: CGFloat {
        switch self {
        case .edit: 44 + 1 + 240
        case .alias, .hotkey: 44 + 1 + 130
        case .screenHistorySave:
            ScreenHistorySaveLayout.minimumWindowHeight
                - PanelSizing.inputHeight - PanelSizing.paneBottomMargin
        }
    }
}

/// Actions on an AI answer. One table drives the footer, the ⌘K palette,
/// and the direct keys, like `ItemAction` does for rows. Keys follow
/// Raycast's Quick AI: Return pastes, ⌘N new chat, ⌘R regenerate,
/// ⌘[ and ⌘] browse recent chats.
enum ResultAction: String, CaseIterable, Identifiable, Sendable {
    case replaceSelection
    case pasteBack
    case copy
    /// `⌥⌘C`: the whole chat as a labelled transcript ("You:" and the model).
    case copyChat
    /// `⌥⌘P`: the thread to a new pi session in tmux, opened in Ghostty.
    case continueInPi
    /// `⌘J`, Open in AI Chat: the chat, its model, tools, and attachments
    /// to the AI Chat window; the launcher closes. Raycast's key for the
    /// same move.
    case continueInAIChat
    case readAloud
    case saveSnippet
    case searchWeb
    case regenerate
    /// `⇧⌘R`: pick a model, then answer the last question again on it.
    case regenerateWithModel
    /// `⌘⇧O`: make the picked model the active one, without answering again.
    case changeModel
    /// `⌥⌘A`: start or switch the chat to an assistant, or back to a plain chat.
    case changeAssistant
    case newChat
    /// `⌘P`: Recent Chats inside Quick AI (`⌘H` too, the v1.4 key).
    case recentChats
    case previousChat
    case nextChat
    case renameChat
    case pinChat
    case deleteChat
    /// `⌘O`: open the answer's source, or pick one when there are several.
    case openSource
    /// `⌥⌘M`: send the answer to `recall remember`. User-triggered only.
    case captureToMemory
    /// `⌥⌘K`: the chat's tools, toggled in the palette.
    case tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replaceSelection: "Replace Selection"
        case .pasteBack: "Paste into Previous App"
        case .copy: "Copy Answer"
        case .copyChat: "Copy Chat"
        case .continueInPi: "Continue in pi"
        case .continueInAIChat: "Open in AI Chat"
        case .readAloud: "Read aloud"
        case .saveSnippet: "Save Answer as Snippet"
        case .searchWeb: "Search the Web for Answer"
        case .regenerate: "Regenerate Answer"
        case .regenerateWithModel: "Regenerate with Model…"
        case .changeModel: "Change Model"
        case .changeAssistant: "Change Assistant"
        case .newChat: "New Chat"
        case .recentChats: "Recent Chats"
        case .previousChat: "Previous Chat"
        case .nextChat: "Next Chat"
        case .renameChat: "Rename Chat"
        case .pinChat: "Pin Chat"
        case .deleteChat: "Delete Chat"
        case .openSource: "Open Source"
        case .captureToMemory: "Capture to Memory"
        case .tools: "Tools"
        }
    }

    var systemImage: String {
        switch self {
        case .replaceSelection: "text.cursor"
        case .pasteBack: "arrow.turn.down.right"
        case .copy: "doc.on.doc"
        case .copyChat: "text.bubble"
        case .continueInPi: "terminal"
        case .continueInAIChat: "macwindow"
        case .readAloud: "speaker.wave.2"
        case .saveSnippet: "text.badge.plus"
        case .searchWeb: "magnifyingglass"
        case .regenerate: "arrow.clockwise"
        case .regenerateWithModel: "arrow.clockwise.circle"
        case .changeModel: "cpu"
        case .changeAssistant: "person.crop.circle"
        case .newChat: "plus.bubble"
        case .recentChats: "clock.arrow.circlepath"
        case .previousChat: "chevron.left"
        case .nextChat: "chevron.right"
        case .renameChat: "pencil"
        case .pinChat: "pin"
        case .deleteChat: "trash"
        case .openSource: "doc.text"
        case .captureToMemory: "brain.head.profile"
        case .tools: "wrench.and.screwdriver"
        }
    }

    /// The key this action runs, resolved through the bindings its owner
    /// holds, so a rebind in Settings reaches the router, the footer hint, the
    /// key-cap badge, the palette row, and the AI Chat menu together.
    func shortcut(_ bindings: ShortcutBindings) -> KeyShortcut {
        bindings.keyShortcut(for: ShortcutAction.forResultAction(self))
    }

    /// The built-in key, unaffected by any override. The registry's defaults,
    /// the Settings pane, and the free-key checks read it; routing reads
    /// `shortcut(_:)` above.
    var defaultShortcut: KeyShortcut {
        switch self {
        // `⌥⌘V`. Replace Selection was `⇧⌘V` until that turned out to be the
        // shipped Clipboard History global hotkey, which swallows the key
        // whenever the launcher is open; the global default is unchanged.
        case .replaceSelection: .commandOption("v")
        case .pasteBack: .commandReturn
        case .copy: .commandShift("c")
        case .copyChat: .commandOption("c")
        // P for pi. Checked free against every key table (see
        // PiHandoffTests); `⇧⌘P` is Pin.
        case .continueInPi: .commandOption("p")
        // Raycast's key for the same move. Recent Chats moved to `⌘P`.
        case .continueInAIChat: .command("j")
        case .readAloud: .command("l")
        case .saveSnippet: .commandShift("n")
        case .searchWeb: .commandShift("w")
        case .regenerate: .command("r")
        case .regenerateWithModel: .commandShift("r")
        case .changeModel: .commandShift("o")
        case .changeAssistant: .commandOption("a")
        case .newChat: .command("n")
        // P for past chats; `QuickViewModel.recentChatsShortcut` is this key.
        case .recentChats: .command("p")
        case .previousChat: .command("[")
        case .nextChat: .command("]")
        case .renameChat: .command("e")
        case .pinChat: .commandShift("p")
        case .deleteChat: .control("x")
        case .openSource: .command("o")
        // `⇧⌘M` folds a long question, so memory takes the Option layer.
        case .captureToMemory: .commandOption("m")
        // `⌘K` opens the palette; `⌥⌘K` opens it on Tools.
        case .tools: .commandOption("k")
        }
    }

    var isDestructive: Bool { self == .deleteChat }

    /// The `⌘K` palette's second line when an action has no detail of its
    /// own: what the action works on. The answer on screen, or the chat.
    var paletteGroup: String {
        switch self {
        case .replaceSelection, .pasteBack, .copy, .readAloud, .saveSnippet, .searchWeb,
             .regenerate, .regenerateWithModel, .openSource, .captureToMemory:
            "Answer"
        case .copyChat, .continueInPi, .continueInAIChat, .changeModel, .changeAssistant,
             .newChat, .recentChats, .previousChat, .nextChat, .renameChat, .pinChat,
             .deleteChat, .tools:
            "Chat"
        }
    }
}
