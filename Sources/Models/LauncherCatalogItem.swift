import Foundation

struct LauncherCatalogItem: Identifiable, Equatable, Sendable {
    var kind: LauncherItemKind
    var itemID: String
    var title: String
    var detail: String
    var value: String
    var requiresInput: Bool = false

    var id: String { "\(kind.rawValue):\(itemID)" }

    var defaultActionTitle: String {
        switch kind {
        case .application: "Open"
        case .snippet, .clipboard: "Paste"
        case .quickLink: requiresInput ? "Enter Input" : "Open"
        }
    }

    var systemImage: String {
        switch kind {
        case .application: "app"
        case .snippet: "text.quote"
        case .quickLink: "link"
        case .clipboard: "clipboard"
        }
    }
}

enum LauncherCatalogScope: String, CaseIterable, Identifiable, Sendable {
    case snippets
    case quickLinks
    case clipboard

    var id: String { rawValue }
    var title: String {
        switch self {
        case .snippets: "Snippets"
        case .quickLinks: "Quick Links"
        case .clipboard: "Clipboard History"
        }
    }
    var aliases: [String] {
        switch self {
        case .snippets: ["snippets", "snippet", "sni"]
        case .quickLinks: ["quick links", "links", "link"]
        case .clipboard: ["clipboard history", "clipboard", "clip"]
        }
    }
    var systemImage: String {
        switch self {
        case .snippets: "text.quote"
        case .quickLinks: "link"
        case .clipboard: "clipboard"
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
