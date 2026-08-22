import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Pinned items", .serialized)
@MainActor
struct PinnedItemTests {
    @Test func snippetsQuickLinksAndScreenshotsOfferPinAndUnpin() {
        let snippet = LauncherCatalogItem(kind: .snippet, itemID: "a", title: "Sig", detail: "", value: "x")
        #expect(ItemActionCatalog.actions(for: .item(snippet), pasteTarget: nil).map(\.title).contains("Pin to Top"))
        var pinnedSnippet = snippet
        pinnedSnippet.isPinned = true
        let unpin = ItemActionCatalog.actions(for: .item(pinnedSnippet), pasteTarget: nil).first { $0.kind == .pin }
        #expect(unpin?.title == "Unpin")
        #expect(unpin?.shortcut?.keyCaps == ["⇧", "⌘", "P"])

        let link = LauncherCatalogItem(kind: .quickLink, itemID: "l", title: "Docs", detail: "", value: "https://x")
        #expect(ItemActionCatalog.actions(for: .item(link), pasteTarget: nil).map(\.title)
            == ["Open Link", "Copy Link", "Pin to Top", "Set Alias…", "Set Hotkey…"])
        let shot = LauncherCatalogItem(kind: .screenshot, itemID: "file-1", title: "Shot", detail: "", value: "/tmp/x.png")
        #expect(ItemActionCatalog.actions(for: .item(shot), pasteTarget: nil).map(\.title).contains("Pin to Top"))
        let command = LauncherCatalogItem(kind: .command, itemID: "w", title: "Left Half", detail: "", value: "window.leftHalf")
        #expect(!ItemActionCatalog.actions(for: .item(command), pasteTarget: nil).map(\.title).contains("Pin to Top"))
        let emoji = LauncherCatalogItem(kind: .emoji, itemID: "e", title: "Fire", detail: "", value: "🔥")
        #expect(!ItemActionCatalog.actions(for: .item(emoji), pasteTarget: nil).map(\.title).contains("Pin to Top"))
    }

    @Test func configurationKeepsThePinAndReadsOldRecords() throws {
        let old = try JSONDecoder().decode(
            LauncherItemConfiguration.self,
            from: Data(#"{"kind":"snippet","itemID":"x","alias":"sig"}"#.utf8)
        )
        #expect(old.alias == "sig" && old.hotkey == nil && !old.isPinned)
        var pinned = LauncherItemConfiguration(kind: .quickLink, itemID: "y")
        #expect(pinned.isEmpty)
        pinned.isPinned = true
        #expect(!pinned.isEmpty)
        let back = try JSONDecoder().decode(LauncherItemConfiguration.self, from: JSONEncoder().encode(pinned))
        #expect(back == pinned && back.isPinned)
    }

    @Test func pinnedSnippetsLeadTheCatalogAboveLearnedFavouritesAndUnpinForgets() async {
        let catalog = PinFakeCatalog()
        let store = LauncherUsageStore(fileURL: nil)
        let vm = QuickViewModel(launcherCatalog: catalog, launcherUsage: store)
        store.recordUse(itemID: "snippet:gamma", scope: LauncherCatalogScope.snippets.rawValue)
        vm.enterCatalog(.snippets)
        vm.input = ""
        #expect(titles(vm.launcherMatches) == ["Gamma", "Alpha", "Beta"])

        let beta = LauncherSearchResult.item(catalog.snippets[1])
        let pin = ItemActionCatalog.actions(for: beta, pasteTarget: nil).first { $0.kind == .pin }!
        await vm.perform(pin, on: beta)
        #expect(titles(vm.launcherMatches) == ["Beta", "Gamma", "Alpha"])
        #expect(vm.launcherMatches.first.map(isPinned) == true)
        #expect(vm.snippets.first?.isPinned == true)
        #expect(vm.settings.launcherItemConfiguration(kind: .snippet, itemID: "beta")?.isPinned == true)
        #expect(vm.isLauncherItemPinned(catalog.snippets[1]))

        // The row offers Unpin now, and ⌘⇧P from the list toggles it back.
        vm.applicationSelectionIndex = 0
        #expect(vm.focusedItemActions.first { $0.kind == .pin }?.title == "Unpin")
        #expect(vm.performShortcut(characters: "p", keyCode: 35, modifiers: [.command, .shift]))
        #expect(titles(vm.launcherMatches) == ["Gamma", "Alpha", "Beta"])
        #expect(vm.settings.launcherItemConfiguration(kind: .snippet, itemID: "beta") == nil)
        #expect(!vm.isLauncherItemPinned(catalog.snippets[1]))
    }

    @Test func pinnedMatchesRankFirstWhenTypingAndDeletingForgetsThePin() async {
        let catalog = PinFakeCatalog()
        catalog.snippets = [
            LauncherCatalogItem(kind: .snippet, itemID: "draft", title: "Report Draft", detail: "", value: "d"),
            LauncherCatalogItem(kind: .snippet, itemID: "final", title: "Report Final", detail: "", value: "f"),
        ]
        let vm = QuickViewModel(launcherCatalog: catalog, launcherUsage: LauncherUsageStore(fileURL: nil))
        vm.enterCatalog(.snippets)
        vm.input = "rep"
        #expect(titles(vm.launcherMatches) == ["Report Draft", "Report Final"])
        vm.togglePinLauncherItem(catalog.snippets[1])
        #expect(titles(vm.launcherMatches) == ["Report Final", "Report Draft"])

        // Root search keeps the pinned item ahead of its unpinned twin too.
        vm.leaveCatalog()
        vm.input = "report"
        let rootTitles = vm.launcherMatches.compactMap { result -> String? in
            if case .item(let item) = result, item.kind == .snippet { return item.title }
            return nil
        }
        #expect(rootTitles == ["Report Final", "Report Draft"])

        vm.setLauncherItemAlias("rf", for: catalog.snippets[1])
        #expect(vm.deleteSnippet(catalog.snippets[1]))
        #expect(vm.settings.launcherItemConfiguration(kind: .snippet, itemID: "final") == nil)
        #expect(catalog.snippets.map(\.title) == ["Report Draft"])
    }

    @Test func pinnedScreenshotsSitAtTheTopOfTheScreenshotsCatalog() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-pin-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let older = folder.appendingPathComponent("Screenshot 2026-08-20 at 09.41.12.png")
        let newer = folder.appendingPathComponent("Screenshot 2026-08-21 at 10.02.33.png")
        try ScreenAwarenessTests.writeImage(to: older, text: "older")
        try ScreenAwarenessTests.writeImage(to: newer, text: "newer")

        let vm = QuickViewModel(launcherUsage: LauncherUsageStore(fileURL: nil))
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)
        vm.input = ""
        let files = vm.launcherMatches.compactMap { result -> LauncherCatalogItem? in
            if case .item(let item) = result, item.kind == .screenshot { return item }
            return nil
        }
        #expect(files.map { ($0.value as NSString).lastPathComponent } == [newer.lastPathComponent, older.lastPathComponent])
        #expect(vm.launcherMatches.first.map(isPinned) == false)

        let olderItem = files[1]
        vm.togglePinLauncherItem(olderItem)
        guard case .item(let top)? = vm.launcherMatches.first else {
            Issue.record("no rows")
            return
        }
        #expect((top.value as NSString).lastPathComponent == older.lastPathComponent && top.isPinned)

        vm.input = "screenshot"
        guard case .item(let match)? = vm.launcherMatches.first else {
            Issue.record("no matches")
            return
        }
        #expect((match.value as NSString).lastPathComponent == older.lastPathComponent)
    }

    private func titles(_ results: [LauncherSearchResult]) -> [String] {
        results.compactMap { result in
            if case .item(let item) = result { return item.title }
            return nil
        }
    }

    private func isPinned(_ result: LauncherSearchResult) -> Bool {
        if case .item(let item) = result { return item.isPinned }
        return false
    }
}

private final class PinFakeCatalog: LauncherCatalogServicing {
    var snippets = [
        LauncherCatalogItem(kind: .snippet, itemID: "alpha", title: "Alpha", detail: "", value: "a"),
        LauncherCatalogItem(kind: .snippet, itemID: "beta", title: "Beta", detail: "", value: "b"),
        LauncherCatalogItem(kind: .snippet, itemID: "gamma", title: "Gamma", detail: "", value: "g"),
    ]
    var quickLinks: [LauncherCatalogItem] = []
    func reload() {}
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteSnippet(_ item: LauncherCatalogItem) throws {
        snippets.removeAll { $0.id == item.id }
    }
}
