import Foundation

enum LauncherItemKind: String, Codable, Sendable {
    case application
    case snippet
    case quickLink
    case clipboard
    case command
    case emoji
    case screenshot
    case conversation
}

/// User-owned configuration shared by searchable launcher items.
/// New catalogs can reuse this record without creating another settings store.
struct LauncherItemConfiguration: Codable, Equatable, Hashable, Identifiable, Sendable {
    var kind: LauncherItemKind
    var itemID: String
    var alias: String = ""
    var hotkey: ActionHotkey?
    /// Pinned items sit at the top of their catalog (snippets, quick links,
    /// screenshots). Clipboard entries and chats keep their pin in their own store.
    var isPinned: Bool = false

    var id: String { "\(kind.rawValue):\(itemID)" }

    /// Nothing set: the record can be dropped from settings.
    var isEmpty: Bool {
        alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hotkey == nil && !isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case kind, itemID, alias, hotkey, isPinned
    }
}

extension LauncherItemConfiguration {
    /// Settings written before pins existed have no `isPinned` key.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(LauncherItemKind.self, forKey: .kind)
        itemID = try c.decode(String.self, forKey: .itemID)
        alias = try c.decodeIfPresent(String.self, forKey: .alias) ?? ""
        hotkey = try c.decodeIfPresent(ActionHotkey.self, forKey: .hotkey)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}
