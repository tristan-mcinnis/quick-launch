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

    var id: String { "\(kind.rawValue):\(itemID)" }
}
