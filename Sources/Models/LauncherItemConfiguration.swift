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
    /// The one row that sends the typed text to the AI.
    case askAI
    /// A folder opened in Finder: built-in user folders and ones added in Settings.
    case folder
    /// A local answer computed as you type (math, a conversion, a date).
    case answer
    /// A local, time-stamped moment from the owned or legacy screen-history store.
    case screenHistory
    /// A color sampled from the screen with the eyedropper.
    case color
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
