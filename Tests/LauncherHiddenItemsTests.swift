// LauncherHiddenItemsTests — launcher learning regression and reversible
// hidden results. The learning tests reproduce the real sequence (type
// "voice", select Voice Memos, the same query leads with it next time and
// after a reload from disk, with a deliberate stronger fuzzy competitor in
// the list). The hidden tests cover the row action, filtering before
// ranking/caps/favourites in root and scoped search, backward-compatible
// persistence, restore (including missing records), and render proofs of
// Settings › Items › Hidden in both appearances.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Launcher hidden items", .serialized)
@MainActor
struct LauncherHiddenItemsTests {
    // Real identity, so the ranking path is exercised exactly as production.
    private static let voiceMemos = LaunchableApplication(
        name: "Voice Memos",
        bundleIdentifier: "com.apple.VoiceMemos",
        url: URL(fileURLWithPath: "/System/Applications/VoiceMemos.app")
    )
    /// An exact-name match that must lose to a learned "voice" mnemonic, so
    /// the test fails if the learned boost or its cache invalidation is lost.
    private static let exactVoice = LaunchableApplication(
        name: "Voice",
        bundleIdentifier: "com.example.voice",
        url: URL(fileURLWithPath: "/Applications/Voice.app")
    )
    private static let voiceRecorder = LaunchableApplication(
        name: "Voice Recorder",
        bundleIdentifier: "com.example.voicerecorder",
        url: URL(fileURLWithPath: "/Applications/Voice Recorder.app")
    )

    private static func temporaryUsageFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-hidden-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("launcher-usage.json")
    }

    private func makeApplicationViewModel(
        usage: LauncherUsageStore,
        applications: [LaunchableApplication] = [
            LauncherHiddenItemsTests.voiceMemos,
            LauncherHiddenItemsTests.exactVoice,
            LauncherHiddenItemsTests.voiceRecorder,
        ],
        snippets: [LauncherCatalogItem] = [
            LauncherCatalogItem(kind: .snippet, itemID: "voice.note", title: "Voice Notes", detail: "", value: "note"),
        ]
    ) -> (QuickViewModel, HiddenFakeApplicationCatalog, HiddenFakeLauncherCatalog) {
        let appCatalog = HiddenFakeApplicationCatalog(applications: applications)
        let launcherCatalog = HiddenFakeLauncherCatalog()
        launcherCatalog.snippets = snippets
        let vm = QuickViewModel(
            applicationCatalog: appCatalog,
            launcherCatalog: launcherCatalog,
            launcherUsage: usage
        )
        return (vm, appCatalog, launcherCatalog)
    }

    // MARK: - Learning regression (the reported Voice Memos case)

    @Test func choosingVoiceMemosForVoiceMakesItFirstNextTimeAndAfterReload() async throws {
        let file = try Self.temporaryUsageFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = LauncherUsageStore(fileURL: file)
        let (vm, appCatalog, _) = makeApplicationViewModel(usage: store)
        let result = LauncherSearchResult.application(Self.voiceMemos)

        vm.input = "voice"
        // Before learning the exact-name competitor leads, so the assertion
        // below proves the mnemonic boost, not alphabetical luck.
        #expect(vm.launcherMatches.first == .application(Self.exactVoice))

        // Choose Voice Memos the way the primary (Return) path does.
        await vm.performLauncherResult(result)
        #expect(appCatalog.launched.last == Self.voiceMemos)
        #expect(store.mnemonicWeight(query: "voice", scope: LauncherUsageStore.rootScope, itemID: result.id) > 0.9)

        // Same view model, same query: the ranked list must not be stale.
        vm.input = "voice"
        #expect(vm.launcherMatches.first == .application(Self.voiceMemos))
        #expect(vm.applicationMatches.first == Self.voiceMemos)

        // After a reload from disk the learned mnemonic still leads.
        store.waitForPendingWrites()
        let reloaded = LauncherUsageStore(fileURL: file)
        #expect(reloaded.mnemonicWeight(query: "voice", scope: LauncherUsageStore.rootScope, itemID: result.id) > 0.9)
        let (vm2, _, _) = makeApplicationViewModel(usage: reloaded)
        vm2.input = "voice"
        #expect(vm2.launcherMatches.first == .application(Self.voiceMemos))
    }

    @Test func keyboardAndMouseSelectionPathsAlsoLearn() async throws {
        // Keyboard: highlight the row, then perform it as Return does.
        let keyboardStore = LauncherUsageStore(fileURL: nil)
        let (keyboardVM, keyboardCatalog, _) = makeApplicationViewModel(usage: keyboardStore)
        keyboardVM.input = "voice"
        let keyboardResult = LauncherSearchResult.application(Self.voiceMemos)
        keyboardVM.applicationSelectionIndex = keyboardVM.launcherMatches.firstIndex(of: keyboardResult) ?? 0
        #expect(keyboardVM.launcherMatches[keyboardVM.applicationSelectionIndex] == keyboardResult)
        await keyboardVM.performLauncherResult(keyboardResult)
        #expect(keyboardCatalog.launched.last == Self.voiceMemos)
        #expect(keyboardStore.mnemonicWeight(query: "voice", scope: LauncherUsageStore.rootScope, itemID: keyboardResult.id) > 0.9)

        // Mouse: the list's `onActivate` calls exactly this.
        let mouseStore = LauncherUsageStore(fileURL: nil)
        let (mouseVM, mouseCatalog, _) = makeApplicationViewModel(usage: mouseStore)
        mouseVM.input = "voice"
        await mouseVM.performLauncherResult(LauncherSearchResult.application(Self.voiceMemos))
        #expect(mouseCatalog.launched.last == Self.voiceMemos)
        #expect(mouseStore.mnemonicWeight(
            query: "voice",
            scope: LauncherUsageStore.rootScope,
            itemID: LauncherSearchResult.application(Self.voiceMemos).id
        ) > 0.9)
    }

    @Test func highlightingAndCancellingDoNotLearn() {
        let store = LauncherUsageStore(fileURL: nil)
        let (vm, _, _) = makeApplicationViewModel(usage: store)
        vm.input = "voice"
        _ = vm.launcherMatches
        // Arrow keys move the highlight; that is not a choice.
        vm.moveApplicationSelection(1)
        vm.moveApplicationSelection(1)
        #expect(store.isEmpty)
        // Escape dismisses or clears; still not a choice.
        _ = vm.handleEscapeKey()
        #expect(store.isEmpty)
    }

    @Test func aFailedLaunchDoesNotLearn() async {
        let store = LauncherUsageStore(fileURL: nil)
        let (vm, catalog, _) = makeApplicationViewModel(usage: store)
        catalog.launchSucceeds = false
        vm.input = "voice"
        await vm.performLauncherResult(.application(Self.voiceMemos))
        #expect(catalog.launched.last == Self.voiceMemos)
        #expect(store.isEmpty)
        #expect(vm.errorMessage != nil)
        vm.input = "voice"
        #expect(vm.launcherMatches.first != .application(Self.voiceMemos))
    }

    // MARK: - Hide action

    @Test func runningApplicationOffersHideWindowsWhileRowsOfferHideFromQuickLaunch() {
        let running = ItemActionCatalog.actions(
            for: .application(Self.exactVoice),
            pasteTarget: nil,
            isRunning: true
        )
        #expect(running.contains { $0.kind == .hide && $0.title == "Hide Windows" })
        #expect(!running.contains { $0.title == "Hide" })
        let idle = ItemActionCatalog.actions(
            for: .application(Self.exactVoice),
            pasteTarget: nil,
            isRunning: false
        )
        #expect(!idle.contains { $0.kind == .hide })

        let catalog = HiddenFakeLauncherCatalog()
        let vm = QuickViewModel(launcherCatalog: catalog, launcherUsage: LauncherUsageStore(fileURL: nil))
        vm.input = "greeting"
        let snippet = catalog.snippets[0]
        vm.applicationSelectionIndex = vm.launcherMatches.firstIndex(of: .item(snippet)) ?? 0
        #expect(vm.focusedItemActions.contains { $0.kind == .hideFromLauncher && $0.title == "Hide from Quick Launch" })
    }

    @Test func hideableKindsExcludeComputedRows() {
        let snippet = LauncherCatalogItem(kind: .snippet, itemID: "s", title: "S", detail: "", value: "v")
        let command = LauncherCatalogItem(kind: .command, itemID: "c", title: "C", detail: "", value: "window.leftHalf")
        let clipboard = LauncherCatalogItem(kind: .clipboard, itemID: "h", title: "T", detail: "", value: "T")
        let chat = LauncherCatalogItem(kind: .conversation, itemID: UUID().uuidString, title: "Chat", detail: "", value: "")
        let typedLink = LauncherCatalogItem(kind: .quickLink, itemID: "typed:abc", title: "Open x", detail: "", value: "https://x")
        #expect(snippet.canBeHidden && command.canBeHidden && clipboard.canBeHidden && chat.canBeHidden)
        #expect(!typedLink.canBeHidden)
        #expect(!LauncherCatalogItem(kind: .answer, itemID: "answer", title: "2", detail: "1+1", value: "2").canBeHidden)
        #expect(!LauncherCatalogItem(kind: .askAI, itemID: "askAI", title: "Ask AI", detail: "", value: "").canBeHidden)
        #expect(!LauncherCatalogItem(kind: .screenHistory, itemID: "m", title: "Moment", detail: "", value: "").canBeHidden)
    }

    @Test func hideFromQuickLaunchRemovesTheRowAndKeepsAliasHotkeyAndSource() async {
        let catalog = HiddenFakeLauncherCatalog()
        let vm = QuickViewModel(launcherCatalog: catalog, launcherUsage: LauncherUsageStore(fileURL: nil))
        let snippet = catalog.snippets[0]
        vm.setLauncherItemAlias("sig", for: snippet)
        vm.setLauncherItemHotkey(ActionHotkey(keyCode: 1, modifiers: 1_048_576 | 524_288), for: snippet)

        vm.input = "greeting"
        let result = LauncherSearchResult.item(snippet)
        vm.applicationSelectionIndex = vm.launcherMatches.firstIndex(of: result) ?? 0
        let hide = vm.focusedItemActions.first { $0.kind == .hideFromLauncher }
        #expect(hide != nil)
        if let hide { await vm.perform(hide, on: result) }

        let configuration = vm.settings.launcherItemConfiguration(kind: .snippet, itemID: snippet.itemID)
        #expect(configuration?.isHidden == true)
        #expect(configuration?.alias == "sig")
        #expect(configuration?.hotkey != nil)
        // Hiding is not deleting: the source item is untouched.
        #expect(catalog.snippets.contains { $0.id == snippet.id })
        // The row and its alias no longer surface in root search.
        #expect(!vm.launcherMatches.contains(result))
        vm.input = "sig"
        #expect(!vm.launcherMatches.contains(result))

        // Scoped catalog search hides it too, and Restore brings it back.
        vm.enterCatalog(.snippets)
        vm.input = "greeting"
        #expect(!vm.catalogMatches.contains { $0.id == snippet.id })
        if let configuration { vm.restoreHiddenItem(configuration) }
        #expect(!vm.isLauncherItemHidden(snippet))
        #expect(vm.catalogMatches.contains { $0.id == snippet.id })
    }

    @Test func hiddenApplicationStaysHiddenThroughAliasPinAndName() async {
        var settings = QuickSettings()
        var configuration = LauncherItemConfiguration(kind: .application, itemID: Self.voiceMemos.id)
        configuration.alias = "vm"
        configuration.isPinned = true
        settings.launcherItemConfigurations.append(configuration)
        let catalog = HiddenFakeApplicationCatalog(applications: [Self.voiceMemos])
        let vm = QuickViewModel(settings: settings, applicationCatalog: catalog)

        vm.hideApplication(Self.voiceMemos)
        #expect(vm.isApplicationHidden(Self.voiceMemos))

        vm.input = "vm"
        #expect(vm.applicationMatches.isEmpty)
        #expect(!vm.launcherMatches.contains(.application(Self.voiceMemos)))
        vm.input = "voice memos"
        #expect(!vm.launcherMatches.contains(.application(Self.voiceMemos)))
        vm.input = ""
        #expect(!vm.launcherMatches.contains(.application(Self.voiceMemos)))

        let stored = vm.settings.launcherItemConfiguration(kind: .application, itemID: Self.voiceMemos.id)
        #expect(stored?.isHidden == true)
        #expect(stored?.alias == "vm")
        #expect(stored?.isPinned == true)
        // A direct hotkey resolves through the raw catalog, not the filtered list.
        #expect(catalog.applications.contains(Self.voiceMemos))
    }

    @Test func hiddenClipboardEntryIsFilteredAndKeepsNoBodyInMetadata() {
        let entry = LauncherCatalogItem(
            kind: .clipboard,
            itemID: "hash-1",
            title: "My private note text",
            detail: "Text",
            value: "My private note text"
        )
        let clipboard = HiddenFakeClipboard(entries: [entry])
        let vm = QuickViewModel(clipboardHistory: clipboard)
        vm.enterCatalog(.clipboard)
        #expect(vm.catalogMatches.contains { $0.id == entry.id })

        #expect(vm.hideLauncherItem(entry))
        #expect(vm.catalogMatches.isEmpty)
        let configuration = vm.settings.launcherItemConfiguration(kind: .clipboard, itemID: entry.itemID)
        #expect(configuration?.isHidden == true)
        // No clipboard body is copied into the hidden record.
        #expect(configuration?.hiddenTitle == nil)
        // The clipboard entry itself is untouched.
        #expect(clipboard.entries.contains { $0.id == entry.id })
    }

    @Test func hiddenChatLeavesEveryChatListWithoutStoringItsText() {
        let vm = QuickViewModel()
        let conversation = QuickConversation(
            providerID: UUID(),
            model: "m",
            messages: [QuickMessage(role: .user, content: "my private question")]
        )
        vm.history = [conversation]
        vm.enterCatalog(.chats)
        let chat = vm.conversationItem(conversation)
        #expect(vm.catalogMatches.contains { $0.id == chat.id })

        #expect(vm.hideLauncherItem(chat))
        #expect(vm.catalogMatches.isEmpty)
        #expect(vm.chatItems(matching: "").isEmpty)
        #expect(vm.catalogCount(.chats) == 0)
        let configuration = vm.settings.launcherItemConfiguration(
            kind: .conversation,
            itemID: conversation.id.uuidString
        )
        #expect(configuration?.isHidden == true)
        #expect(configuration?.hiddenTitle == nil)
    }

    @Test func hiddenStateIsBackwardCompatibleAndRestoresIncludingMissingRecords() throws {
        let old = try JSONDecoder().decode(
            LauncherItemConfiguration.self,
            from: Data(#"{"kind":"snippet","itemID":"x","alias":"sig"}"#.utf8)
        )
        #expect(!old.isHidden && old.hiddenTitle == nil)

        var hidden = LauncherItemConfiguration(kind: .snippet, itemID: "y")
        hidden.isHidden = true
        hidden.hiddenTitle = "Saved"
        #expect(!hidden.isEmpty)
        let back = try JSONDecoder().decode(LauncherItemConfiguration.self, from: JSONEncoder().encode(hidden))
        #expect(back == hidden)

        var onlyHidden = LauncherItemConfiguration(kind: .command, itemID: "c")
        onlyHidden.isHidden = true
        #expect(!onlyHidden.isEmpty)
        onlyHidden.isHidden = false
        #expect(onlyHidden.isEmpty)

        // Restore All covers a record whose app is gone and drops it cleanly.
        var settings = QuickSettings()
        var gone = LauncherItemConfiguration(kind: .application, itemID: "com.example.gone")
        gone.isHidden = true
        gone.hiddenTitle = "Old Editor"
        var hiddenSnippet = LauncherItemConfiguration(kind: .snippet, itemID: "promo")
        hiddenSnippet.isHidden = true
        hiddenSnippet.hiddenTitle = "Welcome"
        settings.launcherItemConfigurations.append(contentsOf: [gone, hiddenSnippet])
        let vm = QuickViewModel(settings: settings)
        #expect(vm.hiddenLauncherItems.count == 2)
        vm.restoreAllHiddenItems()
        #expect(vm.hiddenLauncherItems.isEmpty)
        #expect(vm.settings.launcherItemConfiguration(kind: .application, itemID: "com.example.gone") == nil)
        #expect(vm.settings.launcherItemConfiguration(kind: .snippet, itemID: "promo") == nil)
    }

    @Test func hiddenRecordReportsWhetherItsSourceStillExists() {
        var settings = QuickSettings()
        var live = LauncherItemConfiguration(kind: .snippet, itemID: "promo")
        live.isHidden = true
        live.hiddenTitle = "Welcome"
        var gone = LauncherItemConfiguration(kind: .application, itemID: "com.example.gone")
        gone.isHidden = true
        gone.hiddenTitle = "Old Editor"
        settings.launcherItemConfigurations.append(contentsOf: [live, gone])
        let catalog = HiddenFakeLauncherCatalog()
        catalog.snippets = [LauncherCatalogItem(kind: .snippet, itemID: "promo", title: "Welcome", detail: "", value: "x")]
        let vm = QuickViewModel(settings: settings, launcherCatalog: catalog)
        #expect(vm.hiddenLauncherItemExists(live))
        #expect(!vm.hiddenLauncherItemExists(gone))
    }

    // MARK: - Render proofs (offscreen, both appearances, no focus)

    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
    private static let appearances: [(NSAppearance.Name, AppearancePreference, String)] = [
        (.darkAqua, .dark, "dark"),
        (.aqua, .light, "light"),
    ]
    private static let paneWidth = SettingsView.windowSize.width - House.Layout.settingsRail - House.hairline

    private static func makeHiddenViewModel(_ appearance: AppearancePreference) -> QuickViewModel {
        var settings = QuickSettings()
        settings.appearance = appearance

        var snippet = LauncherItemConfiguration(kind: .snippet, itemID: "promo")
        snippet.isHidden = true
        snippet.hiddenTitle = "Welcome blurb"

        var window = LauncherItemConfiguration(kind: .command, itemID: "window.leftHalf")
        window.isHidden = true
        window.hiddenTitle = "Left Half"

        // A clipboard row keeps no body, so the label is the neutral one.
        var clipboard = LauncherItemConfiguration(kind: .clipboard, itemID: "hash-1")
        clipboard.isHidden = true

        // An uninstalled app whose record survives on the stored label.
        var missingApp = LauncherItemConfiguration(kind: .application, itemID: "com.example.gone")
        missingApp.isHidden = true
        missingApp.hiddenTitle = "Old Editor"

        var chat = LauncherItemConfiguration(kind: .conversation, itemID: UUID().uuidString)
        chat.isHidden = true

        settings.launcherItemConfigurations.append(contentsOf: [
            snippet, window, clipboard, missingApp, chat,
        ])
        let catalog = HiddenFakeLauncherCatalog()
        catalog.snippets = [LauncherCatalogItem(
            kind: .snippet, itemID: "promo", title: "Welcome blurb", detail: "", value: "hi"
        )]
        let clipboardStore = HiddenFakeClipboard(entries: [LauncherCatalogItem(
            kind: .clipboard, itemID: "hash-1", title: "Clip", detail: "", value: "x"
        )])
        return QuickViewModel(
            settings: settings,
            launcherCatalog: catalog,
            clipboardHistory: clipboardStore
        )
    }

    @Test func rendersHiddenItemsInBothAppearances() throws {
        for (appearance, preference, suffix) in Self.appearances {
            let vm = Self.makeHiddenViewModel(preference)
            // The uninstalled app and the missing chat read as unavailable;
            // the live snippet, command, and clipboard entry do not.
            let pane = ItemsSettingsView(viewModel: vm, initialFilter: .hidden)
                .frame(width: Self.paneWidth, height: 430, alignment: .top)
                .background(AQDesign.ColorToken.windowSurface)
                .preferredColorScheme(preference == .dark ? .dark : .light)
            try Self.save(
                try Self.renderFitting(pane, appearance: appearance),
                name: "launcher-hidden-items-\(suffix).png"
            )
        }
    }

    private static func renderFitting<V: View>(_ view: V, appearance: NSAppearance.Name) throws -> NSImage {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProofError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func save(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ProofError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    enum ProofError: Error { case noBitmap }
}

@MainActor
private final class HiddenFakeApplicationCatalog: ApplicationCatalogServicing {
    let applications: [LaunchableApplication]
    var launchSucceeds = true
    var launched: [LaunchableApplication] = []

    init(applications: [LaunchableApplication]) {
        self.applications = applications
    }

    func launch(_ application: LaunchableApplication) -> Bool {
        launched.append(application)
        return launchSucceeds
    }
}

@MainActor
private final class HiddenFakeLauncherCatalog: LauncherCatalogServicing {
    var snippets = [LauncherCatalogItem(
        kind: .snippet, itemID: "one", title: "Greeting", detail: "Test", value: "Hello"
    )]
    var quickLinks = [LauncherCatalogItem(
        kind: .quickLink, itemID: "two", title: "Site", detail: "example.com",
        value: "https://example.com"
    )]
    func reload() {}
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteSnippet(_ item: LauncherCatalogItem) throws {
        snippets.removeAll { $0.id == item.id }
    }
}

@MainActor
private final class HiddenFakeClipboard: ClipboardHistoryServicing {
    var entries: [LauncherCatalogItem]
    var removed: [LauncherCatalogItem] = []

    init(entries: [LauncherCatalogItem]) {
        self.entries = entries
    }

    func startMonitoring(limit: Int) {}
    func stopMonitoring() {}
    func record(_ text: String, limit: Int) {}
    func remove(_ item: LauncherCatalogItem) {
        removed.append(item)
        entries.removeAll { $0.id == item.id }
    }
    func clear() { entries = [] }
    func payload(for item: LauncherCatalogItem) async -> ClipboardPayload? { nil }
}
