import Foundation
import Testing
@testable import QuickLaunch

@Suite("Launcher catalogs", .serialized)
@MainActor
struct LauncherCatalogTests {
    @Test func tunaCustomItemsAndSmartLinksAreLoadedWithoutMigration() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("apfel-catalog-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = folder.appendingPathComponent("Tuna.plist")
        let config = folder.appendingPathComponent("config.toml")
        let records: [[String: Any]] = [
            ["kind": "text", "id": "one", "label": "Greeting", "value": "Hello"],
            ["kind": "url", "id": "two", "label": "Site", "value": "https://example.com"],
        ]
        let nested = try PropertyListSerialization.data(
            fromPropertyList: records, format: .binary, options: 0
        )
        let root: [String: Any] = ["CustomItemsCatalogItems": nested]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        )
        try plist.write(to: preferences)
        try """
        [[smartLinks.entries]]
        enabled = true
        name = "Search"
        requiresInput = true
        template = "https://example.com/search?q={{input}}"
        """.write(to: config, atomically: true, encoding: .utf8)

        let service = TunaCatalogService(preferencesURL: preferences, configURL: config)
        #expect(service.snippets.map(\.title) == ["Greeting"])
        #expect(service.quickLinks.count == 2)
        #expect(service.quickLinks.contains { $0.title == "Search" && $0.requiresInput })
    }

    @Test func clipboardHistoryDeduplicatesBoundsPersistsAndClears() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("apfel-clipboard-tests-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("clipboard-history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardHistoryStore(fileURL: file)
        store.record("first", limit: 2)
        store.record("second", limit: 2)
        store.record("first", limit: 2)
        #expect(store.entries.map(\.value) == ["first", "second"])

        let loaded = ClipboardHistoryStore(fileURL: file)
        #expect(loaded.entries.map(\.value) == ["first", "second"])
        loaded.clear()
        #expect(loaded.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func emptyLauncherShowsCatalogsAndScopeFiltersItems() {
        let service = FakeLauncherCatalog()
        let vm = QuickViewModel(launcherCatalog: service)
        #expect(vm.launcherMatches.count == 3)
        vm.enterCatalog(.snippets)
        vm.input = "greet"
        #expect(vm.catalogMatches.map(\.title) == ["Greeting"])
        vm.handleCommandK()
        #expect(vm.isCatalogActionPanePresented)
    }
}

@MainActor
private final class FakeLauncherCatalog: LauncherCatalogServicing {
    var snippets = [LauncherCatalogItem(
        kind: .snippet, itemID: "one", title: "Greeting", detail: "Test", value: "Hello"
    )]
    var quickLinks = [LauncherCatalogItem(
        kind: .quickLink, itemID: "two", title: "Site", detail: "example.com",
        value: "https://example.com"
    )]
    func reload() {}
}
