import Foundation

/// One tab of the Settings window.
///
/// This lived inside `SettingsView.SettingsTab`. It moved here so the
/// launcher's search index can address a pane without importing the view.
/// `SettingsView` keeps the old name as a type alias, so every existing
/// reference (`SettingsView.SettingsTab`) still compiles.
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    // Appended, never inserted: the ⌘-number of a tab is its position, so
    // adding a pane at the end keeps ⌘1…⌘6 on the tabs they always opened.
    // (Screen History, once ⌘5, was retired on 2026-09-26.)
    case general, items, models, clipboard, prompts, about, keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .keyboard: "Keyboard Shortcuts"
        case .items: "Items"
        case .models: "Models"
        case .clipboard: "Clipboard & Capture"
        case .prompts: "AI Commands"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .keyboard: "keyboard"
        case .items: "square.grid.2x2"
        case .models: "cpu"
        case .clipboard: "clipboard"
        case .prompts: "text.quote"
        case .about: "info.circle"
        }
    }

    /// One plain line under the pane title.
    var subtitle: String {
        switch self {
        case .general: "Hotkeys, launcher behaviour, chats, and learning."
        case .keyboard: "Rebind the in-app keys; see what stays fixed."
        case .items: "Aliases and hotkeys for apps, folders, and commands."
        case .models: "Providers, models, and the quick-action instruction."
        case .clipboard: "Clipboard history, colors, emoji, and Quicklinks."
        case .prompts: "Saved AI commands, their aliases, and hotkeys."
        case .about: "Version, updates, and source."
        }
    }

    /// The quiet hint on the left of the footer well. Keep it true.
    var footerHint: String {
        switch self {
        case .general, .items, .clipboard, .prompts: "Applies immediately"
        case .keyboard: "Rebinds apply immediately"
        case .models: "Model changes apply immediately"
        case .about: "Version and updates"
        }
    }
}

/// One addressable place inside Settings: a pane plus the group (or single
/// control) the pane should scroll to and highlight.
///
/// The index below is the one source of truth for Settings search. The
/// sidebar search and the launcher's root search both read it, so a word that
/// finds a setting in one finds it in the other, and both land on the same
/// place.
struct SettingsDestination: Identifiable, Equatable, Hashable, Sendable {
    /// Stable identifier, e.g. `general.caffeinate.battery`.
    let id: String
    /// Which pane row reveals it.
    let pane: SettingsPane
    /// The `.settingsAnchor(...)` id inside that pane. Empty means the pane
    /// itself, with no particular group to highlight.
    let anchor: String
    /// What the search row says.
    let title: String
    /// The quiet second line, here the pane name.
    let detail: String
    /// Extra words that should find this destination: the words a user is
    /// likely to type instead of the title.
    let synonyms: [String]

    /// Every word a search may match, folded into one candidate string.
    var searchText: String {
        ([title, detail, pane.title, pane.subtitle] + synonyms).joined(separator: " ")
    }

    /// A launcher/catalog row for this destination. `value` routes through
    /// `performSystemCommand`, the same value router every other command uses.
    static let valuePrefix = "settings.destination."

    var launcherValue: String { Self.valuePrefix + id }

    var launcherItem: LauncherCatalogItem {
        LauncherCatalogItem(
            kind: .command,
            itemID: "settings.\(id)",
            title: title,
            detail: "Settings · \(pane.title)",
            value: launcherValue,
            keywords: (synonyms + [pane.title, pane.subtitle, "settings preference option"]).joined(separator: " ")
        )
    }
}

/// The single index of every searchable setting.
///
/// A future Keyboard Shortcuts pane or destination is added here once, and
/// both the sidebar and the launcher pick it up: append a `SettingsPane` case,
/// a pane destination, and its group destinations. Nothing else changes.
enum SettingsDestinationIndex {
    /// The whole list, pane rows first so an exact pane-word search wins.
    static let all: [SettingsDestination] = paneDestinations + groupDestinations

    static func destination(id: String) -> SettingsDestination? {
        all.first { $0.id == id }
    }

    /// Every destination whose title or search words match `query`, best first.
    /// An empty query matches nothing: the sidebar only searches when the
    /// user typed something.
    static func matching(_ query: String) -> [SettingsDestination] {
        let needle = FuzzyMatcher.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        return all
            .compactMap { destination -> (SettingsDestination, Int)? in
                if let title = FuzzyMatcher.score(
                    foldedQuery: needle,
                    foldedCandidate: FuzzyMatcher.fold(destination.title)
                ) {
                    return (destination, title + 10_000)
                }
                guard let hit = FuzzyMatcher.score(
                    foldedQuery: needle,
                    foldedCandidate: FuzzyMatcher.fold(destination.searchText)
                ) else { return nil }
                return (destination, hit)
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1
                    ? lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
                    : lhs.1 > rhs.1
            }
            .map(\.0)
    }

    /// One launcher row per addressed group, in index order. Pane-level rows
    /// are sidebar-only: the launcher should land on a named group, never on
    /// a bare pane ("merely generic settings").
    static var launcherItems: [LauncherCatalogItem] {
        all.filter { !$0.id.hasPrefix("pane.") }.map(\.launcherItem)
    }

    // MARK: - The index

    private static let paneDestinations: [SettingsDestination] = SettingsPane.allCases.map { pane in
        SettingsDestination(
            id: "pane.\(pane.rawValue)",
            pane: pane,
            anchor: "",
            title: pane.title,
            detail: "Settings",
            synonyms: pane.subtitle.split(separator: " ").map(String.init)
        )
    }

    private static let groupDestinations: [SettingsDestination] = [
        // General
        group("general.hotkeys", .general, "general.hotkeys", "Hotkeys & Shortcuts",
              "Open Quick Launch, Translator, and Type to Click; what Return does after",
              ["hotkey", "shortcut", "key", "open quick launch", "translator", "type to click", "after return"]),
        group("general.behaviour", .general, "general.behaviour", "Launcher Behaviour",
              "Auto-copy, launch at login, menu bar icon, screen awareness, and OCR",
              ["auto copy", "first answer", "launch at login", "menu bar", "icon", "double tap", "right command",
               "screenshot", "ocr", "search text", "welcome", "behaviour", "behavior"]),
        group("general.caffeinate", .general, "general.caffeinate", "Caffeinate",
              "Keep this Mac awake, agent watch, battery cutoff, and the display",
              ["caffeine", "keep awake", "sleep", "power", "assertion", "awake"]),
        group("general.caffeinate.enabled", .general, "general.caffeinate.enabled", "Keep This Mac Awake",
              "The master Caffeinate switch",
              ["caffeinate", "enabled", "keep awake", "sleep", "manual", "indefinite"]),
        group("general.caffeinate.agentWatch", .general, "general.caffeinate.agentWatch", "Agent Watch",
              "Stay awake while Claude Code or Codex is working",
              ["agent", "claude", "codex", "agent watch", "working", "session"]),
        group("general.caffeinate.battery", .general, "general.caffeinate.battery", "Caffeinate Battery Cutoff",
              "On battery at or below this percent, allow sleep again",
              ["battery", "cutoff", "percent", "power", "pause", "sleep"]),
        group("general.caffeinate.display", .general, "general.caffeinate.display", "Keep the Display Awake",
              "Prevent the display from idle-sleeping with the system",
              ["display", "screen", "idle", "sleep", "assertion", "dim"]),
        group("general.quickAI", .general, "general.quickAI", "Quick AI and AI Chat",
              "Primary action, Tab hint, new-chat interval, and model",
              ["quick ai", "ai chat", "primary action", "tab", "new chat", "model", "clarifying questions"]),
        group("general.chat", .general, "general.chat", "Chat defaults",
              "Tools a new chat starts with, web search, and pi handoff",
              ["chat", "tools", "memory", "vault", "skills", "web search", "assistant", "on top", "pi"]),
        group("general.fallback", .general, "general.fallback", "Fallback Commands",
              "What unmatched root-search text runs on Return",
              ["fallback", "unmatched", "return", "ask ai", "default command"]),
        group("general.learning", .general, "general.learning", "Learning & Review",
              "Learned ranking and the local interaction journal",
              ["learn", "learning", "ranking", "choices", "journal", "forget", "retention", "export",
               "interaction", "review"]),
        group("general.history", .general, "general.history", "Chat History",
              "Keep chats, how many, and reopen behaviour",
              ["history", "chats", "keep", "limit", "reopen", "retention"]),
        group("general.appearance", .general, "general.appearance", "Appearance",
              "Dark, light, or follow the system",
              ["appearance", "theme", "dark", "light", "system"]),

        // Keyboard Shortcuts
        group("keyboard.actions", .keyboard, "keyboard.actions", "Rebindable Shortcuts",
              "The in-app keys you can change: attachments, the palette, Quick AI, and AI Chat",
              ["shortcut", "shortcuts", "key", "keys", "keyboard", "rebind", "remap", "change key",
               "attach key", "command palette key", "find in chat", "new chat key", "hotkey",
               "reset shortcut", "reset all shortcuts"]),
        group("keyboard.fixed", .keyboard, "keyboard.fixed", "Fixed Keys",
              "The editing, navigation, and window keys that stay where they are",
              ["fixed", "reserved", "cannot change", "editing keys", "navigation keys",
               "copy paste cut undo", "escape return"]),
        group("keyboard.global", .keyboard, "keyboard.global", "Global Hotkeys",
              "Quick Launch itself, Clipboard History, the Translator, and Type to Click",
              ["global", "system-wide", "hotkey", "quick launch hotkey", "clipboard hotkey",
               "translator hotkey", "type to click hotkey"]),

        // Items
        group("items.list", .items, "items.list", "Items",
              "Aliases and hotkeys for apps, folders, and commands; add or remove",
              ["items", "alias", "aliases", "apps", "applications", "folders", "commands", "hotkey",
               "add", "remove", "delete"]),

        // Models
        group("models.provider", .models, "models.provider", "Provider",
              "Endpoints, API keys, and the models each provider offers",
              ["provider", "endpoint", "api key", "base url", "model", "inference"]),
        group("models.vision", .models, "models.vision", "Vision",
              "Where attached screenshots go",
              ["vision", "image", "screenshot", "model", "multimodal"]),
        group("models.webSearch", .models, "models.webSearch", "Web search",
              "The provider used by Quick AI, AI Chat, and the Translator",
              ["web search", "search provider", "searxng", "bocha", "google"]),
        group("models.instruction", .models, "models.instruction", "Quick-action instruction",
              "The system instruction every provider shares",
              ["instruction", "system prompt", "prompt", "persona"]),

        // Clipboard & Capture
        group("clipboard.history", .clipboard, "clipboard.history", "Clipboard History",
              "Keep copied text, its hotkey, and how many items survive",
              ["clipboard", "history", "copy", "hotkey", "limit", "text"]),
        group("clipboard.colors", .clipboard, "clipboard.colors", "Colors",
              "Color format and picked-color history",
              ["color", "colour", "format", "hex", "rgb", "history", "picker"]),
        group("clipboard.emoji", .clipboard, "clipboard.emoji", "Emoji & Symbols",
              "Emoji skin tone for the Emoji catalog",
              ["emoji", "symbols", "skin tone", "fitzpatrick"]),
        group("clipboard.screenText", .clipboard, "clipboard.screenText", "Text from Screen",
              "On-device OCR behaviour for text copied off the screen",
              ["ocr", "line breaks", "screen text", "text from screen", "vision"]),
        group("clipboard.quicklinks", .clipboard, "clipboard.quicklinks", "Quicklinks",
              "Which browser opens Quick Links",
              ["quicklink", "quick link", "browser", "link", "open", "url"]),
        group("clipboard.catalog", .clipboard, "clipboard.catalog", "Snippets & Quicklinks",
              "Private local items owned by Quick Launch",
              ["snippets", "quicklinks", "quick links", "catalog", "local", "files"]),

        // AI Commands
        group("prompts.commands", .prompts, "prompts.commands", "AI Commands",
              "Saved commands, their prefix, aliases, and hotkeys",
              ["commands", "saved", "prompt", "alias", "prefix", "hotkey", "assistant"]),

        // About
        group("about.version", .about, "about.version", "Version",
              "The installed version",
              ["version", "about", "build"]),
        group("about.updates", .about, "about.updates", "Updates",
              "Check for updates now, and whether to check on launch",
              ["update", "updates", "check", "launch", "upgrade", "release"]),
        group("about.source", .about, "about.source", "Source",
              "The public repository",
              ["source", "github", "repository", "repo", "code"]),
    ]

    private static func group(
        _ id: String,
        _ pane: SettingsPane,
        _ anchor: String,
        _ title: String,
        _ detail: String,
        _ synonyms: [String]
    ) -> SettingsDestination {
        SettingsDestination(
            id: id,
            pane: pane,
            anchor: anchor,
            title: title,
            detail: detail,
            synonyms: synonyms
        )
    }
}
