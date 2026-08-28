import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Item actions", .serialized)
@MainActor
struct ItemActionTests {
    private static let safari = LaunchableApplication(
        name: "Safari",
        bundleIdentifier: "com.apple.Safari",
        url: URL(fileURLWithPath: "/Applications/Safari.app")
    )

    @Test func snippetActionsFollowRaycastConventions() {
        let snippet = LauncherCatalogItem(kind: .snippet, itemID: "a", title: "Sig", detail: "", value: "x")
        let actions = ItemActionCatalog.actions(for: .item(snippet), pasteTarget: "Mail")
        #expect(actions.map(\.title) == [
            "Paste to Mail", "Copy to Clipboard", "Copy & Paste", "Edit Snippet", "Pin to Top",
            "Set Alias…", "Set Hotkey…", "Delete Snippet",
        ])
        #expect(actions[0].shortcut?.keyCaps == ["↩"])
        #expect(actions[1].shortcut?.keyCaps == ["⌘", "↩"])
        #expect(actions[2].shortcut?.keyCaps == ["⇧", "⌘", "↩"])
        #expect(actions[3].shortcut?.keyCaps == ["⌘", "E"])
        #expect(actions[4].shortcut?.keyCaps == ["⇧", "⌘", "P"])
        #expect(actions[7].shortcut?.keyCaps == ["⌃", "X"])
        #expect(actions[7].isDestructive)
    }

    @Test func otherKindsHaveTheRightPrimaryAndSecondaryActions() {
        let clip = LauncherCatalogItem(kind: .clipboard, itemID: "c", title: "t", detail: "", value: "v")
        #expect(ItemActionCatalog.actions(for: .item(clip), pasteTarget: nil).map(\.title)
            == ["Paste to Active App", "Copy to Clipboard", "Copy & Paste", "Pin to Top", "Save as Snippet", "Delete Entry"])
        let pinnedLink = LauncherCatalogItem(kind: .clipboard, itemID: "u", title: "t", detail: "", value: "https://example.com/x", isPinned: true)
        #expect(ItemActionCatalog.actions(for: .item(pinnedLink), pasteTarget: nil).map(\.title)
            == ["Paste to Active App", "Copy to Clipboard", "Copy & Paste", "Unpin", "Save as Snippet", "Create Quicklink", "Delete Entry"])
        let link = LauncherCatalogItem(kind: .quickLink, itemID: "l", title: "Docs", detail: "", value: "https://x", requiresInput: true)
        #expect(ItemActionCatalog.actions(for: .item(link), pasteTarget: nil).first?.title == "Enter Input")
        let command = LauncherCatalogItem(kind: .command, itemID: "w", title: "Left Half", detail: "", value: "window.leftHalf")
        #expect(ItemActionCatalog.actions(for: .item(command), pasteTarget: nil).map(\.title) == ["Run", "Set Alias…", "Set Hotkey…"])
        #expect(ItemActionCatalog.actions(for: .application(Self.safari), pasteTarget: nil).map(\.title)
            == ["Open", "Show in Finder", "Copy Path", "Set Alias…", "Set Hotkey…"])
        #expect(ItemActionCatalog.actions(for: .catalog(.snippets, count: 1), pasteTarget: nil).map(\.title) == ["Browse"])
    }

    @Test func shortcutsMatchKeyEventsPrecisely() {
        #expect(KeyShortcut.commandReturn.matches(characters: "\r", keyCode: 36, modifiers: [.command]))
        #expect(!KeyShortcut.commandReturn.matches(characters: "\r", keyCode: 36, modifiers: []))
        #expect(KeyShortcut.control("x").matches(characters: "x", keyCode: 7, modifiers: [.control]))
        #expect(!KeyShortcut.control("x").matches(characters: "x", keyCode: 7, modifiers: [.command]))
        #expect(KeyShortcut.commandShift("a").matches(characters: "a", keyCode: 0, modifiers: [.command, .shift, .function]))
        #expect(KeyShortcut.commandShift("a").keyCaps == ["⇧", "⌘", "A"])
    }

    private func makeSnippetViewModel() -> (QuickViewModel, ActionFakeCatalog) {
        let catalog = ActionFakeCatalog()
        let vm = QuickViewModel(launcherCatalog: catalog)
        vm.enterCatalog(.snippets)
        vm.input = "greet"
        return (vm, catalog)
    }

    @Test func commandKOpensAnActionListAndTogglesClosed() {
        let (vm, _) = makeSnippetViewModel()
        #expect(vm.focusedItemActions.first?.title == "Paste to Active App")
        vm.handleCommandK()
        #expect(vm.isItemActionPanePresented)
        #expect(vm.activeItemActionForm == nil)
        #expect(vm.focusedItemActions.count == 8)
        vm.handleCommandK()
        #expect(!vm.isItemActionPanePresented)
    }

    @Test func escapeClosesCommandKLayersBeforeAnythingBehindThem() {
        let (vm, _) = makeSnippetViewModel()
        vm.handleCommandK()
        #expect(vm.isItemActionPanePresented)
        #expect(vm.handleEscapeKey())
        #expect(!vm.isItemActionPanePresented)

        vm.isActionPalettePresented = true
        #expect(vm.handleEscapeKey())
        #expect(!vm.isActionPalettePresented)
    }

    @Test func typeToClickCommandUsesTheCanonicalEditableHotkey() throws {
        let vm = QuickViewModel()
        let item = try #require(vm.systemCommands.first {
            $0.itemID == "type-to-click.mode"
        })
        #expect(vm.launcherItemHotkey(for: item) == vm.settings.typeToClickHotkey)

        vm.settings.launcherItemConfigurations.append(LauncherItemConfiguration(
            kind: .command,
            itemID: "type-to-click.mode",
            alias: "click",
            hotkey: ActionHotkey(keyCode: 1, modifiers: 524_288)
        ))
        let custom = ActionHotkey(keyCode: 0, modifiers: 1_048_576)
        vm.setLauncherItemHotkey(custom, for: item)
        #expect(vm.settings.typeToClickHotkey == custom)
        #expect(vm.launcherItemHotkey(for: item) == custom)
        let preserved = vm.settings.launcherItemConfigurations.first {
            $0.itemID == "type-to-click.mode"
        }
        #expect(preserved?.alias == "click")
        #expect(preserved?.hotkey == nil)

        vm.setLauncherItemHotkey(nil, for: item)
        #expect(!vm.settings.typeToClickHotkeyEnabled)
        #expect(vm.launcherItemHotkey(for: item) == nil)

        vm.settings.launcherItemConfigurations.append(LauncherItemConfiguration(
            kind: .application,
            itemID: "com.example.other",
            alias: "CLICK"
        ))
        #expect(vm.launcherItemConfigurationConflict(for: item)?.contains("alias") == true)
    }

    @Test func panelCapturesEscapeBeforeFirstResponderDispatch() throws {
        _ = NSApplication.shared
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var escapes = 0
        panel.escapeHandler = {
            escapes += 1
            return true
        }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))

        panel.sendEvent(event)

        #expect(escapes == 1)
    }

    @Test func commandEOpensTheEditorAndEscapeGoesBackThenCloses() {
        let (vm, _) = makeSnippetViewModel()
        #expect(vm.performShortcut(characters: "e", keyCode: 14, modifiers: [.command]))
        #expect(vm.isItemActionPanePresented)
        #expect(vm.activeItemActionForm == .edit)
        vm.dismissItemActionLayer()
        #expect(vm.isItemActionPanePresented)
        #expect(vm.activeItemActionForm == nil)
        vm.dismissItemActionLayer()
        #expect(!vm.isItemActionPanePresented)
    }

    @Test func controlXAsksOnceThenDeletes() async {
        let (vm, catalog) = makeSnippetViewModel()
        #expect(vm.performShortcut(characters: "x", keyCode: 7, modifiers: [.control]))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(vm.isItemActionPanePresented)
        #expect(vm.focusedItemActions.last?.title == "Confirm Delete")
        #expect(catalog.snippets.count == 1)
        #expect(vm.performShortcut(characters: "x", keyCode: 7, modifiers: [.control]))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(catalog.snippets.isEmpty)
        #expect(!vm.isItemActionPanePresented)
    }

    @Test func commandReturnCopiesAndClosesTheOverlay() async {
        let (vm, _) = makeSnippetViewModel()
        var dismissed = 0
        let token = NotificationCenter.default.addObserver(forName: .dismissOverlay, object: nil, queue: nil) { _ in dismissed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(vm.performShortcut(characters: "\r", keyCode: 36, modifiers: [.command]))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(vm.justCopied)
        #expect(dismissed >= 1)
    }

    @Test func plainReturnAndUnknownKeysAreLeftToTheTextField() {
        let (vm, _) = makeSnippetViewModel()
        #expect(!vm.performShortcut(characters: "\r", keyCode: 36, modifiers: []))
        #expect(!vm.performShortcut(characters: "q", keyCode: 12, modifiers: [.command]))
        vm.input = ""
        vm.leaveCatalog()
        vm.input = "zzzz-nothing"
        #expect(!vm.performShortcut(characters: "e", keyCode: 14, modifiers: [.command]))
    }

    @Test func aliasAndHotkeyFormsOpenFromShortcutsForApps() {
        let vm = QuickViewModel(applicationCatalog: ActionFakeApplicationCatalog())
        vm.input = "saf"
        #expect(vm.performShortcut(characters: "a", keyCode: 0, modifiers: [.command, .shift]))
        #expect(vm.activeItemActionForm == .alias)
        #expect(vm.contextualApplication == Self.safari)
        vm.setApplicationAlias("web", for: Self.safari)
        #expect(vm.applicationAlias(for: Self.safari) == "web")
        #expect(vm.performShortcut(characters: "h", keyCode: 4, modifiers: [.command, .shift]) == false,
                "shortcuts are paused while a form has focus")
        vm.dismissItemActionLayer()
        #expect(vm.performShortcut(characters: "h", keyCode: 4, modifiers: [.command, .shift]))
        #expect(vm.activeItemActionForm == .hotkey)
    }

    @Test func clipboardEntriesCanBeDeletedFromTheirActions() async {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-clip-actions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardHistoryStore(fileURL: folder.appendingPathComponent("clipboard-history.json"))
        store.record("one", limit: 10)
        store.record("two", limit: 10)
        let vm = QuickViewModel(clipboardHistory: store)
        vm.enterCatalog(.clipboard)
        let first = vm.launcherMatches.first!
        await vm.perform(ItemActionCatalog.actions(for: first, pasteTarget: nil).last!, on: first)
        await vm.perform(vm.focusedItemActions.last!, on: first)
        #expect(store.entries.map(\.value) == ["one"])
    }
}

private final class ActionFakeCatalog: LauncherCatalogServicing {
    var snippets = [LauncherCatalogItem(
        kind: .snippet, itemID: "one", title: "Greeting", detail: "Test", value: "Hello"
    )]
    var quickLinks: [LauncherCatalogItem] = []
    func reload() {}
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteSnippet(_ item: LauncherCatalogItem) throws {
        snippets.removeAll { $0.id == item.id }
    }
}

private final class ActionFakeApplicationCatalog: ApplicationCatalogServicing {
    let applications = [
        LaunchableApplication(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            url: URL(fileURLWithPath: "/Applications/Safari.app")
        ),
    ]
    func launch(_ application: LaunchableApplication) -> Bool { true }
}
