import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Input modes: translate, caffeinate until, clipboard pins", .serialized)
@MainActor
struct InputModeTests {
    @Test func emptyBackspacePopsExactlyOneLayer() async {
        let vm = QuickViewModel(screenshotService: PopFakeScreenshotService())
        #expect(!vm.popLayerForEmptyBackspace())

        vm.enterCatalog(.caffeinate)
        #expect(vm.popLayerForEmptyBackspace())
        #expect(vm.catalogScope == nil)

        vm.enterInputMode(.caffeinateUntil)
        vm.input = "typed"
        #expect(!vm.popLayerForEmptyBackspace(), "text present: Backspace deletes a character")
        vm.input = ""
        #expect(vm.popLayerForEmptyBackspace())
        #expect(vm.inputMode == nil)

        _ = await vm.attachScreenshot(.window, clearingInput: true)
        #expect(vm.pendingImage != nil)
        #expect(vm.popLayerForEmptyBackspace())
        #expect(vm.pendingImage == nil)

        vm.output = "Answer"
        vm.lastQuestion = "q"
        #expect(vm.popLayerForEmptyBackspace())
        #expect(vm.output.isEmpty)
        #expect(!vm.popLayerForEmptyBackspace())
    }

    @Test func caffeinateUntilModeParsesOrExplains() async {
        let manager = UntilRecordingManager()
        let vm = QuickViewModel(caffeinateManager: manager)
        vm.enterInputMode(.caffeinateUntil)
        #expect(vm.footerContext == "Caffeinate Until")
        vm.input = "whenever"
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.errorMessage == CaffeinateSchedule.usage)
        #expect(vm.inputMode == .caffeinateUntil)

        vm.input = "90m"
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.inputMode == nil)
        #expect(manager.until != nil)
        #expect(vm.settings.caffeinateUntil == manager.until)
        #expect(vm.isCaffeinating)
    }

    @Test func clipboardPinsSurviveTheLimitAndStayOnTop() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-pins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardHistoryStore(fileURL: folder.appendingPathComponent("clipboard-history.json"))
        store.record("keep me", limit: 10)
        store.record("two", limit: 10)
        store.togglePin(store.entries.first { $0.value == "keep me" }!)
        #expect(store.entries.first?.value == "keep me")
        #expect(store.entries.first?.isPinned == true)
        #expect(store.entries.first?.detail.hasPrefix("Pinned") == true)
        for index in 0..<12 { store.record("entry \(index)", limit: 10) }
        #expect(store.entries.first?.value == "keep me")
        #expect(store.entries.count == 11)
        store.waitForPendingWrites()

        let reloaded = ClipboardHistoryStore(fileURL: folder.appendingPathComponent("clipboard-history.json"))
        #expect(reloaded.entries.first?.isPinned == true)
        reloaded.togglePin(reloaded.entries.first!)
        #expect(reloaded.entries.first?.value == "entry 11")
    }

    @Test func clipboardEntriesBecomeSnippetsAndQuickLinks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-convert-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardHistoryStore(fileURL: folder.appendingPathComponent("clipboard-history.json"))
        store.record("https://example.com/docs", limit: 10)
        store.record("Best regards, T", limit: 10)
        let catalog = ConvertRecordingCatalog()
        let vm = QuickViewModel(launcherCatalog: catalog, clipboardHistory: store)
        vm.enterCatalog(.clipboard)

        let text = vm.launcherMatches.first { if case .item(let item) = $0 { return item.value == "Best regards, T" }; return false }!
        let textActions = ItemActionCatalog.actions(for: text, pasteTarget: nil)
        #expect(!textActions.contains { $0.kind == .saveAsQuickLink })
        await vm.perform(textActions.first { $0.kind == .saveAsSnippet }!, on: text)
        #expect(catalog.snippets.map(\.value) == ["Best regards, T"])
        #expect(vm.catalogScope == .snippets)
        #expect(vm.activeItemActionForm == .edit)

        vm.enterCatalog(.clipboard)
        let link = vm.launcherMatches.first { if case .item(let item) = $0 { return item.value.hasPrefix("https://") }; return false }!
        let linkActions = ItemActionCatalog.actions(for: link, pasteTarget: nil)
        await vm.perform(linkActions.first { $0.kind == .saveAsQuickLink }!, on: link)
        #expect(catalog.quickLinks.map(\.title) == ["example.com"])
        #expect(vm.catalogScope == .quickLinks)
        #expect(vm.activeItemActionForm == .alias)
    }

    @Test func screenshotsCatalogListsCapturesThenFilesWithDateWords() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-shotcat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let old = folder.appendingPathComponent("Screenshot 2026-08-11 at 14.32.07.png")
        let recent = folder.appendingPathComponent("CleanShot 2026-08-22 at 09.00.00.png")
        try png.write(to: old); try png.write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: recent.path)
        try png.write(to: folder.appendingPathComponent("unrelated.png"))

        let vm = QuickViewModel()
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)
        let items = vm.catalogItems
        #expect(items.prefix(2).allSatisfy { $0.kind == .command })
        #expect(items.filter { $0.kind == .screenshot }.count == 2)
        // Temp paths come back through /private; compare file names.
        func names(_ list: [LauncherCatalogItem]) -> [String] { list.map { ($0.value as NSString).lastPathComponent } }
        #expect(names(items.filter { $0.kind == .screenshot }).first == recent.lastPathComponent)
        #expect(items.first { ($0.value as NSString).lastPathComponent == old.lastPathComponent }?.title == "Aug 11, 14:32:07")

        vm.input = "today"
        #expect(names(vm.catalogMatches) == [recent.lastPathComponent])
        vm.input = "7d"
        #expect(names(vm.catalogMatches) == [recent.lastPathComponent])
        vm.input = "last 30 days 11"
        #expect(names(vm.catalogMatches) == [old.lastPathComponent])
        let parsed = ScreenshotQuery.parse("yesterday acme")
        #expect(parsed.needle == "acme" && parsed.interval != nil)
        #expect(ScreenshotQuery.parse("acme").interval == nil)

        let file = vm.catalogMatches.first!
        #expect(ItemActionCatalog.actions(for: .item(file), pasteTarget: nil).map(\.title)
            == ["Paste Image", "Copy Image", "Attach to Question", "Quick Look", "Pin to Top", "Reveal in Finder", "Copy File Path", "Move to Trash"])
    }

    @Test func screenshotSearchForgivesPluralsAndDateWordsAnywhere() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-shotsearch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let old = folder.appendingPathComponent("Screenshot 2026-08-11 at 14.32.07.png")
        let recent = folder.appendingPathComponent("Screenshot 2026-08-22 at 09.00.00.png")
        try png.write(to: old); try png.write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: recent.path)

        let vm = QuickViewModel()
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)

        // The word people actually type must not empty the catalog.
        vm.input = "screenshots"
        let pluralHits = vm.catalogMatches.filter { $0.kind == .screenshot }
        #expect(pluralHits.count == 2)
        #expect((pluralHits.first?.value as NSString?)?.lastPathComponent == recent.lastPathComponent)
        vm.input = "screenshot"
        #expect(vm.catalogMatches.count == 2, "capture commands have no filename words; both files match")

        // Date words work after the search words too.
        vm.input = "09 today"
        #expect(vm.catalogMatches.map { ($0.value as NSString).lastPathComponent } == [recent.lastPathComponent])
        let after = ScreenshotQuery.parse("acme today")
        #expect(after.needle == "acme" && after.interval != nil)
        #expect(ScreenshotQuery.parse("meeting 7d").needle == "meeting")
        #expect(ScreenshotQuery.parse("meeting 7d").interval != nil)
        let dated = ScreenshotQuery.parse("2026-08-11 report")
        #expect(dated.needle == "report")
        #expect(dated.interval != nil && dated.interval!.duration == 86_400)
        // Conflicting date words degrade to no filter instead of zero rows.
        let conflict = ScreenshotQuery.parse("today yesterday acme")
        #expect(conflict.interval == nil)
        #expect(conflict.needle == "acme")
    }

    @Test func latestScreenshotFinderUnderstandsEveryCatalogPrefix() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-prefixes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let older = folder.appendingPathComponent("Screenshot 2026-08-20 at 10.00.00.png")
        let cleanshot = folder.appendingPathComponent("CleanShot 2026-08-22 at 10.00.00.png")
        try png.write(to: older); try png.write(to: cleanshot)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: older.path)
        #expect(LatestScreenshotFinder.newestScreenshot(in: folder)?.lastPathComponent == cleanshot.lastPathComponent)
        #expect(!LatestScreenshotFinder.namePrefixes.isEmpty)
        for prefix in ["screen shot", "scr-"] {
            #expect(LatestScreenshotFinder.namePrefixes.contains(prefix))
        }
    }

    @Test func searchVariantsFoldPluralsOnlyWhenSafe() {
        #expect(QuickViewModel.searchVariants(for: "Screenshots") == ["screenshots", "screenshot"])
        #expect(QuickViewModel.searchVariants(for: "shots") == ["shots", "shot"])
        #expect(QuickViewModel.searchVariants(for: "lens") == ["lens"])
        #expect(QuickViewModel.searchVariants(for: "glass") == ["glass"])
        #expect(QuickViewModel.searchVariants(for: "this") == ["this"])
        #expect(QuickViewModel.searchVariants(for: "acme invoice") == ["acme invoice"])
    }

    @Test func backgroundScanCountsRealFilesBeforeTheCatalogOpens() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-warmscan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try png.write(to: folder.appendingPathComponent("Screenshot 2026-08-20 at 10.00.00.png"))
        try png.write(to: folder.appendingPathComponent("Screenshot 2026-08-21 at 10.00.00.png"))

        let vm = QuickViewModel()
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = folder
        // Nothing scanned yet: the count would be commands only.
        #expect(vm.catalogCount(.screenshots) == 2)
        vm.refreshScreenshotFilesInBackground()
        await vm.waitForScreenshotScanForTesting()
        #expect(vm.catalogCount(.screenshots) == 4, "two capture commands plus two files")
        #expect(vm.lastScreenshotScanAt != nil)
        // Entering straight after a warm scan trusts it; files are already there.
        vm.enterCatalog(.screenshots)
        #expect(vm.catalogItems.filter { $0.kind == .screenshot }.count == 2)
    }
}

@MainActor
private final class UntilRecordingManager: CaffeinateManaging {
    private(set) var isEnabled = false
    private(set) var until: Date?
    var endsAt: Date? { until }
    func setEnabled(_ enabled: Bool) -> Bool { isEnabled = enabled; return true }
    func enable(until date: Date) -> Bool { isEnabled = true; until = date; return true }
}

private final class ConvertRecordingCatalog: LauncherCatalogServicing {
    var snippets: [LauncherCatalogItem] = []
    var quickLinks: [LauncherCatalogItem] = []
    func reload() {}
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteSnippet(_ item: LauncherCatalogItem) throws {}
    func createSnippet(title: String, value: String) throws -> LauncherCatalogItem {
        let item = LauncherCatalogItem(kind: .snippet, itemID: "s\(snippets.count)", title: title, detail: "Snippet", value: value)
        snippets.append(item); return item
    }
    func createQuickLink(title: String, value: String) throws -> LauncherCatalogItem {
        let item = LauncherCatalogItem(kind: .quickLink, itemID: "l\(quickLinks.count)", title: title, detail: value, value: value)
        quickLinks.append(item); return item
    }
}

private final class PopFakeScreenshotService: ScreenshotCapturing {
    var isScreenRecordingAuthorized = true
    func capture(_ kind: ScreenshotKind, target: SelectionTarget?, ownProcess: pid_t) async throws -> QuickImageAttachment {
        QuickImageAttachment(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1)
    }
}
