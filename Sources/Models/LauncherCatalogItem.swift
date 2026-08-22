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
    /// Clipboard entries only: pinned entries stay at the top and never expire.
    var isPinned: Bool = false
    /// Screenshots only: when the file was captured, for date filters.
    var capturedAt: Date?

    var id: String { "\(kind.rawValue):\(itemID)" }

    var defaultActionTitle: String {
        switch kind {
        case .application: "Open"
        case .snippet, .clipboard, .emoji: "Paste"
        case .quickLink: requiresInput ? "Enter Input" : "Open"
        case .command: "Run"
        case .screenshot: "Attach"
        }
    }

    var systemImage: String {
        switch kind {
        case .application: "app"
        case .snippet: "text.quote"
        case .quickLink: "link"
        case .clipboard: "clipboard"
        case .command: "rectangle.3.group"
        case .emoji: "face.smiling"
        case .screenshot: "photo"
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
    case commands

    var id: String { rawValue }
    var title: String {
        switch self {
        case .snippets: "Snippets"
        case .quickLinks: "Quick Links"
        case .clipboard: "Clipboard History"
        case .emoji: "Emoji & Symbols"
        case .screenshots: "Screenshots"
        case .caffeinate: "Caffeinate"
        case .commands: "Commands"
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
        case .commands: ["commands", "window management", "windows"]
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
        case .commands: "command"
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
