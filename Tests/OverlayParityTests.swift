import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Raycast Quick AI parity: collapsed messages, the answer model actions,
/// Add Context, the Tab hint, the `⌘P` conversation view, model visibility,
/// and the Fallback Command row copy.
@Suite("Quick AI overlay parity", .serialized)
@MainActor
struct OverlayParityTests {

    private let target = SelectionTarget(processIdentifier: 42, applicationName: "Editor")

    // MARK: - Helpers

    private func make(
        settings: QuickSettings = QuickSettings(),
        service: MockQuickService,
        selection: (any SelectedTextServicing)? = nil
    ) -> QuickViewModel {
        QuickViewModel(settings: settings, service: service, selectedTextService: selection)
    }

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, reply: String) async {
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    private func longMessage(lines: Int) -> String {
        (1...lines).map { "line \($0)" }.joined(separator: "\n")
    }

    // MARK: - 1. Collapsed messages

    @Test func aMessageAtTenLinesStaysInFull() {
        let state = MessageCollapseState(text: longMessage(lines: 10))
        #expect(!state.isCollapsible)
        #expect(state.controlTitle == nil)
        #expect(state.displayedText == longMessage(lines: 10))
    }

    @Test func aMessageOverTenLinesCollapsesAndBothControlsSwap() {
        let text = longMessage(lines: 11)
        var state = MessageCollapseState(text: text)

        #expect(state.isCollapsible)
        #expect(state.isCollapsed)
        #expect(state.controlTitle == "Show more")
        #expect(state.displayedText != text)
        #expect(text.hasPrefix(state.displayedText))

        state.toggle()
        #expect(!state.isCollapsed)
        #expect(state.controlTitle == "Collapse")
        #expect(state.displayedText == text)

        state.toggle()
        #expect(state.controlTitle == "Show more")
    }

    @Test func aComparablyLongSingleParagraphCollapsesLikeTenLines() {
        let short = String(repeating: "a", count: MessageCollapsePolicy.collapsedCharacterCount)
        let long = String(repeating: "b", count: MessageCollapsePolicy.collapsedCharacterCount + 1)

        #expect(!MessageCollapsePolicy.shouldCollapse(short))
        #expect(MessageCollapsePolicy.shouldCollapse(long))
        let words = MessageCollapsePolicy.collapsedCharacterCount / "word ".count + 1
        #expect(MessageCollapsePolicy.shouldCollapse(String(repeating: "word ", count: words)))
    }

    @Test func theCollapsedPreviewKeepsTheFirstPartAndNeverCutsAWord() {
        let text = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let preview = MessageCollapsePolicy.preview(of: text)
        #expect(preview.split(separator: "\n").count == MessageCollapsePolicy.previewLineCount)
        #expect(preview.hasPrefix("line 1\n"))

        let paragraph = Array(repeating: "word", count: 400).joined(separator: " ")
        let cut = MessageCollapsePolicy.preview(of: paragraph)
        #expect(!cut.hasSuffix(" "))
        #expect(cut.hasSuffix("word"))
        #expect(paragraph.hasPrefix(cut))
    }

    @Test func theTranscriptTogglesOneMessageAtATime() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        let long = longMessage(lines: 12)
        let short = "a short question"
        vm.currentConversation = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "test",
            messages: [
                QuickMessage(role: .user, content: long),
                QuickMessage(role: .assistant, content: "first answer"),
                QuickMessage(role: .user, content: short),
                QuickMessage(role: .assistant, content: "second answer"),
            ]
        )
        let longID = vm.conversationMessages[0].id

        // The keyboard toggle acts on the newest collapsible message: the
        // short one below it is not a candidate.
        #expect(vm.keyboardToggleMessageID == longID)
        #expect(vm.collapseState(for: vm.conversationMessages[0]).isCollapsed)

        #expect(vm.toggleTranscriptMessage(longID))
        #expect(vm.collapseState(for: vm.conversationMessages[0]).isExpanded)
        #expect(vm.collapseState(for: vm.conversationMessages[1]).controlTitle == nil)
        #expect(!vm.toggleTranscriptMessage(UUID()), "an unknown message is not toggled")
    }

    // MARK: - 2. Answer model actions

    @Test func theShortcutTableKeepsCommandRAndGivesShiftCommandRToTheChooser() {
        #expect(ResultAction.regenerate.shortcut == .command("r"))
        #expect(ResultAction.regenerateWithModel.shortcut == .commandShift("r"))
        #expect(ResultAction.changeModel == .changeModel)
        // Replace Selection moved off ⇧⌘R, which the chooser now owns.
        #expect(ResultAction.replaceSelection.shortcut != .commandShift("r"))
    }

    @Test func changeModelIsAFirstClassResultActionInThePalette() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        await ask(vm, service, "hello", reply: "Hi.")

        #expect(vm.resultActions.contains(.regenerateWithModel))
        #expect(vm.resultActions.contains(.changeModel))
        #expect(vm.paletteResultActions.contains(.changeModel))
        #expect(ResultAction.changeModel.title == "Change Model")
    }

    @Test func regeneratingWithAModelRunsTheLastQuestionAgainOnIt() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        await ask(vm, service, "who won", reply: "First answer")

        vm.openModelChooser(.regenerate)
        #expect(vm.isModelChooserPresented)
        #expect(vm.modelChooserPurpose == .regenerate)
        // The row for the model in use starts selected.
        #expect(vm.modelChooserOptions[vm.modelChooserIndex].model == vm.activeModelID)

        let other = try! #require(vm.modelChooserOptions.first { $0.model != vm.activeModelID })
        vm.modelChooserIndex = vm.modelChooserOptions.firstIndex(of: other)!
        await service.setResponses([StreamDelta(text: "Second answer", finishReason: "stop")])
        await vm.runModelChooserSelection()

        #expect(!vm.isModelChooserPresented)
        #expect(vm.output == "Second answer")
        #expect(vm.settings.quickAIProviderID == other.providerID)
        #expect(vm.settings.quickAIModel == other.model)
        #expect(vm.currentConversation?.model == other.model)
        // The last question was asked again, not a new one.
        #expect(vm.conversationMessages.filter { $0.role == .user }.map(\.content) == ["who won"])
        #expect(await service.sendCallCount == 2)
    }

    @Test func changeModelSwitchesTheActiveModelWithoutSendingAnything() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        await ask(vm, service, "hello", reply: "Hi.")
        let callsBefore = await service.sendCallCount

        let other = try! #require(
            vm.modelChooserEntries().first { $0.model != vm.activeModelID }
        )
        vm.openModelChooser(.change)
        vm.modelChooserIndex = vm.modelChooserOptions.firstIndex(of: other)!
        await vm.runModelChooserSelection()

        #expect(await service.sendCallCount == callsBefore, "Change Model sends nothing")
        #expect(vm.activeModelID == other.model)
        #expect(vm.currentConversation?.model == other.model)
        #expect(vm.resultActionDetail(.changeModel) == "Using \(ModelProfile.displayName(forModelID: other.model))")
    }

    @Test func theChooserAnswersTheLastQuestionAndNeverAPreviousOne() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        await ask(vm, service, "first", reply: "one")
        await service.setResponses([StreamDelta(text: "two", finishReason: "stop")])
        vm.input = "second"
        await vm.submit()

        vm.openModelChooser(.regenerate)
        await vm.runModelChooserSelection()

        // The regenerated turn replaces the last exchange, not the first.
        #expect(await service.lastPrompt == "second")
        #expect(vm.conversationMessages.filter { $0.role == .user }.map(\.content) == ["first", "second"])
        #expect(vm.conversationMessages.filter { $0.role == .assistant }.count == 2)
        #expect(vm.output == "two")
    }

    @Test func theChooserOnlyOffersVisibleModels() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        let provider = try! #require(vm.settings.providers.first { $0.models.count > 1 })
        let hidden = try! #require(provider.models.first { $0 != provider.selectedModel })
        let kept = provider.models.first { $0 != hidden }
        let stillOffered = try! #require(kept)

        ModelPreferenceStore.shared.setEnabled(false, providerID: provider.id, model: hidden)
        defer { ModelPreferenceStore.shared.reset() }

        let visible = vm.visibleModels(for: provider)
        #expect(!visible.contains(hidden))
        #expect(visible.contains(stillOffered))

        // The chooser reads the same list, so a model that is off is never a
        // row it can pick.
        vm.openModelChooser(.change)
        #expect(!vm.modelChooserOptions.contains { $0.model == hidden })
    }

    // MARK: - 3. Add Context

    @Test func bothEntryPointsOpenTheSameMenuAndTheAtIsDropped() {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)

        vm.input = "summarize this "
        vm.openAddContextMenu()
        #expect(vm.addContextOptions == AddContextEntry.allCases)
        #expect(vm.addContextOptions.map(\.title) == [
            "Focused Window", "Selected Text", "Selected Area", "Entire Screen",
        ])
        vm.closeAddContextMenu()

        vm.input = "summarize this @"
        #expect(vm.addContextTriggerDidChange(vm.input))
        #expect(vm.isAddContextMenuPresented)
        #expect(vm.input == "summarize this ", "the half-typed question survives")
    }

    @Test func anAtInsideAWordNeverOpensTheMenu() {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)

        vm.input = "me@"
        #expect(!vm.addContextTriggerDidChange(vm.input))
        #expect(!vm.isAddContextMenuPresented)
        #expect(vm.input == "me@", "an address keeps its @")

        vm.input = "@"
        #expect(vm.addContextTriggerDidChange(vm.input))
        #expect(vm.input.isEmpty)
    }

    @Test func attachedContextStaysWithTheMessageItIsSentWith() async {
        let service = MockQuickService()
        let selection = ParitySelectedTextService(text: "the selected passage")
        var settings = QuickSettings()
        settings.historyEnabled = false
        settings.autoCopy = false
        let vm = make(settings: settings, service: service, selection: selection)
        vm.rememberSelectionTarget(target)

        vm.input = "explain "
        await vm.addContext(.selectedText)
        #expect(vm.hasPendingAttachment)
        #expect(vm.pendingContext?.selectedText == "the selected passage")
        #expect(vm.input == "explain ", "the typed question comes back after a capture")

        await ask(vm, service, "explain ", reply: "Done.")
        // The context rode exactly one request, then left with it.
        #expect(vm.pendingContext == nil)
        #expect(await service.lastPrompt?.contains("the selected passage") == true)
        #expect(vm.conversationMessages.first?.content.contains("the selected passage") == true)

        await service.setResponses([StreamDelta(text: "Follow-up.", finishReason: "stop")])
        vm.input = "and again"
        await vm.submit()
        #expect(await service.lastPrompt?.contains("the selected passage") == false)
    }

    @Test func theAddContextMenuIsKeyboardDriven() {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        vm.openAddContextMenu()

        vm.moveAddContextSelection(1)
        #expect(vm.addContextIndex == 1)
        vm.moveAddContextSelection(-1)
        #expect(vm.addContextIndex == 0)
        vm.moveAddContextSelection(-1)
        #expect(vm.addContextIndex == AddContextEntry.allCases.count - 1, "wraps")

        #expect(vm.topLayer == .addContextMenu)
        #expect(vm.popTopLayer())
        #expect(!vm.isAddContextMenuPresented)
    }

    // MARK: - 4. Tab hint

    @Test func theTabHintFollowsTheSettingInBothStates() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        settings.tabShortcutHintVisible = true
        let vm = make(settings: settings, service: service)

        let shown = vm.askAIItem(query: "").detail
        #expect(shown.contains("⇥"))
        #expect(vm.askAIItem(query: "tigers").detail.contains("⇥"))

        vm.updateSettings { $0.tabShortcutHintVisible = false }
        let hidden = vm.askAIItem(query: "").detail
        #expect(!hidden.contains("⇥"))
        #expect(!hidden.contains("switches to AI"))
        #expect(vm.askAIItem(query: "tigers").detail.contains("tigers"))
    }

    @Test func theTabHintLivesOnTheAskAIRowAndNotOnAnEmptyQueryRowOnly() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        await ask(vm, service, "keep me", reply: "Hi.")

        let row = vm.askAIItem(query: "a typed question")
        #expect(row.kind == .askAI)
        #expect(row.title == "Ask AI")
        #expect(row.detail.contains("⇥"))
        #expect(row.detail.contains(vm.activeModelDisplay))
    }

    // MARK: - 7. Fallback row copy

    @Test func theRootRowNamesTheCommandReturnWillActuallyRun() {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        settings.fallbackCommandIDs = [FallbackCommandID.command("caffeinate.toggle")]
        let vm = make(settings: settings, service: service)

        let entry = vm.fallbackCommandEntry(for: FallbackCommandID.command("caffeinate.toggle"))
        let row = vm.askAIItem(query: "keep the mac awake")
        #expect(row.title == entry.title)
        #expect(row.title != "Ask AI")
        #expect(row.detail == entry.detail)
        vm.input = "keep the mac awake"
        #expect(vm.classifySubmit() == .fallbackCommand(FallbackCommandID.command("caffeinate.toggle")))
    }

    @Test func theRootRowStillSaysAskAIWhenAskAIHeadsTheFallbackList() {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)

        #expect(vm.askAIItem(query: "a question").title == "Ask AI")
        // The empty-query suggestions row is never the fallback row.
        #expect(vm.askAIItem(query: "").title == "Ask AI")
    }

    // MARK: - 5. ⌘P Recent Chats

    @Test func commandPCarriesTheThreadAndTheModelOver() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        await ask(vm, service, "what happened", reply: "An answer.")
        let model = vm.activeModelDisplay
        let messages = vm.conversationMessages

        #expect(vm.performShortcut(
            characters: "p",
            keyCode: 35,
            modifiers: [.command]
        ))

        #expect(vm.isRecentChatsPresented)
        #expect(vm.isQuickAIPresented)
        #expect(vm.topLayer == .recentChats)
        #expect(vm.conversationMessages == messages)
        #expect(vm.activeModelDisplay == model)
        // One column, inside the same fixed Quick AI window: no split view.
        #expect(vm.currentPanelWidth == PanelSizing.panelWidth)
        #expect(vm.estimatedWindowHeight == PanelSizing.quickAIHeight)
    }

    @Test func escapeReturnsFromRecentChatsToTheThread() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        await ask(vm, service, "a question", reply: "An answer.")

        vm.openRecentChats()
        #expect(vm.isRecentChatsPresented)

        #expect(vm.handleEscapeKey())
        #expect(!vm.isRecentChatsPresented)
        #expect(vm.isQuickAIPresented, "back to the thread, not to root search")
        #expect(!vm.output.isEmpty, "the thread is untouched by leaving the list")
        #expect(vm.currentConversation != nil)
    }

    @Test func recentChatsWalksTheHistoryAndOpensAChatInTheThread() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        let older = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "older-model",
            messages: [QuickMessage(role: .user, content: "older")]
        )
        let newer = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "newer-model",
            messages: [QuickMessage(role: .user, content: "newer")]
        )
        vm.history = [newer, older]
        vm.currentConversation = newer

        vm.openRecentChats()
        #expect(vm.recentChatsIndex == 0)

        vm.moveRecentChatsSelection(1)
        #expect(vm.recentChatsIndex == 1)
        // Return opens the highlighted chat in the thread.
        vm.input = ""
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.currentConversation?.id == older.id)
        #expect(vm.activeModelDisplay == "older-model")
        #expect(!vm.isRecentChatsPresented, "the list gives way to the thread")
        #expect(vm.isQuickAIPresented)
        #expect(vm.quickAITitle == "Quick AI", "no answer yet in that chat")
    }

    // MARK: - 6. Model visibility

    @Test func theSubmenuNeverOffersADisabledModel() {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        let provider = try! #require(vm.settings.providers.first { $0.models.count > 1 })
        let hidden = provider.models[1]

        ModelPreferenceStore.shared.setEnabled(false, providerID: provider.id, model: hidden)
        defer { ModelPreferenceStore.shared.reset() }

        #expect(!vm.visibleModels(for: provider).contains(hidden))
        #expect(ModelCatalogService.visibleModels(for: provider).contains(hidden) == false)
    }

    @Test func aRefreshNeverLandsOnADisabledModel() async {
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = make(settings: settings, service: service)
        let providerID = InferenceProvider.deepSeekID
        let index = try! #require(vm.settings.providers.firstIndex { $0.id == providerID })
        vm.settings.providers[index].models = ["model-a", "model-b"]
        vm.settings.providers[index].selectedModel = "model-a"

        ModelPreferenceStore.shared.setEnabled(false, providerID: providerID, model: "model-a")
        defer { ModelPreferenceStore.shared.reset() }

        // The refresh fallback reads the visible list, so the disabled model
        // at the head of the provider's list is never the one it lands on.
        #expect(QuickViewModel.refreshFallbackModel(for: vm.settings.providers[index]) == "model-b")
        // A picker still lists the current model, so it can render what is on.
        #expect(vm.visibleModels(for: vm.settings.providers[index]) == ["model-b", "model-a"])
    }
}

/// Records the selection the overlay captured, and the target it happened in.
@MainActor
private final class ParitySelectedTextService: SelectedTextServicing {
    var isAccessibilityTrusted: Bool { true }
    var selectedText: String?

    init(text: String?) {
        selectedText = text
    }

    func currentExternalTarget() -> SelectionTarget? { nil }

    func capture(
        from target: SelectionTarget,
        promptForPermission: Bool
    ) -> SelectedTextContext? {
        guard let selectedText else { return nil }
        return SelectedTextContext(target: target, text: selectedText)
    }

    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { true }
    func openAccessibilitySettings() {}
}
