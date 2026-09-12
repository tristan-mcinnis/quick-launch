import Foundation

@MainActor
protocol LauncherCatalogServicing: AnyObject {
    var snippets: [LauncherCatalogItem] { get }
    var quickLinks: [LauncherCatalogItem] { get }
    func reload()
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws
    func deleteSnippet(_ item: LauncherCatalogItem) throws
    /// Adds a snippet to the store and returns the stored item.
    func createSnippet(title: String, value: String) throws -> LauncherCatalogItem
    /// Adds a fixed Quick Link to the store and returns the stored item.
    func createQuickLink(title: String, value: String) throws -> LauncherCatalogItem
    /// Renames a stored Quick Link or points it somewhere else. Smart Links
    /// come from a file this app only reads, so they are never editable.
    func updateQuickLink(_ item: LauncherCatalogItem, title: String, value: String) throws
    func deleteQuickLink(_ item: LauncherCatalogItem) throws
}

enum LauncherCatalogError: LocalizedError {
    case creationUnsupported
    case editingUnsupported

    var errorDescription: String? {
        switch self {
        case .creationUnsupported: "This catalog cannot create snippets."
        case .editingUnsupported: "This catalog cannot change Quicklinks."
        }
    }
}

extension LauncherCatalogServicing {
    func createSnippet(title: String, value: String) throws -> LauncherCatalogItem {
        throw LauncherCatalogError.creationUnsupported
    }
    func createQuickLink(title: String, value: String) throws -> LauncherCatalogItem {
        throw LauncherCatalogError.creationUnsupported
    }
    func updateQuickLink(_ item: LauncherCatalogItem, title: String, value: String) throws {
        throw LauncherCatalogError.editingUnsupported
    }
    func deleteQuickLink(_ item: LauncherCatalogItem) throws {
        throw LauncherCatalogError.editingUnsupported
    }
}

@MainActor
protocol ClipboardHistoryServicing: AnyObject {
    var entries: [LauncherCatalogItem] { get }
    func startMonitoring(limit: Int)
    func stopMonitoring()
    func record(_ text: String, limit: Int)
    func remove(_ item: LauncherCatalogItem)
    /// Pinned entries stay at the top and are never pruned by the limit.
    func togglePin(_ item: LauncherCatalogItem)
    func clear()
    /// The full clipboard payload for a stored item, with its raw items loaded
    /// from the blob (in-memory cache first, disk off-main on a miss). Used by
    /// previews and restore.
    func payload(for item: LauncherCatalogItem) async -> ClipboardPayload?
}

extension ClipboardHistoryServicing {
    func togglePin(_ item: LauncherCatalogItem) {}
    func payload(for item: LauncherCatalogItem) async -> ClipboardPayload? { nil }
}
