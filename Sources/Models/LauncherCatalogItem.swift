import Foundation

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
        case .clipboard: return "clipboard"
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
        case .chats: "Quick AI Chats"
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
}
