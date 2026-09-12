import Foundation
import Testing
@testable import QuickLaunch

/// Creating, editing, and deleting snippets and Quicklinks, and the
/// placeholders they expand on the way out. Every store test runs against a
/// throwaway plist in the temporary directory; nothing here reads or writes
/// the real Tuna store.
@Suite("Snippet and Quicklink authoring", .serialized)
@MainActor
struct SnippetAuthoringTests {
    /// A temporary copy of Tuna's record shape: a root dictionary whose
    /// `CustomItemsCatalogItems` key holds a nested binary plist.
    private struct Fixture {
        let folder: URL
        let preferences: URL
        let config: URL

        @MainActor func service() -> TunaCatalogService {
            TunaCatalogService(preferencesURL: preferences, configURL: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func makeFixture(
        records: [[String: Any]] = [],
        smartLinks: String = ""
    ) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-authoring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preferences = folder.appendingPathComponent("Tuna.plist")
        let config = folder.appendingPathComponent("config.toml")
        let nested = try PropertyListSerialization.data(
            fromPropertyList: records, format: .binary, options: 0
        )
        let root = try PropertyListSerialization.data(
            fromPropertyList: ["CustomItemsCatalogItems": nested], format: .binary, options: 0
        )
        try root.write(to: preferences)
        try smartLinks.write(to: config, atomically: true, encoding: .utf8)
        return Fixture(folder: folder, preferences: preferences, config: config)
    }

    // MARK: - The store

    @Test func aSnippetCanBeCreatedEditedAndDeletedFromNothing() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        #expect(service.snippets.isEmpty)

        let created = try service.createSnippet(title: "Sign-off", value: "Best regards")
        #expect(service.snippets.map(\.title) == ["Sign-off"])
        try service.updateSnippet(created, title: "Sign off", value: "Kind regards")
        #expect(service.snippets.first?.value == "Kind regards")
        try service.deleteSnippet(#require(service.snippets.first))
        #expect(service.snippets.isEmpty)
    }

    @Test func aQuicklinkCanBeCreatedEditedAndDeletedFromNothing() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let service = fixture.service()

        let created = try service.createQuickLink(title: "Docs", value: "https://example.com")
        #expect(service.quickLinks.map(\.title) == ["Docs"])
        try service.updateQuickLink(created, title: "Handbook", value: "https://example.com/handbook")
        #expect(service.quickLinks.first?.title == "Handbook")
        #expect(service.quickLinks.first?.value == "https://example.com/handbook")
        try service.deleteQuickLink(#require(service.quickLinks.first))
        #expect(service.quickLinks.isEmpty)
    }

    @Test func editingOneKindLeavesTheOtherAlone() throws {
        let fixture = try Self.makeFixture(records: [
            ["kind": "text", "id": "one", "label": "Note", "value": "Body"],
            ["kind": "url", "id": "two", "label": "Site", "value": "https://example.com"],
        ])
        defer { fixture.remove() }
        let service = fixture.service()

        try service.deleteQuickLink(#require(service.quickLinks.first))
        #expect(service.quickLinks.isEmpty)
        #expect(service.snippets.map(\.title) == ["Note"])
    }

    @Test func everyWriteLeavesATimestampedBackup() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        _ = try fixture.service().createSnippet(title: "One", value: "x")
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path)
        #expect(files.contains { $0.contains("quick-launch-backup") })
    }

    @Test func theStoreRefusesEmptyAndMalformedItems() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let service = fixture.service()

        #expect(throws: TunaCatalogService.MutationError.invalidSnippet) {
            _ = try service.createSnippet(title: "  ", value: "text")
        }
        #expect(throws: TunaCatalogService.MutationError.invalidSnippet) {
            _ = try service.createSnippet(title: "Name", value: "")
        }
        #expect(throws: TunaCatalogService.MutationError.invalidQuickLink) {
            _ = try service.createQuickLink(title: "Name", value: "not a web address")
        }
        #expect(throws: TunaCatalogService.MutationError.invalidQuickLink) {
            _ = try service.createQuickLink(title: "Name", value: "ftp://example.com")
        }
        #expect(throws: TunaCatalogService.MutationError.invalidQuickLink) {
            _ = try service.createQuickLink(title: " ", value: "https://example.com")
        }
        #expect(service.snippets.isEmpty)
        #expect(service.quickLinks.isEmpty)
    }

    @Test func aSmartLinkIsNeverEditedOrDeleted() throws {
        let fixture = try Self.makeFixture(smartLinks: """
        [[smartLinks.entries]]
        enabled = true
        name = "Search"
        requiresInput = true
        template = "https://example.com/search?q={{input}}"
        """)
        defer { fixture.remove() }
        let service = fixture.service()
        let smart = try #require(service.quickLinks.first { $0.itemID.hasPrefix("tuna-smart-") })

        #expect(!smart.isEditableQuickLink)
        #expect(throws: TunaCatalogService.MutationError.smartLinkIsReadOnly) {
            try service.updateQuickLink(smart, title: "New", value: "https://example.com")
        }
        #expect(throws: TunaCatalogService.MutationError.smartLinkIsReadOnly) {
            try service.deleteQuickLink(smart)
        }
        // The config file itself is never rewritten.
        let config = try String(contentsOf: fixture.config, encoding: .utf8)
        #expect(config.contains("[[smartLinks.entries]]"))
    }

    @Test func aQuicklinkWithAQueryPlaceholderLoadsAndAsksForInput() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let service = fixture.service()
        let created = try service.createQuickLink(
            title: "Search",
            value: "https://example.com/s?q={query}"
        )
        #expect(created.requiresInput)
        #expect(service.quickLinks.first?.requiresInput == true)
    }

    // MARK: - Quicklink query rendering

    @Test func aQueryIsPercentEncodedIntoTheAddress() {
        let rendered = QuickLinkQuery.render(
            "https://example.com/s?q={query}",
            query: "a&b c=d+e#f?g/h",
            clipboard: ""
        )
        #expect(rendered == "https://example.com/s?q=a%26b%20c%3Dd%2Be%23f%3Fg/h")
        #expect(URL(string: rendered) != nil)
    }

    @Test func aLinkWithoutAQueryIsUntouched() {
        #expect(QuickLinkQuery.render("https://example.com/x", query: "ignored", clipboard: "c")
            == "https://example.com/x")
        #expect(!QuickLinkQuery.contains("https://example.com/x"))
    }

    @Test func theSmartLinkSpellingsStillRender() {
        #expect(QuickLinkQuery.render("https://e.com/?q={{input}}", query: "hi there", clipboard: "")
            == "https://e.com/?q=hi%20there")
        #expect(QuickLinkQuery.render("https://e.com/?q={{clipboard}}", query: "", clipboard: "a b")
            == "https://e.com/?q=a%20b")
    }

    // MARK: - Row actions

    @Test func aStoredQuicklinkOffersEditAndDeleteJustLikeASnippet() {
        let stored = LauncherCatalogItem(
            kind: .quickLink, itemID: "tuna-url-abc", title: "Docs",
            detail: "example.com", value: "https://example.com"
        )
        let titles = ItemActionCatalog.actions(for: .item(stored), pasteTarget: nil).map(\.title)
        #expect(titles == [
            "Open Link", "Copy Link", "Edit Quicklink", "Pin to Top",
            "Set Alias…", "Set Hotkey…", "Delete Quicklink",
        ])
    }

    @Test func aSmartLinkKeepsTheReadOnlyActions() {
        let smart = LauncherCatalogItem(
            kind: .quickLink, itemID: "tuna-smart-abc", title: "Search",
            detail: "example.com", value: "https://example.com/?q={{input}}",
            requiresInput: true
        )
        let titles = ItemActionCatalog.actions(for: .item(smart), pasteTarget: nil).map(\.title)
        #expect(!titles.contains("Edit Quicklink"))
        #expect(!titles.contains("Delete Quicklink"))
        #expect(titles.first == "Enter Input")
    }

    // MARK: - The launcher commands

    @Test func theLauncherOffersBothCreateCommands() {
        let vm = QuickViewModel()
        let values = vm.systemCommands.map(\.value)
        #expect(values.contains("snippet.create"))
        #expect(values.contains("quicklink.create"))
    }

    @Test func createSnippetOpensABlankEditor() async throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let vm = QuickViewModel(launcherCatalog: fixture.service(), pasteboard: FakePasteboard())
        let command = try #require(vm.systemCommands.first { $0.value == "snippet.create" })

        await vm.performLauncherItem(command)
        #expect(vm.isCatalogActionPanePresented)
        #expect(vm.activeItemActionForm == .edit)
        let draft = try #require(vm.contextualCatalogItem)
        #expect(vm.isDraftItem(draft))
        #expect(draft.kind == .snippet)
        #expect(draft.title.isEmpty)
        #expect(draft.value.isEmpty)
        #expect(vm.catalogScope == .snippets)
    }

    @Test func createQuicklinkOpensABlankEditorOnTheLinksCatalog() async throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let vm = QuickViewModel(launcherCatalog: fixture.service(), pasteboard: FakePasteboard())
        let command = try #require(vm.systemCommands.first { $0.value == "quicklink.create" })

        await vm.performLauncherItem(command)
        let draft = try #require(vm.contextualCatalogItem)
        #expect(draft.kind == .quickLink)
        #expect(vm.catalogScope == .quickLinks)
    }

    /// Beside a stored row the catalog shows its preview column, and the
    /// editor takes that column rather than hanging across the list.
    @Test func theEditorTakesTheDetailColumnWhenThereIsOne() throws {
        let fixture = try Self.makeFixture(records: [
            ["kind": "text", "id": "one", "label": "Note", "value": "Body"],
        ])
        defer { fixture.remove() }
        let vm = QuickViewModel(launcherCatalog: fixture.service(), pasteboard: FakePasteboard())

        vm.beginCreatingSnippet()
        #expect(vm.showsDetailPane)
        #expect(vm.currentPanelWidth == PanelSizing.panelWidthWithDetail)
        let pane = PanelSizing.itemActionPaneWidth(
            panelWidth: vm.currentPanelWidth,
            showsDetailPane: vm.showsDetailPane
        )
        #expect(pane < vm.currentPanelWidth - PanelSizing.detailListWidth,
                "the card stays inside the detail column")
    }

    /// An empty catalog has no preview column, so the panel stays narrow and
    /// the editor keeps the floating width every ⌘K pane has.
    @Test func theEditorKeepsThePaletteWidthOnTheOneColumnPanel() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let vm = QuickViewModel(launcherCatalog: fixture.service(), pasteboard: FakePasteboard())

        vm.beginCreatingSnippet()
        #expect(!vm.showsDetailPane)
        #expect(vm.currentPanelWidth == PanelSizing.panelWidth)
        #expect(PanelSizing.itemActionPaneWidth(
            panelWidth: vm.currentPanelWidth,
            showsDetailPane: vm.showsDetailPane
        ) == PanelSizing.actionPaletteWidth)
    }

    /// The footer belongs to whatever is on top. While the editor is open
    /// that is the editor, not the row it was opened from.
    @Test func theFooterNamesTheEditorsOwnKeysWhileItIsOpen() throws {
        let fixture = try Self.makeFixture(records: [
            ["kind": "text", "id": "one", "label": "Note", "value": "Body"],
        ])
        defer { fixture.remove() }
        let vm = QuickViewModel(launcherCatalog: fixture.service(), pasteboard: FakePasteboard())

        vm.beginCreatingSnippet()
        #expect(vm.footerHints == [
            QuickViewModel.FooterHint(label: "Save", keys: ["⌘", "↩"]),
            QuickViewModel.FooterHint(label: "Cancel", keys: ["esc"]),
        ])

        vm.dismissItemActionLayer()
        #expect(vm.activeItemActionForm == nil)
        let backOnTheRow = vm.footerHints.map(\.label)
        #expect(!backOnTheRow.contains("Save"), "the row's own actions come back")
        #expect(backOnTheRow.contains("Actions"))
        #expect(backOnTheRow.first == "Paste", "Return acts on the row again")

        vm.beginCreatingQuicklink()
        #expect(vm.footerHints.map(\.label) == ["Save", "Cancel"])
    }

    @Test func savingADraftWritesItToTheStore() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let catalog = fixture.service()
        let vm = QuickViewModel(launcherCatalog: catalog, pasteboard: FakePasteboard())

        vm.beginCreatingSnippet()
        let draft = try #require(vm.contextualCatalogItem)
        #expect(vm.commitItemEdit(draft, title: "Sign-off", value: "Kind regards"))
        #expect(catalog.snippets.map(\.title) == ["Sign-off"])
        #expect(vm.draftCatalogItem == nil)
        #expect(vm.activeItemActionForm == nil)
        #expect(vm.errorMessage == nil)

        vm.beginCreatingQuicklink()
        let linkDraft = try #require(vm.contextualCatalogItem)
        #expect(vm.commitItemEdit(linkDraft, title: "Docs", value: "https://example.com"))
        #expect(catalog.quickLinks.map(\.title) == ["Docs"])
    }

    @Test func anInvalidDraftKeepsTheFormOpenAndSaysWhy() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let catalog = fixture.service()
        let vm = QuickViewModel(launcherCatalog: catalog, pasteboard: FakePasteboard())

        vm.beginCreatingSnippet()
        let draft = try #require(vm.contextualCatalogItem)
        #expect(!vm.commitItemEdit(draft, title: "", value: "text"))
        #expect(vm.activeItemActionForm == .edit)
        #expect(vm.errorMessage != nil)
        #expect(catalog.snippets.isEmpty)

        vm.beginCreatingQuicklink()
        let linkDraft = try #require(vm.contextualCatalogItem)
        #expect(!vm.commitItemEdit(linkDraft, title: "Docs", value: "example dot com"))
        #expect(vm.errorMessage != nil)
        #expect(catalog.quickLinks.isEmpty)
    }

    @Test func editingAStoredItemUpdatesItInPlace() throws {
        let fixture = try Self.makeFixture(records: [
            ["kind": "text", "id": "one", "label": "Note", "value": "Body"],
            ["kind": "url", "id": "two", "label": "Site", "value": "https://example.com"],
        ])
        defer { fixture.remove() }
        let catalog = fixture.service()
        let vm = QuickViewModel(launcherCatalog: catalog, pasteboard: FakePasteboard())

        let snippet = try #require(catalog.snippets.first)
        #expect(vm.commitItemEdit(snippet, title: "Note 2", value: "Body 2"))
        #expect(catalog.snippets.first?.title == "Note 2")

        let link = try #require(catalog.quickLinks.first)
        #expect(vm.commitItemEdit(link, title: "Site 2", value: "https://example.com/2"))
        #expect(catalog.quickLinks.first?.value == "https://example.com/2")
    }

    @Test func deletingAQuicklinkGoesThroughTheViewModel() throws {
        let fixture = try Self.makeFixture(records: [
            ["kind": "url", "id": "two", "label": "Site", "value": "https://example.com"],
        ])
        defer { fixture.remove() }
        let catalog = fixture.service()
        let vm = QuickViewModel(launcherCatalog: catalog, pasteboard: FakePasteboard())

        #expect(vm.deleteQuickLink(try #require(catalog.quickLinks.first)))
        #expect(catalog.quickLinks.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    // MARK: - Placeholders on the way out

    private func pinnedViewModel(
        _ catalog: TunaCatalogService,
        clipboard: String? = nil
    ) -> (QuickViewModel, FakePasteboard) {
        let pasteboard = FakePasteboard(string: clipboard)
        let vm = QuickViewModel(launcherCatalog: catalog, pasteboard: pasteboard)
        vm.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        return (vm, pasteboard)
    }

    @Test func copyingASnippetExpandsItsPlaceholders() async throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let catalog = fixture.service()
        let item = try catalog.createSnippet(title: "Stamp", value: "{date format=\"yyyy\"} · {clipboard}")
        let (vm, pasteboard) = pinnedViewModel(catalog, clipboard: "  note  ")

        await vm.insertSnippet(item, mode: .copy)
        #expect(pasteboard.string == "2023 · note")
        #expect(vm.inputMode == nil)
    }

    @Test func aSnippetWithoutPlaceholdersIsCopiedUnchanged() async throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let catalog = fixture.service()
        let item = try catalog.createSnippet(title: "Plain", value: "just text {unknown}")
        let (vm, pasteboard) = pinnedViewModel(catalog)

        await vm.insertSnippet(item, mode: .copy)
        #expect(pasteboard.string == "just text {unknown}")
    }

    @Test func argumentsArePromptedInOrderBeforeTheSnippetGoesOut() async throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let catalog = fixture.service()
        let item = try catalog.createSnippet(
            title: "Invoice",
            value: "Hi {argument name=\"Name\"}, you owe {argument}."
        )
        let (vm, pasteboard) = pinnedViewModel(catalog)

        await vm.insertSnippet(item, mode: .copy)
        #expect(vm.inputMode == .snippetArgument)
        #expect(vm.inputPlaceholder == "Name…")
        #expect(vm.footerContext == "Snippet · Invoice")
        #expect(pasteboard.string == nil, "nothing is inserted until every slot is answered")

        vm.input = "Ana"
        #expect(await vm.submitInputMode())
        #expect(vm.inputMode == .snippetArgument, "the second argument is still to come")
        #expect(vm.inputPlaceholder == "Argument 2…")
        #expect(vm.input.isEmpty)

        vm.input = "£20"
        #expect(await vm.submitInputMode())
        #expect(vm.inputMode == nil)
        #expect(vm.pendingSnippetInsertion == nil)
        #expect(pasteboard.string == "Hi Ana, you owe £20.")
    }

    @Test func leavingTheArgumentPromptCancelsTheInsertion() async throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let catalog = fixture.service()
        let item = try catalog.createSnippet(title: "Ask", value: "Hi {argument}")
        let (vm, pasteboard) = pinnedViewModel(catalog)

        await vm.insertSnippet(item, mode: .copy)
        vm.leaveInputMode()
        #expect(vm.inputMode == nil)
        #expect(vm.pendingSnippetInsertion == nil)
        #expect(pasteboard.string == nil)
    }

    @Test func theViewModelReadsTheClipboardThroughItsSeam() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.remove() }
        let (vm, _) = pinnedViewModel(fixture.service(), clipboard: "seam")
        #expect(vm.expandSnippet("{clipboard}").text == "seam")
        #expect(vm.expandSnippet("a{cursor}b").cursorOffset == 1)
    }
}
