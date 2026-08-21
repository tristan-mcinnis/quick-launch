import Foundation

@MainActor
protocol LauncherCatalogServicing: AnyObject {
    var snippets: [LauncherCatalogItem] { get }
    var quickLinks: [LauncherCatalogItem] { get }
    func reload()
}

@MainActor
protocol ClipboardHistoryServicing: AnyObject {
    var entries: [LauncherCatalogItem] { get }
    func startMonitoring(limit: Int)
    func stopMonitoring()
    func record(_ text: String, limit: Int)
    func clear()
}
