import Foundation

/// On/off state a row reports at a glance: green light and "On", red light
/// and "Off". Status colour only, never chrome.
enum LauncherStatusLight: Equatable, Sendable {
    case on
    case off

    var label: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        }
    }
}

struct LauncherCatalogItem: Identifiable, Equatable, Sendable {
    var kind: LauncherItemKind
    var itemID: String
    var title: String
    var detail: String
    var value: String
    var requiresInput: Bool = false
    /// Extra search words that are not part of the title (emoji names, tags).
    var keywords: String = ""
    /// Pinned items stay at the top of their catalog. Clipboard entries and
    /// chats also never expire while pinned.
    var isPinned: Bool = false
    /// Screenshots only: when the file was captured, for date filters.
    var capturedAt: Date?
    /// A live on/off state the row shows as a coloured light with a word,
    /// in place of its type label. Caffeinate uses it.
    var statusLight: LauncherStatusLight?
    /// Clipboard entries: the full multi-type contents so the UI can preview
    /// and restore the original representation. Nil for plain-text entries
    /// and for every non-clipboard kind.
    var clipboardPayload: ClipboardPayload? = nil
    /// Chats found by a search in their text: the line that shows where
    /// (`ChatSearch`). The row draws it under the title, with the count and
    /// time on the trailing edge. Nil for a title hit and every other kind.
    var chatSnippet: ChatSnippet? = nil

    var id: String { "\(kind.rawValue):\(itemID)" }

    /// Icons for the helper commands that are neither toggles nor panes.
    static let helperCommandIcons = [
        "color.pick": "eyedropper",
        "color.pickPaste": "eyedropper.halffull",
        "ocr.area": "text.viewfinder",
        "ocr.areaPaste": "text.viewfinder",
        "paste.plain": "doc.on.clipboard",
        "clipboard.cleanLink": "link.badge.plus",
        "screenshot.latest": "photo.badge.plus",
        "screenshot.pasteLatest": "photo.on.rectangle",
        "screenshot.window": "macwindow.on.rectangle",
        "screenshot.display": "rectangle.dashed.badge.record",
        "awareness.area": "rectangle.dashed",
        "awareness.selection": "text.cursor",
        "caffeinate.toggle": "cup.and.saucer.fill",
        "caffeinate.until": "clock",
        "caffeinate.30": "timer",
        "caffeinate.60": "timer",
        "caffeinate.120": "timer",
        "caffeinate.240": "timer",
        "caffeinate.agentWatch": "eye",
        "speech.readAloud": "speaker.wave.2",
        "speech.stop": "speaker.slash",
    ]

    var defaultActionTitle: String {
        switch kind {
        case .application: "Open"
        case .snippet, .clipboard, .emoji: "Paste"
        case .quickLink: requiresInput ? "Enter Input" : "Open"
        case .command: value.hasPrefix("vault.") ? "Search" : "Run"
        case .screenshot: "Paste"
        case .conversation: "Continue"
        case .askAI: "Ask"
        case .folder: "Open"
        case .answer: "Copy"
        case .screenHistory: "Open moment"
        case .color: "Paste"
        }
    }

    var systemImage: String {
        switch kind {
        case .application: return "app"
        case .snippet: return "text.quote"
        case .quickLink: return "link"
        case .clipboard: return clipboardPayload?.kind == .image ? "photo" : "clipboard"
        case .command:
            if let icon = Self.helperCommandIcons[value] { return icon }
            if value.hasPrefix("vault.") { return "magnifyingglass" }
            if value.hasPrefix("settingspane."),
               let pane = SystemSettingsPaneCatalog.panes.first(where: {
                   $0.id == String(value.dropFirst("settingspane.".count))
               }) {
                return pane.systemImage
            }
            if value.hasPrefix("toggle."),
               let toggle = QuickToggle(rawValue: String(value.dropFirst("toggle.".count))) {
                return toggle.systemImage
            }
            return "rectangle.3.group"
        case .emoji: return "face.smiling"
        case .screenshot: return "photo"
        case .conversation: return "bubble.left.and.text.bubble.right"
        case .askAI: return "sparkles"
        case .folder: return "folder"
        case .answer: return "equal.circle"
        case .screenHistory: return "clock.arrow.circlepath"
        case .color: return "eyedropper"
        }
    }
}

enum LauncherCatalogScope: String, CaseIterable, Identifiable, Sendable {
    case snippets
    case quickLinks
    case clipboard
    case emoji
    case screenshots
    case caffeinate
    case chats
    case commands
    case folders
    case vaultSearch
    case screenHistory
    case colors

    var id: String { rawValue }
    var title: String {
        switch self {
        case .snippets: "Snippets"
        case .quickLinks: "Quicklinks"
        case .clipboard: "Clipboard History"
        case .emoji: "Emoji & Symbols"
        case .screenshots: "Screenshots"
        case .caffeinate: "Caffeinate"
        case .chats: "Chats"
        case .commands: "Commands"
        case .folders: "Folders"
        case .vaultSearch: "Vault Search"
        case .screenHistory: "Screen History"
        case .colors: "Colors"
        }
    }
    var aliases: [String] {
        switch self {
        case .snippets: ["snippets", "snippet", "sni"]
        case .quickLinks: ["quick links", "links", "link"]
        case .clipboard: ["clipboard history", "clipboard", "clip"]
        case .emoji: ["emoji", "emojis", "symbols", "symbol", "emoji and symbols"]
        case .screenshots: ["screenshots", "screenshot", "shots", "capture", "photos"]
        case .caffeinate: ["caffeinate", "caffeine", "awake", "keep awake", "decaffeinate", "sleep"]
        case .chats: ["chats", "quick ai", "ai chats", "history", "conversations", "recent chats"]
        case .commands: ["commands", "window management", "windows", "toggles", "settings panes"]
        case .folders: ["folders", "folder", "places", "locations", "finder"]
        case .vaultSearch: ["vault search", "vault", "projects", "project search"]
        case .screenHistory: ["screen history", "screen memory", "what i saw", "coast", "rewind"]
        case .colors: ["colors", "colours", "color picker", "colour picker", "pick color", "eyedropper", "hex", "swatches"]
        }
    }
    var systemImage: String {
        switch self {
        case .snippets: "text.quote"
        case .quickLinks: "link"
        case .clipboard: "clipboard"
        case .emoji: "face.smiling"
        case .screenshots: "camera.viewfinder"
        case .caffeinate: "cup.and.saucer"
        case .chats: "bubble.left.and.text.bubble.right"
        case .commands: "command"
        case .folders: "folder"
        case .vaultSearch: "magnifyingglass"
        case .screenHistory: "clock.arrow.circlepath"
        case .colors: "eyedropper"
        }
    }
}

enum LauncherSearchResult: Identifiable, Equatable, Sendable {
    case application(LaunchableApplication)
    case catalog(LauncherCatalogScope, count: Int)
    case item(LauncherCatalogItem)

    var id: String {
        switch self {
        case .application(let application): "application:\(application.id)"
        case .catalog(let scope, _): "catalog:\(scope.id)"
        case .item(let item): item.id
        }
    }
}

enum StableIdentifier {
    static func make(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// Same FNV-1a over raw bytes, so image and rich-content entries get a
    /// stable, content-derived identity for de-duplication and pinning.
    static func make(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// Text entries keep the old string id only when they are plain text (so
    /// existing history and pins still match). Non-text, or text with a
    /// retained non-text representation, hashes every representation with item
    /// boundaries so re-copying the same content de-duplicates faithfully.
    static func make(_ payload: ClipboardPayload) -> String {
        if payload.isPlainTextOnly {
            return make(payload.text)
        }
        if let items = payload.items {
            return make(items)
        }
        return payload.blobKey ?? make(payload.text)
    }

    /// FNV-1a over an ordered list of pasteboard items, hashing each represent-
    /// ation's type and bytes so item boundaries are preserved.
    static func make(_ items: [[ClipboardRawItem]]) -> String {
        var data = Data()
        for item in items {
            for rep in item {
                data.append(Data(rep.type.utf8))
                data.append(rep.data)
            }
        }
        return make(data)
    }
}
