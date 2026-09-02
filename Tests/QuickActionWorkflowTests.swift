import AppKit
import Testing
@testable import QuickLaunch

@Suite("Quick action workflow", .serialized)
@MainActor
struct QuickActionWorkflowTests {
    private let target = SelectionTarget(processIdentifier: 42, applicationName: "Editor")

    @Test func selectedTextFeedsActionPrompt() async {
        let selection = FakeSelectedTextService(text: "Long selected passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Short summary", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "tldr" })!
        await vm.perform(action: action)

        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("Long selected passage") == true)
        #expect(vm.output == "Short summary")
    }

    @Test func replaceActionWritesBackToCapturedSelection() async {
        let selection = FakeSelectedTextService(text: "rough words")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Polished words", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "grammar" })!
        await vm.perform(action: action)

        #expect(selection.replacedText == "Polished words")
        #expect(selection.replacedContext?.text == "rough words")
    }

    @Test func fuzzyAliasRunsWithoutFullSpelling() async {
        let selection = FakeSelectedTextService(text: "A long passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Summary", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.input = "/smrz"

        await vm.submitResolvingFuzzyAlias()

        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("A long passage") == true)
        #expect(vm.output == "Summary")
    }

    @Test func missingPermissionProducesUsefulError() async {
        let selection = FakeSelectedTextService(text: nil, trusted: false)
        let vm = QuickViewModel(
            service: MockQuickService(),
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "tldr" })!
        await vm.perform(action: action)

        #expect(vm.errorMessage?.contains("Accessibility") == true)
    }

    @Test func streamCompletionRequestsInputFocus() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Answer", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: service)
        let before = vm.inputFocusRequest
        vm.input = "Question"

        await vm.submit()

        #expect(vm.inputFocusRequest > before)
    }

    @Test func resultCanPasteBackToPreviousApp() async {
        let selection = FakeSelectedTextService(text: nil)
        let vm = QuickViewModel(
            service: MockQuickService(),
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.output = "Paste this result"

        let pasted = await vm.pasteOutputToPreviousApp()

        #expect(pasted)
        #expect(selection.pastedText == "Paste this result")
        #expect(selection.pastedTarget == target)
    }

    @Test func snippetCanCopyPasteOrDoBoth() async {
        let selection = FakeSelectedTextService(text: nil)
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(
            service: MockQuickService(),
            selectedTextService: selection,
            pasteboard: pasteboard
        )
        vm.rememberSelectionTarget(target)
        vm.prepareForExternalAction = { selection.externalActionPrepared = true }
        let item = LauncherCatalogItem(
            kind: .snippet,
            itemID: "greeting",
            title: "Greeting",
            detail: "Test",
            value: "Hello there"
        )

        vm.copyLauncherItem(item)
        #expect(pasteboard.string == "Hello there")
        #expect(await vm.pasteLauncherItem(item))
        #expect(selection.pastedText == "Hello there")
        #expect(selection.wasPreparedWhenPasted)
        #expect(await vm.copyAndPasteLauncherItem(item))
        #expect(pasteboard.string == "Hello there")
    }

    @Test func blockedSnippetPasteReportsAccessibilityAndRestoresOverlay() async {
        let selection = FakeSelectedTextService(text: nil, trusted: false)
        selection.pasteSucceeds = false
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        var recovered = false
        vm.prepareForExternalAction = { selection.externalActionPrepared = true }
        vm.recoverFromExternalActionFailure = { recovered = true }
        let item = LauncherCatalogItem(
            kind: .snippet,
            itemID: "blocked",
            title: "Blocked",
            detail: "Test",
            value: "Private value"
        )

        #expect(!(await vm.pasteLauncherItem(item)))
        #expect(recovered)
        #expect(vm.errorMessage?.contains("Accessibility") == true)
    }

    @Test func windowCommandTargetsPreviousWindowAfterDismissingOverlay() {
        let windows = FakeWindowManager()
        let vm = QuickViewModel(windowManager: windows)
        vm.rememberSelectionTarget(target)
        vm.prepareForExternalAction = { windows.externalActionPrepared = true }
        let item = vm.systemCommands.first { $0.itemID == "window.centerThird" }!

        vm.performSystemCommand(item)

        #expect(windows.appliedLayout == .centerThird)
        #expect(windows.appliedTarget == target)
        #expect(windows.wasPreparedWhenApplied)
    }

    @Test func caffeinateCommandTogglesAndPersistsIntent() {
        let caffeine = FakeCaffeinateManager()
        let vm = QuickViewModel(caffeinateManager: caffeine)
        vm.persistSettings = { _ in }
        let item = vm.systemCommands.first { $0.itemID == "caffeinate.toggle" }!

        vm.performSystemCommand(item)
        #expect(vm.isCaffeinating)
        #expect(vm.settings.caffeinateEnabled)
        #expect(caffeine.isEnabled)

        vm.performSystemCommand(vm.systemCommands.first { $0.itemID == "caffeinate.toggle" }!)
        #expect(!vm.isCaffeinating)
        #expect(!vm.settings.caffeinateEnabled)
    }
}

@MainActor
private final class FakeWindowManager: WindowManaging {
    var isAccessibilityTrusted = true
    var externalActionPrepared = false
    var wasPreparedWhenApplied = false
    var appliedLayout: WindowLayout?
    var appliedTarget: SelectionTarget?

    func apply(_ layout: WindowLayout, to target: SelectionTarget) -> Bool {
        wasPreparedWhenApplied = externalActionPrepared
        appliedLayout = layout
        appliedTarget = target
        return true
    }

    var appliedMove: WindowMove?

    func move(_ move: WindowMove, target: SelectionTarget) -> Bool {
        wasPreparedWhenApplied = externalActionPrepared
        appliedMove = move
        appliedTarget = target
        return true
    }
}

@MainActor
private final class FakeCaffeinateManager: CaffeinateManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) -> Bool {
        isEnabled = enabled
        return true
    }
}

@MainActor
private final class FakeSelectedTextService: SelectedTextServicing {
    var isAccessibilityTrusted: Bool
    var selectedText: String?
    var replacedText: String?
    var replacedContext: SelectedTextContext?
    var pastedText: String?
    var pastedTarget: SelectionTarget?
    var externalActionPrepared = false
    var wasPreparedWhenPasted = false
    var pasteSucceeds = true
    var openedSettings = false

    init(text: String?, trusted: Bool = true) {
        selectedText = text
        isAccessibilityTrusted = trusted
    }

    func currentExternalTarget() -> SelectionTarget? { nil }

    func capture(
        from target: SelectionTarget,
        promptForPermission: Bool
    ) -> SelectedTextContext? {
        guard isAccessibilityTrusted, let selectedText else { return nil }
        return SelectedTextContext(target: target, text: selectedText)
    }

    func replace(_ text: String, in context: SelectedTextContext) async -> Bool {
        replacedText = text
        replacedContext = context
        return true
    }

    func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        wasPreparedWhenPasted = externalActionPrepared
        pastedText = text
        pastedTarget = target
        return pasteSucceeds
    }

    func openAccessibilitySettings() { openedSettings = true }
}
