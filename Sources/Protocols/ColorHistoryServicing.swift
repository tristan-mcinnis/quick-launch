import Foundation

/// Picked colors, newest first, kept locally so a color can be copied again
/// in any format long after the loupe closed.
@MainActor
protocol ColorHistoryServicing: AnyObject {
    var entries: [LauncherCatalogItem] { get }
    /// The format every row's value is written in. Changing it rewrites the rows.
    var preferredFormat: ColorFormat { get set }
    @discardableResult
    func record(_ color: PickedColor, limit: Int) -> LauncherCatalogItem
    func color(for item: LauncherCatalogItem) -> PickedColor?
    func remove(_ item: LauncherCatalogItem)
    func togglePin(_ item: LauncherCatalogItem)
    func clear()
}
