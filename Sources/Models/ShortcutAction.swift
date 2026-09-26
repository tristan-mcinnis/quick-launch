import AppKit
import Foundation

/// The in-app shortcuts a user may rebind.
///
/// One table, one value type (`ActionHotkey`: a key code and modifiers), four
/// surfaces: the key router, the footer hints, the key-cap badges and tooltips,
/// and the `⌘K` palette rows. A rebind writes an override into
/// `QuickSettings.shortcutOverrides`; every reader resolves through
/// `QuickSettings.shortcuts` (`ShortcutBindings`), so an old binding stops
/// matching the moment it is replaced, on every surface at once.
///
/// There is no process-wide table. Each view model owns its store's settings,
/// and the two AppKit surfaces that cannot reach a view model (the launcher
/// panel and the AI Chat menu) are handed bindings by the object that owns
/// them, so nothing couples one store to another and no test can leak a key
/// into its neighbours.
///
/// What this table does NOT own, and the Keyboard Shortcuts pane says so:
/// the global Carbon hotkeys (Quick Launch itself, Clipboard History, the
/// Translator, Type to Click, saved-action hotkeys, launcher-item hotkeys)
/// and the fixed keys.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable, Codable {
    // MARK: Attachments

    /// `⇧⌘A` on the Quick AI or AI Chat surface: the Add Context menu.
    /// Surface-gated: the same key on a launcher row opens "Set Alias…", which
    /// stays fixed in the launcher scope, so a rebind may not take it.
    case attachMenu
    /// `⇧⌘S`: the capture chooser (selected text, window, area, or screen).
    case attachWindow
    /// `⇧⌘D`: attach the display under the pointer.
    case attachDisplay

    // MARK: The command palette

    /// `⌘K`: the action list for the row, or the surface's own actions.
    case commandPalette

    // MARK: Chat

    case newChat
    case recentChats
    case previousChat
    case nextChat
    case renameChat
    case pinChat
    case deleteChat
    case continueInAIChat
    case changeModel
    case changeAssistant
    case tools
    case copyChat
    case continueInPi
    case captureToMemory
    case openSource
    case chatList
    case findInChat

    // MARK: The answer on screen

    case replaceSelection
    case pasteBack
    case copyAnswer
    case readAloud
    case saveSnippet
    case searchWeb
    case regenerate
    case regenerateWithModel
    case transformChooser
    case transcriptCollapse

    var id: String { rawValue }

    /// The surface the key acts on. Two actions may share a key when their
    /// scopes do not overlap; `.shared` overlaps both.
    var scope: ShortcutScope {
        switch self {
        case .commandPalette: .shared
        default: .chat
        }
    }

    /// The section the Keyboard Shortcuts pane lists it under.
    var group: ShortcutGroup {
        switch self {
        case .attachMenu, .attachWindow, .attachDisplay: .attachments
        case .commandPalette: .palette
        case .newChat, .recentChats, .previousChat, .nextChat, .renameChat, .pinChat,
             .deleteChat, .continueInAIChat, .changeModel, .changeAssistant, .tools,
             .copyChat, .continueInPi, .captureToMemory, .openSource, .chatList,
             .findInChat:
            .chat
        case .replaceSelection, .pasteBack, .copyAnswer, .readAloud, .saveSnippet,
             .searchWeb, .regenerate, .regenerateWithModel, .transformChooser,
             .transcriptCollapse:
            .answer
        }
    }

    /// What the row is called.
    var title: String {
        switch self {
        case .attachMenu: "Add Context"
        case .attachWindow: "Attach Capture"
        case .attachDisplay: "Attach Display"
        case .commandPalette: "Command Palette"
        case .newChat: "New Chat"
        case .recentChats: "Recent Chats"
        case .previousChat: "Previous Chat"
        case .nextChat: "Next Chat"
        case .renameChat: "Rename Chat"
        case .pinChat: "Pin Chat"
        case .deleteChat: "Delete Chat"
        case .continueInAIChat: "Open in AI Chat"
        case .changeModel: "Change Model"
        case .changeAssistant: "Change Assistant"
        case .tools: "Tools"
        case .copyChat: "Copy Chat"
        case .continueInPi: "Continue in pi"
        case .captureToMemory: "Capture to Memory"
        case .openSource: "Open Source"
        case .chatList: "Show or Hide Chat List"
        case .findInChat: "Find in Chat"
        case .replaceSelection: "Replace Selection"
        case .pasteBack: "Paste into Previous App"
        case .copyAnswer: "Copy Answer"
        case .readAloud: "Read Aloud"
        case .saveSnippet: "Save Answer as Snippet"
        case .searchWeb: "Search the Web for Answer"
        case .regenerate: "Regenerate Answer"
        case .regenerateWithModel: "Regenerate with Model"
        case .transformChooser: "Transform Selection"
        case .transcriptCollapse: "Fold or Unfold the Newest Question"
        }
    }

    /// One plain line under the title.
    var detail: String {
        switch self {
        case .attachMenu: "A window, a selection, an area, a screen, a file, or a link"
        case .attachWindow: "Pick what to attach: selected text, a window, an area, or a screen"
        case .attachDisplay: "The display under the pointer, in Quick Launch or AI Chat"
        case .commandPalette: "The action list for the highlighted row, or the surface"
        case .newChat: "Start an empty chat without leaving the surface"
        case .recentChats: "Past chats in place of the thread"
        case .previousChat: "The chat before this one"
        case .nextChat: "The chat after this one"
        case .renameChat: "Rename the open chat, or the highlighted chat row"
        case .pinChat: "Pin or unpin the open chat, or the highlighted chat row"
        case .deleteChat: "Delete the open chat, or the highlighted chat row"
        case .continueInAIChat: "Move this chat into the AI Chat window"
        case .changeModel: "Pick the model the next answer uses"
        case .changeAssistant: "Switch the chat to an assistant, or back to a plain chat"
        case .tools: "The chat's tools, toggled in the palette"
        case .copyChat: "The whole chat as a labelled transcript"
        case .continueInPi: "The thread to a new pi session in tmux, opened in Ghostty"
        case .captureToMemory: "Send the answer to recall capture"
        case .openSource: "The answer's source, or a picker when there are several"
        case .chatList: "The pinned and recent chats beside the thread, AI Chat only"
        case .findInChat: "Search the messages of this chat, AI Chat only"
        case .replaceSelection: "Swap the selected text for the answer"
        case .pasteBack: "Paste the answer into the app behind"
        case .copyAnswer: "Copy the answer to the clipboard"
        case .readAloud: "Speak the answer with the local voice"
        case .saveSnippet: "Keep the answer as a launcher snippet"
        case .searchWeb: "Search the web for the answer's question"
        case .regenerate: "Ask the last question again"
        case .regenerateWithModel: "Pick a model, then answer again on it"
        case .transformChooser: "The keyboard-first rewrite chooser for the selected chip"
        case .transcriptCollapse: "Expand or collapse the newest long question"
        }
    }

    /// The key this action ships with, expressed the same way as the rest of
    /// the app's key tables. This is the one source for the default; the
    /// recorded form is derived from it below.
    ///
    /// No default may collide with another default in an overlapping scope, a
    /// fixed key, or a default global hotkey; `ShortcutRegistryTests` asserts
    /// all three.
    var defaultShortcut: KeyShortcut {
        switch self {
        case .attachMenu: .commandShift("a")
        case .attachWindow: .commandShift("s")
        case .attachDisplay: .commandShift("d")
        case .commandPalette: .command("k")
        case .newChat: .command("n")
        case .recentChats: .command("p")
        case .previousChat: .command("[")
        case .nextChat: .command("]")
        case .renameChat: .command("e")
        case .pinChat: .commandShift("p")
        case .deleteChat: .control("x")
        case .continueInAIChat: .command("j")
        case .changeModel: .commandShift("o")
        case .changeAssistant: .commandOption("a")
        case .tools: .commandOption("k")
        case .copyChat: .commandOption("c")
        case .continueInPi: .commandOption("p")
        case .captureToMemory: .commandOption("m")
        case .openSource: .command("o")
        case .chatList: .controlCommand("s")
        case .findInChat: .command("f")
        // `⌥⌘V`. Replace Selection used to be `⇧⌘V`, which is the shipped
        // Clipboard History global hotkey; an in-app key that the global
        // layer swallows is not a shortcut. The global default is unchanged.
        case .replaceSelection: .commandOption("v")
        case .pasteBack: .commandReturn
        case .copyAnswer: .commandShift("c")
        case .readAloud: .command("l")
        case .saveSnippet: .commandShift("n")
        case .searchWeb: .commandShift("w")
        case .regenerate: .command("r")
        case .regenerateWithModel: .commandShift("r")
        case .transformChooser: .commandOption("t")
        case .transcriptCollapse: .commandShift("m")
        }
    }

    /// The default as a recorded hotkey: the value an override is compared
    /// against, and the one the recorder starts from.
    var defaultHotkey: ActionHotkey { ActionHotkey(defaulting: defaultShortcut) }

    /// The `ResultAction` this shortcut runs, when it is one of that table's.
    /// Every `ResultAction` has exactly one, and `forResultAction` is the
    /// inverse; the compiler enforces both directions.
    var resultAction: ResultAction? {
        switch self {
        case .newChat: .newChat
        case .recentChats: .recentChats
        case .previousChat: .previousChat
        case .nextChat: .nextChat
        case .renameChat: .renameChat
        case .pinChat: .pinChat
        case .deleteChat: .deleteChat
        case .continueInAIChat: .continueInAIChat
        case .changeModel: .changeModel
        case .changeAssistant: .changeAssistant
        case .tools: .tools
        case .copyChat: .copyChat
        case .continueInPi: .continueInPi
        case .captureToMemory: .captureToMemory
        case .openSource: .openSource
        case .replaceSelection: .replaceSelection
        case .pasteBack: .pasteBack
        case .copyAnswer: .copy
        case .readAloud: .readAloud
        case .saveSnippet: .saveSnippet
        case .searchWeb: .searchWeb
        case .regenerate: .regenerate
        case .regenerateWithModel: .regenerateWithModel
        case .attachMenu, .attachWindow, .attachDisplay, .commandPalette,
             .chatList, .findInChat, .transformChooser, .transcriptCollapse:
            nil
        }
    }

    static func forResultAction(_ action: ResultAction) -> ShortcutAction {
        switch action {
        case .replaceSelection: .replaceSelection
        case .pasteBack: .pasteBack
        case .copy: .copyAnswer
        case .copyChat: .copyChat
        case .continueInPi: .continueInPi
        case .continueInAIChat: .continueInAIChat
        case .readAloud: .readAloud
        case .saveSnippet: .saveSnippet
        case .searchWeb: .searchWeb
        case .regenerate: .regenerate
        case .regenerateWithModel: .regenerateWithModel
        case .changeModel: .changeModel
        case .changeAssistant: .changeAssistant
        case .newChat: .newChat
        case .recentChats: .recentChats
        case .previousChat: .previousChat
        case .nextChat: .nextChat
        case .renameChat: .renameChat
        case .pinChat: .pinChat
        case .deleteChat: .deleteChat
        case .openSource: .openSource
        case .captureToMemory: .captureToMemory
        case .tools: .tools
        }
    }
}

/// Which surface a shortcut acts on. Two actions may share a key when their
/// scopes do not overlap, which is how `⇧⌘A` is Add Context on a chat and
/// Set Alias… on a launcher row.
enum ShortcutScope: String, Sendable, CaseIterable {
    case launcher
    case chat
    case shared

    func overlaps(_ other: ShortcutScope) -> Bool {
        self == .shared || other == .shared || self == other
    }

    /// Where the key is used, for a refusal message.
    var label: String {
        switch self {
        case .launcher: "a launcher row action"
        case .chat: "a Quick AI or AI Chat action"
        case .shared: "a key used on both surfaces"
        }
    }
}

/// The sections of the Keyboard Shortcuts pane, in the order it lists them.
enum ShortcutGroup: String, Sendable, CaseIterable, Identifiable {
    case attachments
    case palette
    case chat
    case answer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attachments: "Attachments"
        case .palette: "Command palette"
        case .chat: "Quick AI and AI Chat"
        case .answer: "The answer on screen"
        }
    }

    var detail: String {
        switch self {
        case .attachments: "Capture or attach context while a chat is up"
        case .palette: "The action list over the launcher or the chat"
        case .chat: "The chat itself: opening, switching, renaming, sending on"
        case .answer: "What a key does to the answer on screen"
        }
    }

    var actions: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.group == self }
    }
}

/// The resolved in-app shortcut table for one set of settings.
///
/// Defaults come from `ShortcutAction.defaultShortcut`; an override replaces
/// one entry whole. Resolution never merges a modifier set, so a rebind fully
/// replaces the old key and the old key stops matching.
struct ShortcutBindings: Equatable, Sendable {
    static let defaults = ShortcutBindings()

    private let overrides: [ShortcutAction: ActionHotkey]

    init(overrides: [ShortcutAction: ActionHotkey] = [:]) {
        // A stored value may predate normalization. Normalize on the way in
        // and drop anything that is not a usable shortcut, so a corrupt entry
        // falls back to the default instead of shadowing it with nonsense.
        self.overrides = overrides.reduce(into: [:]) { result, entry in
            let hotkey = entry.value.normalized
            guard hotkey.isValidShortcut else { return }
            guard hotkey != entry.key.defaultHotkey else { return }
            result[entry.key] = hotkey
        }
    }

    init(settings: QuickSettings) {
        self.init(overrides: settings.shortcutOverrideTable)
    }

    /// True when nothing has been rebound.
    var isEmpty: Bool { overrides.isEmpty }

    /// The actions with a stored override, in table order.
    var customized: [ShortcutAction] {
        ShortcutAction.allCases.filter { overrides[$0] != nil }
    }

    func override(for action: ShortcutAction) -> ActionHotkey? { overrides[action] }

    func isCustomized(_ action: ShortcutAction) -> Bool { overrides[action] != nil }

    /// The key an action answers to now.
    func hotkey(for action: ShortcutAction) -> ActionHotkey {
        overrides[action] ?? action.defaultHotkey
    }

    /// The resolved key as the app's key tables express it. A rebound action
    /// answers by key code; a default keeps the character form the older
    /// tables use, so a default still matches the same event.
    func keyShortcut(for action: ShortcutAction) -> KeyShortcut {
        guard let override = overrides[action] else { return action.defaultShortcut }
        return KeyShortcut(key: .keyCode(override.keyCode), modifiers: override.modifiers)
    }

    func keyCaps(for action: ShortcutAction) -> [String] { hotkey(for: action).keyCaps }

    func displayName(for action: ShortcutAction) -> String { hotkey(for: action).displayName }

    /// Whether this key event is the action's current key.
    func matches(_ action: ShortcutAction, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        hotkey(for: action).matches(keyCode: keyCode, modifiers: modifiers)
    }

    /// The same test for the callers that still carry `characters`; a rebound
    /// key answers by key code, a default by its character.
    func matches(
        _ action: ShortcutAction,
        characters: String?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        keyShortcut(for: action).matches(
            characters: characters,
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    /// The first action this key event belongs to, in table order.
    func action(matchingKeyCode keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ShortcutAction? {
        ShortcutAction.allCases.first { matches($0, keyCode: keyCode, modifiers: modifiers) }
    }

    /// The first action this recorded hotkey belongs to, in table order.
    func action(matching hotkey: ActionHotkey) -> ShortcutAction? {
        let hotkey = hotkey.normalized
        return ShortcutAction.allCases.first { self.hotkey(for: $0) == hotkey }
    }

    /// Why `candidate` may not be bound to `action`, or nil when it may.
    ///
    /// Rejects the fixed keys, another remappable action in an overlapping
    /// scope, and every other setting that owns a key (the global hotkeys and
    /// the per-action and per-item ones). The user's own settings are the
    /// truth here; nothing in this function writes.
    func conflict(
        for candidate: ActionHotkey,
        action: ShortcutAction,
        settings: QuickSettings
    ) -> String? {
        let candidate = candidate.normalized
        guard candidate.isValidShortcut else { return "Must include Ctrl, Option, or Cmd" }
        if let fixed = ReservedShortcut.matching(candidate) {
            return fixed.refusal
        }
        if let other = ShortcutAction.allCases.first(where: {
            $0 != action
                && $0.scope.overlaps(action.scope)
                && hotkey(for: $0) == candidate
        }) {
            return "This conflicts with \(other.title)."
        }
        return settings.globalHotkeyConflictMessage(for: candidate)
    }
}

/// The keys a rebind may not take: the editor and navigation keys the app
/// keeps fixed, the launcher row's own keys, the window and app keys the macOS
/// menu bar owns, and the system combinations.
///
/// Recording an action's built-in key is a reset rather than a rebind, so a
/// key that a launcher row and a chat action share by default (⌘E, `⇧⌘P`,
/// `⌃X`, `⇧⌘A`, `⇧⌘N`, `⇧⌘C`, `⇧⌘R`) still ships and still works; a rebind of
/// a *different* action onto one of them is what this list refuses.
struct ReservedShortcut: Sendable, Equatable {
    /// What the key is called, e.g. "Edit or Rename".
    let label: String
    /// Where it is used, so the refusal can say which surface owns it.
    let scope: ShortcutScope
    let hotkey: ActionHotkey

    static func matching(_ hotkey: ActionHotkey) -> ReservedShortcut? {
        let hotkey = hotkey.normalized
        return all.first { $0.hotkey == hotkey }
    }

    private static func entry(
        _ label: String,
        _ scope: ShortcutScope,
        _ keyCode: UInt16,
        _ modifiers: NSEvent.ModifierFlags
    ) -> ReservedShortcut {
        ReservedShortcut(
            label: label,
            scope: scope,
            hotkey: ActionHotkey(keyCode: keyCode, modifiers: modifiers.rawValue)
        )
    }

    /// The message a refused rebind shows.
    var refusal: String {
        "That key is fixed: \(label) (\(hotkey.displayName)), \(scope.label)."
    }

    static let all: [ReservedShortcut] = [
        // Editing, in every text field. These are the platform's.
        entry("Undo", .shared, 6, [.command]),
        entry("Redo", .shared, 6, [.command, .shift]),
        entry("Cut", .shared, 7, [.command]),
        entry("Copy", .shared, 8, [.command]),
        entry("Paste", .shared, 9, [.command]),
        entry("Select All", .shared, 0, [.command]),
        // Navigation and submission inside the overlay.
        entry("Translate or submit", .shared, 36, [.shift]),
        entry("Find next", .chat, 5, [.command]),
        entry("Find previous", .chat, 5, [.command, .shift]),
        entry("Preview selected text", .shared, 34, [.command, .option]),
        // The launcher row's own keys. A chat action may ship on one of them
        // (⌘E, ⇧⌘P, ⌃X), which is why recording the built-in key is a reset.
        entry("Edit or Rename", .launcher, 14, [.command]),
        entry("Pin or Unpin", .launcher, 35, [.command, .shift]),
        entry("Delete", .launcher, 7, [.control]),
        entry("Set Alias…", .launcher, 0, [.command, .shift]),
        entry("Set Hotkey…", .launcher, 4, [.command, .shift]),
        entry("Save as Snippet", .launcher, 45, [.command, .shift]),
        entry("Create Quicklink", .launcher, 37, [.command, .shift]),
        entry("Copy Path or Copy Answer", .launcher, 8, [.command, .shift]),
        entry("Copy Clean Link", .launcher, 32, [.command, .shift]),
        entry("Quick Look or Show Timeline", .launcher, 16, [.command]),
        entry("Relaunch App", .launcher, 15, [.command, .shift]),
        entry("Quit App", .launcher, 12, [.command, .shift]),
        entry("Hide App", .launcher, 4, [.command, .option]),
        entry("Force Quit App, or Quit Quick Launch", .launcher, 12, [.command, .option]),
        // A number picks a chat, a colour notation, or a Settings tab.
        entry("Pick a numbered row", .launcher, 18, [.command]),
        entry("Pick a numbered row", .launcher, 19, [.command]),
        entry("Pick a numbered row", .launcher, 20, [.command]),
        entry("Pick a numbered row", .launcher, 21, [.command]),
        entry("Pick a numbered row", .launcher, 23, [.command]),
        entry("Pick a numbered row", .launcher, 22, [.command]),
        entry("Pick a numbered row", .launcher, 26, [.command]),
        entry("Pick a numbered row", .launcher, 28, [.command]),
        entry("Pick a numbered row", .launcher, 25, [.command]),
        // Window and app keys, from the AI Chat menu bar.
        entry("Close Window", .shared, 13, [.command]),
        entry("Quit Quick Launch", .shared, 12, [.command]),
        entry("Minimize", .shared, 46, [.command]),
        entry("Settings", .shared, 43, [.command]),
        entry("Hide Quick Launch", .shared, 4, [.command]),
        // The system's.
        entry("Switch apps", .shared, 48, [.command]),
        entry("Switch apps backwards", .shared, 48, [.command, .shift]),
        entry("Spotlight", .shared, 49, [.command]),
        entry("Cycle windows", .shared, 50, [.command]),
        entry("Mission Control", .shared, 126, [.control]),
        entry("Application windows", .shared, 125, [.control]),
        entry("Move left a space", .shared, 123, [.control]),
        entry("Move right a space", .shared, 124, [.control]),
    ]
}
