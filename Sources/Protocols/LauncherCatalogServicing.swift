import Foundation

@MainActor
protocol LauncherCatalogServicing: AnyObject {
    var snippets: [LauncherCatalogItem] { get }
    var quickLinks: [LauncherCatalogItem] { get }
    func reload()
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws
    func deleteSnippet(_ item: LauncherCatalogItem) throws
}

@MainActor
protocol ClipboardHistoryServicing: AnyObject {
    var entries: [LauncherCatalogItem] { get }
    func startMonitoring(limit: Int)
    func stopMonitoring()
    func record(_ text: String, limit: Int)
    func clear()
}
