import Foundation

@MainActor
final class ColorHistoryStore: ColorHistoryServicing {
    private struct StoredColor: Codable, Sendable {
        var id: String
        var color: PickedColor
        var pickedAt: Date
        var pinned: Bool?
    }

    private(set) var entries: [LauncherCatalogItem] = []
    var preferredFormat: ColorFormat = .hex {
        didSet {
            guard preferredFormat != oldValue else { return }
            rebuildPublicEntries()
        }
    }

    private var storedColors: [StoredColor] = []
    private let file: JSONFileStore<[StoredColor]>

    init(fileURL: URL? = nil, preferredFormat: ColorFormat = .hex) {
        self.file = JSONFileStore(fileURL: fileURL ?? Self.defaultFileURL())
        self.preferredFormat = preferredFormat
        load()
    }

    /// Records a pick. Picking a color that is already in the list moves it
    /// back to the top instead of adding a duplicate row.
    @discardableResult
    func record(_ color: PickedColor, limit: Int) -> LauncherCatalogItem {
        let id = color.storageID
        let wasPinned = storedColors.first { $0.id == id }?.pinned ?? false
        storedColors.removeAll { $0.id == id }
        storedColors.insert(
            StoredColor(id: id, color: color, pickedAt: Date(), pinned: wasPinned),
            at: 0
        )
        prune(limit: limit)
        rebuildPublicEntries()
        save()
        return entries.first { $0.itemID == id } ?? Self.item(for: storedColors[0], format: preferredFormat)
    }

    func color(for item: LauncherCatalogItem) -> PickedColor? {
        storedColors.first { $0.id == item.itemID }?.color
            ?? PickedColor(hexString: item.itemID)
    }

    func remove(_ item: LauncherCatalogItem) {
        storedColors.removeAll { $0.id == item.itemID }
        rebuildPublicEntries()
        save()
    }

    func togglePin(_ item: LauncherCatalogItem) {
        guard let index = storedColors.firstIndex(where: { $0.id == item.itemID }) else { return }
        storedColors[index].pinned = !(storedColors[index].pinned ?? false)
        rebuildPublicEntries()
        save()
    }

    func clear() {
        storedColors.removeAll()
        entries.removeAll()
        file.delete()
    }

    /// Keeps every pinned color and the newest `limit` unpinned ones.
    private func prune(limit: Int) {
        let cap = max(1, min(limit, 200))
        var kept: [StoredColor] = []
        var unpinned = 0
        for stored in storedColors {
            if stored.pinned == true {
                kept.append(stored)
            } else if unpinned < cap {
                kept.append(stored)
                unpinned += 1
            }
        }
        storedColors = kept
    }

    private func rebuildPublicEntries() {
        let ordered = storedColors.filter { $0.pinned == true }
            + storedColors.filter { $0.pinned != true }
        entries = ordered.map { Self.item(for: $0, format: preferredFormat) }
    }

    private static func item(for stored: StoredColor, format: ColorFormat) -> LauncherCatalogItem {
        let stamp = stored.pickedAt.formatted(date: .abbreviated, time: .shortened)
        let isPinned = stored.pinned == true
        // Every notation is searchable, so "rgb(74" and "steel" both land here.
        let keywords = (stored.color.allStrings.map(\.1)
            + [stored.color.name, isPinned ? "pinned" : "", "color colour swatch"])
            .joined(separator: " ")
        return LauncherCatalogItem(
            kind: .color,
            itemID: stored.id,
            title: stored.color.string(in: format),
            detail: (isPinned ? "Pinned · " : "") + "\(stored.color.name) · \(stamp)",
            value: stored.color.string(in: format),
            keywords: keywords,
            isPinned: isPinned,
            capturedAt: stored.pickedAt
        )
    }

    private func load() {
        guard let decoded = file.load() else { return }
        storedColors = decoded
        rebuildPublicEntries()
    }

    private func save() {
        file.save(storedColors)
    }

    /// Tests: block until queued writes are on disk.
    func waitForPendingWrites() {
        file.flush()
    }

    private static func defaultFileURL() -> URL {
        AppPaths.file("color-history.json")
    }
}
