import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Folders, answers, typed URLs, and utility commands", .serialized)
@MainActor
struct FoldersAndCommandsTests {
    private static let apps = [
        LaunchableApplication(name: "Safari", bundleIdentifier: "com.apple.Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")),
        LaunchableApplication(name: "Downie", bundleIdentifier: "com.example.downie", url: URL(fileURLWithPath: "/Applications/Downie.app")),
    ]

    private func make(settings: QuickSettings = QuickSettings()) -> QuickViewModel {
        QuickViewModel(settings: settings, applicationCatalog: CommandsFakeCatalog(applications: Self.apps))
    }

    @Test func builtInFoldersAreItemsWithDefaultAliases() {
        let vm = make()
        let titles = vm.folderItems.map(\.title)
        #expect(titles.contains("Downloads"))
        #expect(titles.contains("Desktop"))
        #expect(vm.catalogCount(.folders) == vm.folderItems.count)
        let downloads = vm.folderItems.first { $0.itemID == "downloads" }!
        #expect(vm.launcherItemAlias(for: downloads) == "dl")
        #expect(downloads.detail.hasPrefix("~/"))
    }

    @Test func dlAliasRanksDownloadsFirstOverAnAppThatStartsWithTheSameLetters() {
        let vm = make()
        vm.input = "dl"
        #expect(vm.launcherMatches.first?.id == "folder:downloads")
        vm.input = "dk"
        #expect(vm.launcherMatches.first?.id == "folder:desktop")
        #expect(vm.footerHints.first?.label == "Open")
    }

    @Test func customFoldersAreAddedRemovedAndPersisted() {
        var saved: QuickSettings?
        let vm = make()
        vm.persistSettings = { saved = $0 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-custom-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        vm.addCustomFolder(folder)
        vm.addCustomFolder(folder)
        #expect(vm.settings.customFolders.count == 1)
        #expect(saved?.customFolders.count == 1)
        let item = vm.folderItems.first { $0.title == folder.lastPathComponent }
        #expect(item != nil)
        let actions = ItemActionCatalog.actions(for: .item(item!), pasteTarget: nil).map(\.kind)
        #expect(actions.contains(.delete))
        #expect(!ItemActionCatalog.actions(for: .item(vm.folderItems.first { $0.itemID == "downloads" }!), pasteTarget: nil).map(\.kind).contains(.delete))
        vm.removeCustomFolder(item!)
        #expect(vm.settings.customFolders.isEmpty)
    }

    @Test func folderHotkeyResolvesThroughCatalogItem() {
        let vm = make()
        #expect(vm.catalogItem(kind: .folder, itemID: "desktop")?.title == "Desktop")
    }

    @Test func typedURLBecomesAnOpenRow() {
        let vm = make()
        vm.input = "apple.com/iphone"
        let top = vm.launcherMatches.first
        guard case .item(let item)? = top else { Issue.record("no row"); return }
        #expect(item.kind == .quickLink)
        #expect(item.value == "https://apple.com/iphone")
        #expect(item.title == "Open apple.com")
        let kinds = ItemActionCatalog.actions(for: .item(item), pasteTarget: nil).map(\.kind)
        #expect(!kinds.contains(.setAlias), "a typed address is not configurable")
        vm.input = "hello world"
        #expect(!vm.launcherMatches.contains { if case .item(let i) = $0 { return i.itemID.hasPrefix("typed:") } else { return false } })
    }

    @Test func localAnswersShowAsTheTopRow() {
        let vm = make()
        vm.input = "12 km in miles"
        guard case .item(let conversion)? = vm.launcherMatches.first else { Issue.record("no row"); return }
        #expect(conversion.kind == .answer)
        #expect(conversion.title.hasSuffix("mi"))
        #expect(vm.footerHints.first?.label == "Copy")
        vm.input = "2+2*3"
        guard case .item(let math)? = vm.launcherMatches.first else { Issue.record("no row"); return }
        #expect(math.kind == .answer)
        #expect(math.title == "8")
        vm.input = "safari"
        #expect(!vm.launcherMatches.contains { if case .item(let i) = $0 { return i.kind == .answer } else { return false } })
    }

    @Test func utilityCommandsAreInTheCommandsCatalog() {
        let vm = make()
        let ids = vm.systemCommands.map(\.itemID)
        #expect(ids.contains("toggle.toggleDarkMode"))
        #expect(ids.contains("toggle.lockScreen"))
        #expect(ids.contains("ocr.area"))
        #expect(ids.contains("paste.plain"))
        #expect(ids.contains("clipboard.cleanLink"))
        #expect(!ids.contains("screenHistory.toggleCapture"), "capture control stays hidden until it can run safely")
        #expect(ids.contains { $0.hasPrefix("settingspane.") })
        #expect(Set(ids).count == ids.count, "command ids stay unique")
        vm.input = "dark mode"
        #expect(vm.launcherMatches.first?.id == "command:toggle.toggleDarkMode")
        vm.input = "bluetooth"
        #expect(vm.launcherMatches.first?.id.hasPrefix("command:settingspane.") == true)
    }

    @Test func cleanLinkActionAppearsOnlyForTrackedLinks() {
        let tracked = LauncherCatalogItem(kind: .clipboard, itemID: "a", title: "", detail: "", value: "https://example.com/x?utm_source=news&id=4")
        let plain = LauncherCatalogItem(kind: .clipboard, itemID: "b", title: "", detail: "", value: "https://example.com/x?id=4")
        #expect(ItemActionCatalog.actions(for: .item(tracked), pasteTarget: nil).map(\.kind).contains(.copyCleanLink))
        #expect(!ItemActionCatalog.actions(for: .item(plain), pasteTarget: nil).map(\.kind).contains(.copyCleanLink))
    }

    @Test func runningAppsGetQuitHideRelaunchActions() {
        let app = LauncherSearchResult.application(Self.apps[0])
        let idle = ItemActionCatalog.actions(for: app, pasteTarget: nil, isRunning: false).map(\.kind)
        let running = ItemActionCatalog.actions(for: app, pasteTarget: nil, isRunning: true).map(\.kind)
        #expect(!idle.contains(.quit))
        #expect(running.contains(.quit) && running.contains(.forceQuit) && running.contains(.hide) && running.contains(.relaunch))
        #expect(ItemActionCatalog.actions(for: app, pasteTarget: nil, isRunning: true).first?.title == "Switch To")
    }

    @Test func settingsMigrationAddsTheFolderAliasesOnce() throws {
        var old = QuickSettings()
        old.configurationVersion = 14
        old.launcherItemConfigurations = QuickSettings.defaultWindowConfigurations
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(QuickSettings.self, from: data)
        #expect(decoded.launcherItemConfigurations.contains { $0.kind == .folder && $0.alias == "dl" })
        #expect(decoded.configurationVersion == 26)
        let again = try JSONDecoder().decode(QuickSettings.self, from: JSONEncoder().encode(decoded))
        #expect(again.launcherItemConfigurations.filter { $0.kind == .folder }.count == 2)
    }
}

private final class CommandsFakeCatalog: ApplicationCatalogServicing {
    let applications: [LaunchableApplication]
    var launched: LaunchableApplication?
    init(applications: [LaunchableApplication]) { self.applications = applications }
    func launch(_ application: LaunchableApplication) -> Bool { launched = application; return true }
}
