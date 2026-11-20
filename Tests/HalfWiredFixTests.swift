import Foundation
import Testing
@testable import QuickLaunch

/// Features that were built but only half wired (found in the Raycast
/// comparison of 2026-11-20): each test fails on the code before the fix.
@Suite("Half-wired fixes", .serialized)
@MainActor
struct HalfWiredFixTests {

    private func make(
        settings: QuickSettings = QuickSettings(),
        service: MockQuickService = MockQuickService(),
        selection: (any SelectedTextServicing)? = nil,
        usage: LauncherUsageStore? = nil
    ) -> QuickViewModel {
        QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection,
            launcherUsage: usage
        )
    }

    // MARK: - Fallback Commands

    @Test func everyFallbackCommandAfterTheFirstGetsARow() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        let prompt = SavedPrompt(alias: "clean", prompt: "Clean this up: {selection}")
        settings.savedPrompts.append(prompt)
        settings.fallbackCommandIDs = [
            FallbackCommandID.askAI,
            FallbackCommandID.savedPrompt(prompt.id),
            FallbackCommandID.savedPrompt(UUID()),  // deleted since: no row
        ]
        let mock = MockQuickService()
        let vm = make(settings: settings, service: mock)

        vm.input = "hello there"
        let rows = vm.launcherMatches
        let fallbacks = rows.filter { $0.id.hasPrefix("command:fallback:") }
        #expect(fallbacks.count == 1, "one row for the saved command, none for the deleted one")
        #expect(rows.last == fallbacks.first, "at the foot of the list")
        #expect(rows.count <= QuickViewModel.maxLauncherRows)
        guard case .item(let row)? = fallbacks.first else { return }
        #expect(row.title == prompt.name)
        #expect(row.detail.contains("hello there"))
        vm.applicationSelectionIndex = rows.count - 1
        #expect(vm.focusedItemActions.map(\.kind) == [.primary], "no pin, alias, hotkey or hide")

        await mock.setResponses([StreamDelta(text: "Tidied.", finishReason: "stop")])
        await vm.performLauncherResult(.item(row))
        #expect(await mock.sendCallCount == 1)
        #expect(await mock.lastPrompt == "Clean this up: hello there")
        #expect(!vm.launcherUsage.hasLearning(itemID: row.id), "a fallback row is not a learned item")
    }

    @Test func aLongFallbackListKeepsRealResults() {
        var settings = QuickSettings()
        settings.savedPrompts = (0..<20).map { SavedPrompt(alias: "p\($0)", prompt: "x {selection}") }
        settings.fallbackCommandIDs = [FallbackCommandID.askAI]
            + settings.savedPrompts.map { FallbackCommandID.savedPrompt($0.id) }
        let vm = make(settings: settings)
        vm.input = "empty trash"
        let rows = vm.launcherMatches
        #expect(rows.filter { $0.id.hasPrefix("command:fallback:") }.count == QuickViewModel.maximumAdditionalFallbackRows)
        #expect(rows.contains { $0.id == "command:toggle.emptyTrash" })
    }

    @Test func oneFallbackCommandAddsNoRow() {
        let vm = make()
        vm.input = "hello there"
        #expect(!vm.launcherMatches.contains { $0.id.hasPrefix("command:fallback:") })
        #expect(vm.additionalFallbackRows(text: "hello there").isEmpty)
    }

    // MARK: - Empty Trash

    @Test func emptyTrashWaitsForASecondReturn() async {
        let vm = make()
        let (ran, continuation) = AsyncStream<QuickToggle>.makeStream()
        vm.runQuickToggle = { toggle in
            continuation.yield(toggle)
            return nil
        }
        let item = vm.systemCommands.first { $0.itemID == "toggle.emptyTrash" }!
        vm.input = "empty"

        vm.performSystemCommand(item)
        #expect(vm.isDestructiveCommandArmed(item.itemID))
        #expect(vm.input == "empty", "the first Return runs nothing and keeps the search")
        let armedRow = vm.systemCommands.first { $0.itemID == "toggle.emptyTrash" }!
        #expect(armedRow.title == "Empty Trash", "the title stays, so the row keeps its place")
        #expect(armedRow.detail.contains("Return again"))

        vm.input = "empt"
        #expect(!vm.isDestructiveCommandArmed(item.itemID), "typing disarms it")

        vm.performSystemCommand(item)
        vm.performSystemCommand(item)
        var iterator = ran.makeAsyncIterator()
        #expect(await iterator.next() == .emptyTrash)
        #expect(vm.armedDestructiveCommand == nil)
    }

    @Test func theArmEndsWithThePanelAndWithAnyOtherRow() async {
        let vm = make()
        vm.runQuickToggle = { _ in
            Issue.record("Empty Trash ran on one Return")
            return nil
        }
        vm.input = "empty trash"
        let trash = vm.launcherMatches.first { $0.id == "command:toggle.emptyTrash" }!
        let usage = vm.launcherUsage
        let place = vm.launcherMatches.firstIndex { $0.id == trash.id }

        await vm.performLauncherResult(trash)
        #expect(vm.armedDestructiveCommand != nil)
        #expect(!usage.hasLearning(itemID: trash.id), "the arming Return is not a choice yet")
        #expect(vm.launcherMatches.firstIndex { $0.id == trash.id } == place, "the armed row stays under the highlight")

        // Escape, then the same text again: one Return must only arm.
        vm.endInteractionSession()
        #expect(vm.armedDestructiveCommand == nil)
        vm.input = "empty trash"
        await vm.performLauncherResult(trash)
        #expect(vm.armedDestructiveCommand != nil)

        // Return on another row drops the arm.
        let dark = vm.systemCommands.first { $0.itemID == "toggle.toggleDarkMode" }!
        vm.runQuickToggle = { _ in nil }
        await vm.performLauncherResult(.item(dark))
        #expect(vm.armedDestructiveCommand == nil)
    }

    @Test func anInputStepIsCountedOnlyWhenItStarts() async {
        let vm = make()
        let before = vm.inputStepGeneration
        let dark = vm.systemCommands.first { $0.itemID == "toggle.toggleDarkMode" }!
        vm.runQuickToggle = { _ in nil }
        await vm.performLauncherItem(dark)
        #expect(vm.inputStepGeneration == before, "a command with no input starts no step")
        let snippet = LauncherCatalogItem(
            kind: .snippet, itemID: "s", title: "G", detail: "", value: "Dear {argument name=\"Name\"},"
        )
        await vm.performLauncherItem(snippet)
        #expect(vm.inputStepGeneration == before + 1)
    }

    @Test func aHotkeyStandsForBothReturns() async {
        let vm = make()
        let (ran, continuation) = AsyncStream<QuickToggle>.makeStream()
        vm.runQuickToggle = { toggle in
            continuation.yield(toggle)
            return nil
        }
        let item = vm.systemCommands.first { $0.itemID == "toggle.emptyTrash" }!
        vm.armDestructiveCommandForDirectUse(item)
        vm.performSystemCommand(item)
        var iterator = ran.makeAsyncIterator()
        #expect(await iterator.next() == .emptyTrash)
    }

    @Test func aToggleThatCanBeUndoneRunsOnTheFirstReturn() async {
        let vm = make()
        let (ran, continuation) = AsyncStream<QuickToggle>.makeStream()
        vm.runQuickToggle = { toggle in
            continuation.yield(toggle)
            return nil
        }
        let item = vm.systemCommands.first { $0.itemID == "toggle.toggleDarkMode" }!
        vm.performSystemCommand(item)
        var iterator = ran.makeAsyncIterator()
        #expect(await iterator.next() == .toggleDarkMode)
    }

    // MARK: - Hotkey steps that need the panel

    @Test func aSnippetArgumentAskedForByHotkeyNeedsThePanel() async {
        let vm = make()
        #expect(!vm.needsPanelForPendingInput)
        let snippet = LauncherCatalogItem(
            kind: .snippet,
            itemID: "s",
            title: "Greeting",
            detail: "",
            value: "Dear {argument name=\"Name\"},"
        )
        await vm.performLauncherItem(snippet)
        #expect(vm.inputMode == .snippetArgument)
        #expect(vm.needsPanelForPendingInput)
    }

    // MARK: - Quicklink slot

    @Test func theQuicklinkSlotHasThreeSpellings() {
        for template in [
            "https://example.com/?q={query}",
            "https://example.com/?q={{input}}",
            "https://example.com/?q={argument name=\"query\"}",
            "https://example.com/?q={argument}",
        ] {
            #expect(QuickLinkQuery.contains(template), "\(template)")
            #expect(
                QuickLinkQuery.render(template, query: "a b&c $1", clipboard: "")
                    == "https://example.com/?q=a%20b%26c%20$1",
                "\(template)"
            )
        }
        #expect(!QuickLinkQuery.contains("https://example.com/{arguments}"))
        // The Raycast spelling holds a space; it must still pass as an address.
        #expect(ItemActionCatalog.looksLikeURL(
            QuickLinkQuery.validationSample("https://example.com/?q={argument name=\"query\"}")
        ))
        #expect(!ItemActionCatalog.looksLikeURL(QuickLinkQuery.validationSample("not a link {query}")))
    }

    // MARK: - {cursor}

    @Test func theCaretStepsBackToTheCursorPlaceholder() {
        let middle = SnippetPlaceholders.expand("Hi {cursor}there")
        #expect(QuickViewModel.caretStepsBack(for: middle) == 5)
        #expect(QuickViewModel.caretStepsBack(for: SnippetPlaceholders.expand("Hi there{cursor}")) == nil)
        #expect(QuickViewModel.caretStepsBack(for: SnippetPlaceholders.expand("Hi there")) == nil)
        let long = SnippetPlaceholders.expand("{cursor}" + String(repeating: "x", count: 501))
        #expect(QuickViewModel.caretStepsBack(for: long) == nil)
    }

    @Test func pastingASnippetMovesTheCaret() async {
        let selection = CaretSpy()
        let vm = make(selection: selection)
        let snippet = LauncherCatalogItem(
            kind: .snippet, itemID: "s", title: "Sign-off", detail: "", value: "Best,{cursor}\nT"
        )
        await vm.insertSnippet(snippet, mode: .paste)
        #expect(selection.pasted == "Best,\nT")
        #expect(selection.caretSteps == 2)

        await vm.insertSnippet(snippet, mode: .copy)
        #expect(selection.caretSteps == 2, "a copy moves nothing")
    }

    // MARK: - Command action arguments

    @Test func commandArgumentsHonourQuotes() {
        let line = #"search "two words" --path '/a b/c' x\ y {input} """#
        let parts = CommandActionRunner.splitArguments(line)
        #expect(parts == ["search", "two words", "--path", "/a b/c", "x y", "{input}", ""])
        #expect(CommandActionRunner.splitArguments(CommandActionRunner.joinArguments(parts)) == parts)
        #expect(CommandActionRunner.splitArguments("  plain   words ") == ["plain", "words"])
        #expect(CommandActionRunner.joinArguments(["a", "b c"]) == #"a "b c""#)
        let tricky = [#"say "hi""#, #"back\slash"#, "it's"]
        #expect(CommandActionRunner.splitArguments(CommandActionRunner.joinArguments(tricky)) == tricky)
        // Inside double quotes a backslash stays unless it escapes " or \.
        #expect(CommandActionRunner.splitArguments(#"grep "\d+" "%s\n""#) == ["grep", #"\d+"#, #"%s\n"#])
        let patterns = [#"\d+"#, #"a\nb"#]
        #expect(CommandActionRunner.splitArguments(CommandActionRunner.joinArguments(patterns)) == patterns)
        #expect(CommandActionRunner.splitArguments("say \u{201C}two words\u{201D}") == ["say", "two words"])
    }

    // MARK: - Reset ranking for one row

    @Test func forgettingOneRowLeavesTheOthers() {
        let store = LauncherUsageStore(fileURL: nil)
        store.recordSelection(query: "sa", scope: LauncherUsageStore.rootScope, itemID: "application:safari")
        store.recordUse(itemID: "application:notes")
        #expect(store.hasLearning(itemID: "application:safari"))
        store.forget(itemID: "application:safari")
        #expect(!store.hasLearning(itemID: "application:safari"))
        #expect(store.hasLearning(itemID: "application:notes"))
    }

    @Test func theActionPaneOffersForgetOnlyForALearnedRow() async {
        let store = LauncherUsageStore(fileURL: nil)
        let vm = make(usage: store)
        vm.input = "empty trash"
        guard let row = vm.launcherMatches.first(where: { $0.id == "command:toggle.emptyTrash" }) else {
            Issue.record("Empty Trash is not in the list")
            return
        }
        vm.applicationSelectionIndex = vm.launcherMatches.firstIndex(of: row)!
        #expect(!vm.focusedItemActions.contains { $0.kind == .resetRanking })

        store.recordUse(itemID: row.id)
        let action = vm.focusedItemActions.first { $0.kind == .resetRanking }
        #expect(action != nil)
        if let action { await vm.perform(action, on: row) }
        #expect(!store.hasLearning(itemID: row.id))
    }
}

/// A paste target that records what was pasted and how far the caret moved.
private final class CaretSpy: SelectedTextServicing {
    var isAccessibilityTrusted = true
    var pasted: String?
    var caretSteps = 0

    func currentExternalTarget() -> SelectionTarget? {
        SelectionTarget(processIdentifier: 1, applicationName: "Notes")
    }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? { nil }
    func hasSelection(from target: SelectionTarget) -> Bool { false }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { false }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        pasted = text
        return true
    }
    func pastePasteboard(to target: SelectionTarget) async -> Bool { true }
    func openAccessibilitySettings() {}
    func moveCaretLeft(by count: Int) async { caretSteps += count }
}
