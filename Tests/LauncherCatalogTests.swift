import Foundation
import Testing
@testable import QuickLaunch

@Suite("Launcher catalogs", .serialized)
@MainActor
struct LauncherCatalogTests {
    @Test func tunaCustomItemsAndSmartLinksAreLoadedWithoutMigration() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-catalog-tests-\(UUID().uuidString)")
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
            .appendingPathComponent("quick-launch-clipboard-tests-\(UUID().uuidString)")
        let file = folder.appendingPathComponent("clipboard-history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardHistoryStore(fileURL: file)
        store.record("first", limit: 2)
        store.record("second", limit: 2)
        store.record("first", limit: 2)
        #expect(store.entries.map(\.value) == ["first", "second"])
        store.waitForPendingWrites()

        let loaded = ClipboardHistoryStore(fileURL: file)
        #expect(loaded.entries.map(\.value) == ["first", "second"])
        loaded.clear()
        loaded.waitForPendingWrites()
        #expect(loaded.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func emptyLauncherShowsCatalogsAndScopeFiltersItems() {
        let service = FakeLauncherCatalog()
        let vm = QuickViewModel(launcherCatalog: service)
        // Ask AI plus every catalog root.
        #expect(vm.launcherMatches.count == LauncherCatalogScope.allCases.count + 1)
        #expect(vm.launcherMatches.contains(.catalog(.commands, count: vm.systemCommands.count)))
        vm.enterCatalog(.snippets)
        vm.input = "greet"
        #expect(vm.catalogMatches.map(\.title) == ["Greeting"])
        vm.handleCommandK()
        #expect(vm.isCatalogActionPanePresented)
    }

    @Test func snippetsAndQuickLinksCarryTheDetailPane() {
        let service = FakeLauncherCatalog()
        let vm = QuickViewModel(launcherCatalog: service)

        vm.enterCatalog(.snippets)
        #expect(vm.showsDetailPane, "a selected snippet previews its stored text")
        #expect(vm.detailItem?.kind == .snippet)
        #expect(vm.detailItem?.value == "Hello")
        #expect(vm.currentPanelWidth == QuickViewModel.panelWidthWithDetail)

        vm.leaveCatalog()
        vm.enterCatalog(.quickLinks)
        #expect(vm.showsDetailPane, "a selected quick link previews its target")
        #expect(vm.detailItem?.kind == .quickLink)
        #expect(vm.detailItem?.value == "https://example.com")

        vm.leaveCatalog()
        vm.enterCatalog(.commands)
        #expect(!vm.showsDetailPane, "catalogs without a preview keep the narrow panel")
        #expect(vm.currentPanelWidth == QuickViewModel.panelWidth)
    }

    @Test func windowAliasesAreSearchableFromTheLauncherRoot() {
        let vm = QuickViewModel()
        let item = vm.windowCommand(for: .bottomHalf)
        vm.setLauncherItemAlias("lower", for: item)
        vm.input = "lower"

        #expect(vm.launcherMatches.contains(.item(item)))
    }

    @Test func settingsAreSearchableFromTheLauncherRoot() {
        let vm = QuickViewModel()
        vm.input = "settings"

        #expect(vm.launcherMatches.contains {
            guard case .item(let item) = $0 else { return false }
            return item.itemID == "settings.open"
        })
    }

    @Test func snippetCanBeEditedAndDeletedThroughCatalogService() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-mutation-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = folder.appendingPathComponent("Tuna.plist")
        let config = folder.appendingPathComponent("config.toml")
        let records: [[String: Any]] = [
            ["kind": "text", "id": "one", "label": "Before", "value": "Original"],
            ["kind": "url", "id": "two", "label": "Keep", "value": "https://example.com"],
        ]
        let nested = try PropertyListSerialization.data(
            fromPropertyList: records, format: .binary, options: 0
        )
        let root = try PropertyListSerialization.data(
            fromPropertyList: ["CustomItemsCatalogItems": nested], format: .binary, options: 0
        )
        try root.write(to: preferences)
        let service = TunaCatalogService(preferencesURL: preferences, configURL: config)
        let snippet = try #require(service.snippets.first)
        try service.updateSnippet(snippet, title: "After", value: "Updated")
        #expect(service.snippets.first?.title == "After")
        #expect(service.quickLinks.count == 1)
        try service.deleteSnippet(try #require(service.snippets.first))
        #expect(service.snippets.isEmpty)
        #expect(service.quickLinks.count == 1)
        #expect((try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains {
            $0.contains("quick-launch-backup")
        })
    }

    @Test func catalogReturnsToRootAfterIdle() async {
        let vm = QuickViewModel(launcherCatalog: FakeLauncherCatalog())
        vm.catalogIdleResetDelay = .milliseconds(20)
        vm.enterCatalog(.snippets)
        vm.input = "greet"
        vm.noteInteraction()
        // Other suites share the main actor; wait for the reset rather than a fixed delay.
        for _ in 0..<100 where vm.catalogScope != nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(vm.catalogScope == nil)
        #expect(vm.input.isEmpty)
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
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {
        guard let index = snippets.firstIndex(where: { $0.id == item.id }) else { return }
        snippets[index] = LauncherCatalogItem(
            kind: .snippet, itemID: item.itemID, title: title, detail: item.detail, value: value
        )
    }
    func deleteSnippet(_ item: LauncherCatalogItem) throws {
        snippets.removeAll { $0.id == item.id }
    }
}
