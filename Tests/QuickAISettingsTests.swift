import Foundation
import Testing
@testable import QuickLaunch

/// Quick AI settings: the migration off the old shape, the Start New Chat
/// options, the primary action Return runs on a finished answer, and the
/// Fallback Commands routing.
@Suite("Quick AI settings", .serialized)
@MainActor
struct QuickAISettingsTests {

    // MARK: - Helpers

    private func decode(_ json: String) throws -> QuickSettings {
        try JSONDecoder().decode(QuickSettings.self, from: Data(json.utf8))
    }

    private func make(
        settings: QuickSettings = QuickSettings(),
        service: MockQuickService,
        selection: (any SelectedTextServicing)? = nil,
        pasteboard: (any PasteboardWriting)? = nil
    ) -> QuickViewModel {
        QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection,
            pasteboard: pasteboard
        )
    }

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, reply: String) async {
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    // MARK: - Migration

    @Test func aLegacyMinuteCountMovesOntoTheNearestOption() throws {
        let expected: [(stored: Int, option: NewChatInterval)] = [
            (1, .fiveMinutes),
            (5, .fiveMinutes),
            (7, .fiveMinutes),
            (8, .tenMinutes),
            (15, .fifteenMinutes),
            (22, .fifteenMinutes),
            (23, .thirtyMinutes),
            (45, .thirtyMinutes),
            (46, .oneHour),
            (600, .oneHour),
        ]
        for (stored, option) in expected {
            let settings = try decode(
                #"{"configurationVersion":21,"newConversationAfterMinutes":\#(stored)}"#
            )
            #expect(settings.newChatInterval == option, "\(stored) minutes")
            #expect(settings.configurationVersion == 22)
        }
    }

    @Test func oldBlobsMissingEveryNewKeyLoadWithTheDocumentedDefaults() throws {
        let settings = try decode(#"{"configurationVersion":21,"newConversationAfterMinutes":15}"#)
        #expect(settings.quickAIPrimaryAction == .pasteToActiveApp)
        #expect(settings.tabShortcutHintVisible)
        #expect(settings.quickAIProviderID == nil)
        #expect(settings.quickAIModel.isEmpty)
        #expect(settings.fallbackCommandIDs == [FallbackCommandID.askAI])
        #expect(settings.newChatInterval == .fifteenMinutes, "the stored count still decides")
    }

    /// A blob with no version and no keys at all, the oldest shape there is.
    @Test func aVersionlessBlobStillDecodes() throws {
        let settings = try decode(#"{"autoCopy":false}"#)
        #expect(settings.configurationVersion == 22)
        #expect(settings.autoCopy == false)
        #expect(settings.newChatInterval == .fiveMinutes)
        #expect(settings.quickAIPrimaryAction == .pasteToActiveApp)
        #expect(settings.tabShortcutHintVisible)
        #expect(settings.fallbackCommandIDs == [FallbackCommandID.askAI])
    }

    @Test func theNewFieldsRoundTripThroughAFile() throws {
        var settings = QuickSettings()
        settings.newChatInterval = .never
        settings.quickAIPrimaryAction = .copyToClipboard
        settings.tabShortcutHintVisible = false
        settings.quickAIProviderID = InferenceProvider.deepSeekID
        settings.quickAIModel = "deepseek-chat"
        settings.fallbackCommandIDs = [FallbackCommandID.savedPrompt(UUID()), FallbackCommandID.askAI]

        let data = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(QuickSettings.self, from: data)
        #expect(back.newChatInterval == .never)
        #expect(back.quickAIPrimaryAction == .copyToClipboard)
        #expect(back.tabShortcutHintVisible == false)
        #expect(back.quickAIProviderID == InferenceProvider.deepSeekID)
        #expect(back.quickAIModel == "deepseek-chat")
        #expect(back.fallbackCommandIDs == settings.fallbackCommandIDs)
    }

    @Test func aRememberedQuickAIProviderThatIsGoneFallsBackToTheSelection() throws {
        let missing = UUID()
        let settings = try decode(
            #"{"configurationVersion":22,"quickAIProviderID":"\#(missing.uuidString)","quickAIModel":"gone"}"#
        )
        #expect(settings.quickAIProviderID == nil)
        #expect(settings.quickAIModel.isEmpty)
        #expect(settings.quickAIProvider?.id == settings.selectedProviderID)
    }

    @Test func theNearestOptionTiesOnTheShorterWindow() {
        #expect(NewChatInterval.nearest(toMinutes: 0) == .fiveMinutes)
        #expect(NewChatInterval.nearest(toMinutes: 12) == .tenMinutes)
        #expect(NewChatInterval.nearest(toMinutes: 13) == .fifteenMinutes)
        #expect(NewChatInterval.nearest(toMinutes: 22) == .fifteenMinutes)
        #expect(NewChatInterval.nearest(toMinutes: 23) == .thirtyMinutes)
        // The order the card reads, which is the order the manual gives.
        #expect(NewChatInterval.allCases.map(\.displayName) == [
            "5 minutes", "10 minutes", "15 minutes", "30 minutes", "1 hour", "Always", "Never",
        ])
        #expect(NewChatInterval.always.minutes == nil)
        #expect(NewChatInterval.never.minutes == nil)
    }

    // MARK: - Start New Chat

    @Test func alwaysStartsANewChatForEveryQuestion() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.newChatInterval = .always
        let mock = MockQuickService()
        let vm = make(settings: settings, service: mock)

        await ask(vm, mock, "first question", reply: "First answer")
        await ask(vm, mock, "second question", reply: "Second answer")

        #expect(vm.currentConversation?.messages.count == 2, "the second question starts a new chat")
        #expect(vm.history.count == 2)
        #expect(vm.currentConversation?.title == "second question")
    }

    @Test func neverKeepsOneThreadUntilTheUserStartsANewOne() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.newChatInterval = .never
        let mock = MockQuickService()
        let vm = make(settings: settings, service: mock)

        await ask(vm, mock, "first question", reply: "First answer")
        vm.currentConversation?.updatedAt = Date(timeIntervalSince1970: 0)
        await ask(vm, mock, "second question", reply: "Second answer")

        #expect(vm.currentConversation?.messages.count == 4, "an old chat is never replaced")
        #expect(vm.history.count == 1)
        #expect(vm.isFollowUp)
    }

    @Test func eachTimedOptionUsesItsOwnWindow() async {
        for option in NewChatInterval.allCases {
            guard let minutes = option.minutes else { continue }
            let window = Double(minutes) * 60

            var inside = QuickSettings()
            inside.autoCopy = false
            inside.newChatInterval = option
            let insideMock = MockQuickService()
            let insideVM = make(settings: inside, service: insideMock)
            await ask(insideVM, insideMock, "first", reply: "one")
            insideVM.currentConversation?.updatedAt = Date().addingTimeInterval(-(window - 5))
            await ask(insideVM, insideMock, "second", reply: "two")
            #expect(insideVM.currentConversation?.messages.count == 4, "\(option.displayName) inside")

            var outside = QuickSettings()
            outside.autoCopy = false
            outside.newChatInterval = option
            let outsideMock = MockQuickService()
            let outsideVM = make(settings: outside, service: outsideMock)
            await ask(outsideVM, outsideMock, "first", reply: "one")
            outsideVM.currentConversation?.updatedAt = Date().addingTimeInterval(-(window + 5))
            await ask(outsideVM, outsideMock, "second", reply: "two")
            #expect(outsideVM.currentConversation?.messages.count == 2, "\(option.displayName) outside")
            #expect(outsideVM.history.count == 2)
        }
    }

    // MARK: - Primary action

    @Test func returnWithAnEmptyComposerPastesWhenPrimaryActionIsPaste() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.quickAIPrimaryAction = .pasteToActiveApp
        let mock = MockQuickService()
        let selection = QuickAIPasteRecorder()
        let vm = make(settings: settings, service: mock, selection: selection)
        vm.rememberSelectionTarget(SelectionTarget(processIdentifier: 1, applicationName: "Notes"))
        await ask(vm, mock, "hello", reply: "Bonjour")

        vm.input = ""
        #expect(vm.classifySubmit() == .answerIdle)
        await vm.submitResolvingFuzzyAlias()

        #expect(selection.pasted == "Bonjour")
        #expect(vm.errorMessage == nil)
        #expect(await mock.sendCallCount == 1, "Return on an answer never asks again")
    }

    @Test func returnWithAnEmptyComposerCopiesWhenPrimaryActionIsCopy() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.quickAIPrimaryAction = .copyToClipboard
        let mock = MockQuickService()
        let selection = QuickAIPasteRecorder()
        let pasteboard = FakePasteboard()
        let vm = make(settings: settings, service: mock, selection: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(SelectionTarget(processIdentifier: 1, applicationName: "Notes"))
        await ask(vm, mock, "hello", reply: "Bonjour")

        vm.input = ""
        await vm.submitResolvingFuzzyAlias()

        #expect(selection.pasted == nil, "copy never pastes")
        #expect(pasteboard.string == "Bonjour")
        #expect(vm.justCopied)
    }

    @Test func pasteWithNoTargetExplainsInsteadOfDoingNothing() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.quickAIPrimaryAction = .pasteToActiveApp
        let mock = MockQuickService()
        let vm = make(settings: settings, service: mock)
        await ask(vm, mock, "hello", reply: "Bonjour")

        vm.input = ""
        await vm.submitResolvingFuzzyAlias()

        #expect(vm.errorMessage == "Open Quick Launch from the app where you want to paste.")
        #expect(vm.output == "Bonjour", "the answer stays on screen")
    }

    @Test func typedTextOnAnAnswerStillSubmits() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.quickAIPrimaryAction = .pasteToActiveApp
        let mock = MockQuickService()
        let selection = QuickAIPasteRecorder()
        let vm = make(settings: settings, service: mock, selection: selection)
        vm.rememberSelectionTarget(SelectionTarget(processIdentifier: 1, applicationName: "Notes"))
        await ask(vm, mock, "hello", reply: "Bonjour")

        await mock.setResponses([StreamDelta(text: "Encore.", finishReason: "stop")])
        vm.input = "and in French?"
        await vm.submitResolvingFuzzyAlias()

        #expect(await mock.sendCallCount == 2, "typed text is a follow-up, never the primary action")
        #expect(selection.pasted == nil)
        #expect(vm.currentConversation?.messages.count == 4)
    }

    // MARK: - Fallback Commands

    @Test func theDefaultFallbackIsAskAI() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        let mock = MockQuickService()
        let vm = make(settings: settings, service: mock)

        vm.input = "hello there"
        #expect(vm.classifySubmit() == .fallbackCommand(FallbackCommandID.askAI))
        #expect(vm.settings.firstFallbackCommandID == FallbackCommandID.askAI)

        await mock.setResponses([StreamDelta(text: "Hi.", finishReason: "stop")])
        await vm.submitResolvingFuzzyAlias()
        #expect(await mock.sendCallCount == 1)
        #expect(await mock.lastPrompt == "hello there")
    }

    @Test func theFirstConfiguredFallbackRunsOnReturn() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        let prompt = SavedPrompt(alias: "clean", prompt: "Clean this up: {selection}")
        settings.savedPrompts.append(prompt)
        settings.fallbackCommandIDs = [FallbackCommandID.savedPrompt(prompt.id), FallbackCommandID.askAI]
        let mock = MockQuickService()
        let vm = make(settings: settings, service: mock)

        vm.input = "rough draft text"
        #expect(vm.classifySubmit() == .fallbackCommand(FallbackCommandID.savedPrompt(prompt.id)))

        await mock.setResponses([StreamDelta(text: "Tidied.", finishReason: "stop")])
        await vm.submitResolvingFuzzyAlias()
        #expect(await mock.sendCallCount == 1)
        #expect(await mock.lastPrompt == "Clean this up: rough draft text")
    }

    @Test func anEmptyFallbackListMakesReturnDoNothing() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.fallbackCommandIDs = []
        let mock = MockQuickService()
        let vm = make(settings: settings, service: mock)

        vm.input = "hello there"
        #expect(vm.classifySubmit() == .fallbackCommand(nil))
        await vm.submitResolvingFuzzyAlias()

        #expect(await mock.sendCallCount == 0)
        #expect(vm.input == "hello there", "the typed text stays a search")
        #expect(vm.output.isEmpty)
    }

    @Test func tabOpensQuickAIWhateverTheFallbackListHolds() async {
        for list in [[FallbackCommandID.askAI], [], [FallbackCommandID.command("caffeinate.toggle")]] {
            var settings = QuickSettings()
            settings.fallbackCommandIDs = list
            let vm = make(settings: settings, service: MockQuickService())
            vm.input = "hello there"
            #expect(vm.handleTab())
            #expect(vm.inputMode == .askAI, "\(list)")
            #expect(vm.launcherMatches.isEmpty)
        }
    }

    @Test func aPinnedAskAIRowStillAsksTheModel() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.launcherItemConfigurations.append(
            LauncherItemConfiguration(kind: .askAI, itemID: QuickViewModel.askAIItemID, isPinned: true)
        )
        let prompt = SavedPrompt(alias: "clean", prompt: "Clean this up: {selection}")
        settings.savedPrompts.append(prompt)
        settings.fallbackCommandIDs = [FallbackCommandID.savedPrompt(prompt.id)]
        let mock = MockQuickService()
        let vm = make(settings: settings, service: mock)
        vm.input = "hello there"

        guard case .launcherRow(let index) = vm.classifySubmit() else {
            Issue.record("a pinned Ask AI row is an explicit choice")
            return
        }
        #expect(vm.launcherMatches[index].id == "askAI:ask")

        await mock.setResponses([StreamDelta(text: "Hi.", finishReason: "stop")])
        await vm.submitResolvingFuzzyAlias()
        #expect(await mock.lastPrompt == "hello there")
    }

    @Test func anAliasedAskAIRowStillAsksTheModel() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.launcherItemConfigurations.append(
            LauncherItemConfiguration(kind: .askAI, itemID: QuickViewModel.askAIItemID, alias: "ai")
        )
        let prompt = SavedPrompt(alias: "clean", prompt: "Clean this up: {selection}")
        settings.savedPrompts.append(prompt)
        settings.fallbackCommandIDs = [FallbackCommandID.savedPrompt(prompt.id)]
        let mock = MockQuickService()
        let vm = make(settings: settings, service: mock)
        vm.input = "ai"

        guard case .launcherRow(let index) = vm.classifySubmit() else {
            Issue.record("an aliased Ask AI row is an explicit choice")
            return
        }
        #expect(vm.launcherMatches[index].id == "askAI:ask")

        await mock.setResponses([StreamDelta(text: "Hi.", finishReason: "stop")])
        await vm.submitResolvingFuzzyAlias()
        #expect(await mock.lastPrompt == "ai")
    }

    @Test func aDeletedFallbackCommandReportsItselfInsteadOfCrashing() async {
        let missing = FallbackCommandID.savedPrompt(UUID())
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.fallbackCommandIDs = [missing]
        let mock = MockQuickService()
        let vm = make(settings: settings, service: mock)

        #expect(vm.fallbackCommandEntries.map(\.title) == ["Missing command"])
        vm.input = "hello there"
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.errorMessage == "That fallback command is no longer available.")
        #expect(await mock.sendCallCount == 0)
    }

    @Test func theCardCannotAddWhatItAlreadyHolds() {
        var settings = QuickSettings()
        settings.fallbackCommandIDs = [FallbackCommandID.askAI]
        let vm = make(settings: settings, service: MockQuickService())
        let offered = vm.fallbackCommandChoiceGroups.flatMap(\.choices).map(\.id)
        #expect(!offered.contains(FallbackCommandID.askAI), "Ask AI is already listed")

        vm.addFallbackCommand(FallbackCommandID.command("caffeinate.toggle"))
        #expect(vm.settings.fallbackCommandIDs == [
            FallbackCommandID.askAI,
            FallbackCommandID.command("caffeinate.toggle"),
        ])
        vm.addFallbackCommand(FallbackCommandID.command("caffeinate.toggle"))
        #expect(vm.settings.fallbackCommandIDs.count == 2, "adding twice changes nothing")
        #expect(vm.fallbackCommandEntries.last?.title == "Caffeinate: Off")

        vm.moveFallbackCommand(FallbackCommandID.command("caffeinate.toggle"), toIndex: 0)
        #expect(vm.settings.fallbackCommandIDs.first == FallbackCommandID.command("caffeinate.toggle"))
        vm.moveFallbackCommand(FallbackCommandID.command("caffeinate.toggle"), toIndex: 9)
        #expect(vm.settings.fallbackCommandIDs.last == FallbackCommandID.command("caffeinate.toggle"))

        vm.removeFallbackCommand(FallbackCommandID.askAI)
        #expect(vm.settings.fallbackCommandIDs.count == 1)
        vm.removeFallbackCommand(FallbackCommandID.command("caffeinate.toggle"))
        #expect(vm.settings.fallbackCommandIDs.isEmpty)
        #expect(vm.fallbackCommandEntries.isEmpty)
    }

    // MARK: - Default model

    @Test func theQuickAIModelAnswersAndTheSelectionIsTheFallback() async {
        var settings = QuickSettings()
        settings.autoCopy = false
        let mock = MockQuickService()

        let unset = make(settings: settings, service: mock)
        unset.selectModel(providerID: InferenceProvider.deepSeekID, model: "current-model")
        #expect(unset.activeModelDisplay == "current-model")
        await ask(unset, mock, "hello", reply: "Hi.")
        #expect(unset.currentConversation?.model == "current-model")
        #expect(unset.currentConversation?.providerID == InferenceProvider.deepSeekID)

        settings.select(providerID: InferenceProvider.deepSeekID, model: "current-model")
        settings.quickAIProviderID = InferenceProvider.deepSeekID
        settings.quickAIModel = "quick-ai-model"
        let chosen = make(settings: settings, service: MockQuickService())
        #expect(chosen.activeModelDisplay == "quick-ai-model")
        await ask(chosen, mock, "hello again", reply: "Hi.")
        #expect(chosen.currentConversation?.model == "quick-ai-model")
        #expect(chosen.settings.selectedModel == "current-model", "the launcher selection is untouched")
    }

    @Test func theTabHintSettingIsPersistedAndIndependent() {
        var settings = QuickSettings()
        settings.tabShortcutHintVisible = false
        let vm = make(settings: settings, service: MockQuickService())
        #expect(!vm.showsTabShortcutHint)
        vm.updateSettings { $0.tabShortcutHintVisible = true }
        #expect(vm.showsTabShortcutHint)
    }
}

/// Records paste-back without touching the real Accessibility path.
@MainActor
private final class QuickAIPasteRecorder: SelectedTextServicing {
    private(set) var pasted: String?
    var isAccessibilityTrusted: Bool { true }
    func currentExternalTarget() -> SelectionTarget? { nil }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? { nil }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        pasted = text
        return true
    }
    func openAccessibilitySettings() {}
}
