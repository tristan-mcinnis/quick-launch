// QuickAISurfaceTests — the Raycast Quick AI surface (docs/quick-ai-raycast-
// surface-20260911.md): one fixed window that replaces the launcher, entered
// by Tab, left by Escape with the thread kept, with Recent Chats inside it;
// the model migration off the sunset vision id; and the clarifying-question
// tool behind its setting.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Quick AI surface", .serialized)
@MainActor
struct QuickAISurfaceTests {

    private func make(
        service: MockQuickService = MockQuickService(),
        configure: (inout QuickSettings) -> Void = { _ in }
    ) -> QuickViewModel {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        configure(&settings)
        return QuickViewModel(settings: settings, service: service)
    }

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, reply: String) async {
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    private static let searchResult = """
    ## [1] Raycast
    URL: https://www.raycast.com/about
    Snippet: Raycast was co-founded by Thomas Paul Mann and Petr Nikolaev.
    """

    /// A model with a kept thread and a web search that waits for the test.
    private func makeSearching() async -> (QuickViewModel, MockQuickService, GatedWebSearchService) {
        let search = GatedWebSearchService(result: Self.searchResult)
        let mock = MockQuickService()
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: mock, webSearchService: search)
        await ask(vm, mock, "first", reply: "One.")
        await mock.setResponses([StreamDelta(text: "Thomas Paul Mann.", finishReason: "stop")])
        return (vm, mock, search)
    }

    // MARK: - Entering

    @Test func tabWithTextOpensTheSurfaceAndSubmitsInTheSameGesture() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Thomas Paul Mann and Petr Nikolaev.", finishReason: "stop")])
        let vm = make(service: mock)
        vm.input = "raycast founder"

        #expect(vm.handleTab())
        #expect(vm.isQuickAIPresented)
        #expect(vm.launcherMatches.isEmpty)
        await vm.tabSubmitTask?.value

        #expect(await mock.sendCallCount == 1, "nothing is staged for editing")
        #expect(vm.lastQuestion == "raycast founder")
        #expect(vm.output == "Thomas Paul Mann and Petr Nikolaev.")
        #expect(vm.quickAITitle == "Raycast founder", "the title is the first user message, capitalised")
        #expect(vm.input.isEmpty)
    }

    @Test func tabWithNoTextOpensTheSurfaceEmpty() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.input = ""

        #expect(vm.handleTab())

        #expect(vm.isQuickAIPresented)
        #expect(vm.tabSubmitTask == nil)
        #expect(await mock.sendCallCount == 0)
        #expect(vm.output.isEmpty)
        #expect(vm.quickAITitle == "Quick AI")
        #expect(vm.quickAIComposerAction == .init(label: "Ask", keys: ["↩"]))
        #expect(vm.launcherMatches.isEmpty)
    }

    @Test func theAskAIRowAndTheFallbackCommandSubmitLikeTab() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "One.", finishReason: "stop")])
        let vm = make(service: mock)
        await vm.performLauncherItem(vm.askAIItem(query: "one question"))
        #expect(vm.isQuickAIPresented)
        #expect(await mock.sendCallCount == 1)
        #expect(await mock.lastPrompt == "one question")

        vm.closeQuickAI()
        await mock.setResponses([StreamDelta(text: "Two.", finishReason: "stop")])
        vm.input = "another question here"
        #expect(vm.classifySubmit() == .fallbackCommand(FallbackCommandID.askAI))
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.isQuickAIPresented)
        #expect(await mock.sendCallCount == 2)
        #expect(await mock.lastPrompt == "another question here")
    }

    @Test func aliasCompletionOnTabIsUnchanged() {
        let vm = make()
        vm.input = "/gram"
        #expect(vm.handleTab())
        #expect(!vm.isQuickAIPresented, "an alias completes; Quick AI stays closed")
        #expect(vm.input.hasPrefix("/grammar"))
    }

    // MARK: - Size

    @Test func theSurfaceIsAFixedSevenFiftyByFourSeventyFive() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        #expect(vm.currentPanelWidth == 750)
        #expect(vm.estimatedWindowHeight == 475)
        #expect(vm.currentPanelWidth == House.Layout.panelWidth)
        #expect(vm.estimatedWindowHeight == House.Layout.quickAIHeight)

        await ask(vm, mock, "a long one", reply: String(repeating: "A line of prose.\n", count: 200))
        #expect(vm.estimatedWindowHeight == 475, "the thread scrolls; the window never grows")

        vm.handleCommandK()
        #expect(vm.isActionPalettePresented)
        #expect(vm.estimatedWindowHeight == 475, "the palette floats over the fixed surface")
        vm.closeActionPalette()

        vm.openModelChooser(.change)
        #expect(vm.isModelChooserPresented)
        #expect(vm.estimatedWindowHeight == 475, "the chooser floats above the composer")
        vm.closeModelChooser()

        vm.openRecentChats()
        #expect(vm.isRecentChatsPresented)
        #expect(vm.currentPanelWidth == 750)
        #expect(vm.estimatedWindowHeight == 475)
    }

    // MARK: - Leaving

    @Test func escapeReturnsToRootSearchAndKeepsTheThread() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        await ask(vm, mock, "what happened", reply: "An answer.")
        let conversation = vm.currentConversation
        #expect(vm.topLayer == .answer)

        #expect(vm.handleEscapeKey())

        #expect(!vm.isQuickAIPresented)
        #expect(presenter.dismissals == 0, "the first Escape leaves the surface, not the window")
        #expect(vm.output == "An answer.", "the thread is kept")
        #expect(vm.currentConversation == conversation)
        #expect(!vm.launcherMatches.isEmpty, "root search shows its rows again")
        #expect(
            vm.estimatedWindowHeight == PanelSizing.panelHeight(
                errorMessage: nil,
                suggestionCount: vm.launcherMatches.count,
                showsFooter: true,
                launcherRowCount: vm.launcherMatches.count
            ),
            "root search measures its rows again"
        )
        #expect(vm.topLayer == .root)

        // The kept thread comes back with the next question.
        await mock.setResponses([StreamDelta(text: "A follow-up.", finishReason: "stop")])
        vm.input = "and then"
        #expect(vm.handleTab())
        await vm.tabSubmitTask?.value
        #expect(vm.isQuickAIPresented)
        #expect(vm.currentConversation?.id == conversation?.id)
        #expect(vm.conversationMessages.count == 4)

        #expect(vm.handleEscapeKey())
        #expect(vm.handleEscapeKey())
        #expect(presenter.dismissals == 1, "the second Escape in root search closes the window")
    }

    @Test func escapeWhileStreamingStops() {
        let vm = make()
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        vm.isStreaming = true
        vm.streamingStatus = "Thinking…"
        #expect(vm.isQuickAIPresented)
        #expect(vm.quickAIComposerAction == .init(label: "Stop", keys: ["esc"]))

        #expect(vm.handleEscapeKey())
        #expect(!vm.isStreaming)
        #expect(vm.isQuickAIPresented, "stopping keeps the surface")
        #expect(presenter.dismissals == 0)
    }

    @Test func escapeDuringTheWebSearchStopsTheAskBeforeTheModelIsCalled() async {
        let (vm, mock, search) = await makeSearching()
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter

        // Tab from root search, with the thread kept behind it.
        vm.closeQuickAI()
        vm.input = "search web raycast founder"
        #expect(vm.handleTab())
        let submit = vm.tabSubmitTask
        await search.waitUntilSearching()
        #expect(vm.topLayer == .streaming)
        #expect(vm.quickAIComposerAction == .init(label: "Stop", keys: ["esc"]))

        #expect(vm.handleEscapeKey())
        #expect(!vm.isStreaming)
        #expect(vm.isQuickAIPresented, "stopping keeps the surface")
        #expect(presenter.dismissals == 0)
        #expect(vm.tabSubmitTask == nil, "the submit in flight is cancelled with the ask")
        #expect(vm.pendingQuestion == nil)
        #expect(vm.webSearchNote == nil, "the search line was made for an answer that will not come")

        await search.release()
        await submit?.value
        #expect(await mock.sendCallCount == 1, "the stopped ask never reaches the model")
        #expect(vm.output.isEmpty)
        #expect(vm.conversationMessages.count == 2, "the question was never a turn")

        // Return in the composer takes the same path, and a Return after
        // the stop starts a fresh ask.
        vm.input = "search web raycast founder"
        vm.submitFromComposer()
        let second = vm.composerSubmitTask
        await search.waitUntilSearching()
        #expect(vm.handleEscapeKey())
        #expect(vm.composerSubmitTask == nil)
        await search.release()
        await second?.value
        #expect(await mock.sendCallCount == 1)

        vm.input = "search web raycast founder"
        vm.submitFromComposer()
        let third = vm.composerSubmitTask
        #expect(third != nil, "the composer takes a new Return after a stop")
        await search.waitUntilSearching()
        await search.release()
        await third?.value
        #expect(vm.composerSubmitTask == nil, "the cancelled submit did not clear the newer handle early")
        #expect(await mock.sendCallCount == 2)
        #expect(vm.output == "Thomas Paul Mann.")
    }

    @Test func theQuestionIsOnScreenWhileTheWebSearchRunsAndThePreviousAnswerIsNot() async {
        let (vm, mock, search) = await makeSearching()
        #expect(vm.output == "One.")

        vm.input = "search web raycast founder"
        vm.submitFromComposer()
        await search.waitUntilSearching()

        #expect(vm.isStreaming)
        #expect(vm.output.isEmpty, "the previous answer is not drawn live under a caret")
        #expect(vm.lastQuestion == "search web raycast founder")
        #expect(vm.pendingQuestion == "search web raycast founder", "the question is a pill before it is a turn")
        #expect(vm.conversationMessages.count == 2, "the user message joins the thread with the model call")
        #expect(vm.webSearchNote?.hasPrefix("Search web: ") == true)
        #expect(vm.streamingStatus == vm.webSearchNote)
        #expect(vm.quickAIDetachedAnswer == nil)

        await search.release()
        await vm.composerSubmitTask?.value
        #expect(await mock.sendCallCount == 2)
        #expect(vm.pendingQuestion == nil, "once a turn, the thread draws it")
        #expect(vm.conversationMessages.count == 4)
        #expect(vm.conversationMessages[2].content == "search web raycast founder")
        #expect(vm.output == "Thomas Paul Mann.")
        #expect(vm.webSearchNote == nil, "the finished line moved onto its answer")
        let line = vm.conversationMessages[3].tools.first
        #expect(line?.kind == .web)
        #expect(line?.summary.hasPrefix("Search web: ") == true, "the finished line stays with its answer, saved")
    }

    @Test func returnWaitsForTheStreamToEnd() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.isStreaming = true
        vm.input = "typed during the stream"
        await vm.submitResolvingFuzzyAlias()
        #expect(await mock.sendCallCount == 0, "Return is ignored until the stream ends")
        #expect(vm.input == "typed during the stream")
    }

    @Test func returnStillPicksInAChooserWhileTheStreamRuns() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "hello", reply: "Hi.")
        vm.isStreaming = true

        vm.openModelChooser(.change)
        #expect(vm.isModelChooserPresented)
        let other = vm.modelChooserOptions.first { $0.model != vm.activeModelID }!
        vm.modelChooserIndex = vm.modelChooserOptions.firstIndex(of: other)!
        await vm.submitResolvingFuzzyAlias()
        #expect(!vm.isModelChooserPresented, "Return picks the highlighted model")
        #expect(vm.activeModelID == other.model)
        #expect(await mock.sendCallCount == 1, "Change Model sends nothing")
        vm.cancel()
    }

    @Test func returnFromTheComposerKeepsOneHandleAndDropsASecondPress() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "One.", finishReason: "stop")])
        let vm = make(service: mock)
        vm.openQuickAI()
        vm.input = "one question"

        vm.submitFromComposer()
        let first = vm.composerSubmitTask
        #expect(first != nil, "the handle is kept for tests and against a second Return")
        vm.submitFromComposer()
        #expect(vm.composerSubmitTask == first, "a second Return while one runs is dropped")
        await first?.value
        #expect(vm.composerSubmitTask == nil)
        #expect(await mock.sendCallCount == 1)
        #expect(vm.output == "One.")
    }

    @Test func recentChatsFromAModeOrACatalogLeavesTheModeSoReturnAsks() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "first", reply: "One.")
        vm.history = [vm.currentConversation!]

        vm.enterInputMode(.renameChat(vm.currentConversation!.id))
        #expect(vm.inputMode != nil)
        #expect(!vm.isQuickAIPresented, "a mode owns the root row")
        vm.openRecentChats()
        #expect(vm.isRecentChatsPresented)
        #expect(vm.inputMode == nil, "the mode steps aside, as on Tab")
        vm.closeRecentChats()
        vm.input = "and then"
        #expect(vm.classifySubmit() == .prompt, "the composer's Return asks")

        vm.enterCatalog(.commands)
        #expect(vm.catalogScope != nil)
        vm.openRecentChats()
        #expect(vm.catalogScope == nil)
        #expect(vm.pendingQuickLinkID == nil)
        vm.closeRecentChats()
        vm.input = "and then"
        #expect(vm.classifySubmit() == .prompt)
    }

    // MARK: - Detached answers

    @Test func aLocalAnswerAskedOnTheSurfaceStaysInTheChat() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "first", reply: "One.")
        #expect(vm.quickAIDetachedAnswer == nil, "the last turn is the thread's own")

        // v1.5.0 (Phase A2): math asked in a chat stays in it, as its own
        // answer under its own pill; only root search answers inline.
        vm.input = "2+2"
        await vm.submit()
        #expect(vm.isQuickAIPresented, "the reader stays in the chat")
        #expect(vm.rootAnswer == nil, "root search's inline answer is for root search")
        #expect(vm.currentConversation?.messages.count == 2, "2+2 is not a turn")
        #expect(vm.output == "4")
        #expect(vm.quickAIDetachedAnswer == "4", "drawn after the thread, not as a turn")
        #expect(vm.pendingQuestion == "2+2", "under its own pill")
        #expect(vm.quickAIHeaderSubtitle == QuickViewModel.localAnswerSourceTitle)
        #expect(vm.input.isEmpty, "the field empties as it does for a model answer")
        #expect(vm.topLayer == .answer)
        #expect(await mock.sendCallCount == 1)

        // The next question is a turn of the same chat again.
        await ask(vm, mock, "and then", reply: "Two.")
        #expect(vm.conversationMessages.map(\.content) == ["first", "One.", "and then", "Two."])
        #expect(vm.quickAIHeaderSubtitle == vm.activeModelDisplay)
    }

    // MARK: - Recent Chats

    @Test func commandPIsOneColumnInsideTheSameWindow() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "first", reply: "One.")
        var older = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "older-model",
            messages: [
                QuickMessage(role: .user, content: "older"),
                QuickMessage(role: .assistant, content: "Older answer."),
            ]
        )
        // The rows are the Chats catalog's: pinned first, then newest first.
        older.updatedAt = Date(timeIntervalSinceNow: -3_600)
        vm.history = [vm.currentConversation!, older]

        #expect(vm.performShortcut(characters: "p", keyCode: 35, modifiers: [.command]))
        #expect(vm.isRecentChatsPresented)
        #expect(vm.isQuickAIPresented)
        #expect(vm.topLayer == .recentChats)
        #expect(vm.currentPanelWidth == House.Layout.panelWidth, "no rail beside the thread")
        #expect(vm.estimatedWindowHeight == House.Layout.quickAIHeight)
        #expect(vm.recentChatsIndex == 0)

        #expect(vm.quickAIComposerAction == .init(label: "Open", keys: ["↩"]), "↩ means one thing on the screen")

        vm.moveRecentChatsSelection(1)
        #expect(vm.recentChatsIndex == 1)
        vm.webSearchNote = "Search web: first and 2 more terms"
        await vm.submitResolvingFuzzyAlias()
        #expect(!vm.isRecentChatsPresented, "Return opens the chat in the thread")
        #expect(vm.currentConversation?.id == older.id)
        #expect(vm.output == "Older answer.")
        #expect(vm.quickAITitle == "Older")
        #expect(vm.activeModelDisplay == "older-model", "the header names the model that answers next")
        #expect(vm.webSearchNote == nil, "the tool line belongs to the answer it was made for")
        #expect(vm.quickAIComposerAction.label == "Paste Response")

        vm.openRecentChats()
        #expect(vm.handleEscapeKey())
        #expect(!vm.isRecentChatsPresented)
        #expect(vm.isQuickAIPresented, "Escape returns to the thread")
    }

    @Test func recentChatsAreTheChatsCatalogRowsPinnedFirst() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "first", reply: "One.")
        let pinned = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "deepseek-v4-pro",
            messages: [
                QuickMessage(role: .user, content: "older"),
                QuickMessage(role: .assistant, content: "Older answer."),
            ],
            isPinned: true
        )
        vm.history = [vm.currentConversation!, pinned]

        vm.openRecentChats()
        let rows = vm.recentChatItems
        #expect(rows.map(\.itemID) == vm.conversationItems.map(\.itemID), "the launcher's own chat rows")
        #expect(rows.first?.itemID == pinned.id.uuidString, "pinned first, as in the Chats catalog")
        #expect(rows.first?.kind == .conversation)
        #expect(rows.first?.detail.hasPrefix("1 question · ") == true, "count and time in the detail column")
        #expect(rows.first?.isPinned == true, "the row draws the pin glyph, not a Pinned prefix")
        #expect(vm.recentChatsIndex == 1, "the current chat is the highlighted row")

        vm.moveRecentChatsSelection(-1)
        #expect(vm.recentChatsIndex == 0)
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.currentConversation?.id == pinned.id, "Return opens the row under the highlight")
        #expect(!vm.isRecentChatsPresented)
    }

    @Test func theHeaderNamesTheVisionModelOnlyWhileAnImageIsAttached() {
        let vm = make()
        vm.openQuickAI()
        let text = vm.activeModelDisplay
        #expect(vm.activeModelID == InferenceProvider.deepSeekDefaultModel)
        #expect(text == "DeepSeek V4.1 Flash", "the header shows the display name, not the id")
        vm.pendingImage = QuickImageAttachment(data: Data([1, 2, 3]), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1)
        #expect(vm.activeModelDisplay.contains("DeepSeek V4.1 Flash"), "images go to the same flash model")
        #expect(!vm.activeModelDisplay.contains(InferenceProvider.deepSeekVisionModel))
        vm.clearAttachments()
        #expect(vm.activeModelDisplay == text)
    }

    // MARK: - Model migration

    /// Settings as v1.4.0 left them: DeepSeek on the retired flash aliases.
    private func legacyDeepSeekJSON(version: Int, selected: String, quickAIModel: String,
                                    visionModel: String, promptModel: String) -> String {
        let deepSeek = InferenceProvider.deepSeekID.uuidString
        return """
        {"configurationVersion":\(version),
         "selectedProviderID":"\(deepSeek)",
         "quickAIProviderID":"\(deepSeek)",
         "quickAIModel":"\(quickAIModel)",
         "visionProviderID":"\(deepSeek)",
         "visionModel":"\(visionModel)",
         "savedPrompts":[{"id":"\(UUID().uuidString)","name":"Fix","alias":"fix","prompt":"Fix: {input}",
           "providerID":"\(deepSeek)","model":"\(promptModel)","outputBehavior":"showInOverlay"}],
         "providers":[{"id":"\(deepSeek)","name":"DeepSeek API","kind":"openAICompatible","location":"cloud",
           "baseURL":"https://api.deepseek.com",
           "models":["deepseek-v4-flash","deepseek-v4-pro","deepseek-v4-flash-vision-exp"],
           "selectedModel":"\(selected)","discovery":"openAI","isBuiltIn":true}]}
        """
    }

    @Test func everyRetiredFlashIdMovesToDeepSeekFlash() throws {
        for version in [22, 23] {
            let json = legacyDeepSeekJSON(
                version: version,
                selected: "deepseek-v4-flash",
                quickAIModel: "deepseek-v4-flash-vision-exp",
                visionModel: "deepseek-v4-flash-vision-exp",
                promptModel: "deepseek-v4-flash"
            )
            let settings = try JSONDecoder().decode(QuickSettings.self, from: Data(json.utf8))
            #expect(settings.configurationVersion == 25)
            let provider = try #require(settings.providers.first { $0.id == InferenceProvider.deepSeekID })
            #expect(provider.selectedModel == "deepseek-flash")
            #expect(provider.models == ["deepseek-flash", "deepseek-v4-pro"], "the aliases leave the list")
            #expect(settings.quickAIModel == "deepseek-flash")
            #expect(settings.visionModel == "deepseek-flash", "images go to the same model")
            #expect(settings.savedPrompts.first?.model == "deepseek-flash")
        }
    }

    @Test func anExplicitOtherChoiceStays() throws {
        let json = legacyDeepSeekJSON(
            version: 23,
            selected: "deepseek-v4-pro",
            quickAIModel: "deepseek-v4-pro",
            visionModel: "deepseek-v4-pro",
            promptModel: "deepseek-v4-pro"
        )
        let settings = try JSONDecoder().decode(QuickSettings.self, from: Data(json.utf8))
        let provider = try #require(settings.providers.first { $0.id == InferenceProvider.deepSeekID })
        #expect(provider.selectedModel == "deepseek-v4-pro")
        #expect(settings.quickAIModel == "deepseek-v4-pro")
        #expect(settings.visionModel == "deepseek-v4-pro")
        #expect(settings.savedPrompts.first?.model == "deepseek-v4-pro")
    }

    @Test func freshSettingsUseDeepSeekFlashForTextAndImages() {
        let settings = QuickSettings()
        let provider = InferenceProvider.defaults.first { $0.id == InferenceProvider.deepSeekID }!
        #expect(provider.selectedModel == "deepseek-flash")
        #expect(provider.models == ["deepseek-flash", "deepseek-v4-pro"])
        #expect(settings.visionModel == "deepseek-flash")
        #expect(ModelProfile.displayName(forModelID: "deepseek-flash") == "DeepSeek V4.1 Flash")
    }

    @Test func theRetiredAliasesShipOffInManageModels() {
        let store = ModelPreferenceStore(fileURL: nil)
        let provider = InferenceProvider.defaults.first { $0.id == InferenceProvider.deepSeekID }!
        for alias in InferenceProvider.legacyDeepSeekFlashModels {
            #expect(!store.isEnabled(providerID: provider.id, model: alias))
        }
        #expect(store.isEnabled(providerID: provider.id, model: "deepseek-flash"))
        let visible = ModelCatalogService.visibleModels(
            for: provider,
            currentModel: provider.selectedModel,
            preferences: store
        )
        #expect(visible.contains("deepseek-flash"))
        #expect(visible.allSatisfy { !InferenceProvider.legacyDeepSeekFlashModels.contains($0) })
    }

    @Test func aFreshInstallDefaultsToTheFlashTextModel() {
        let settings = QuickSettings()
        #expect(settings.selectedModel == InferenceProvider.deepSeekDefaultModel)
        let vm = make()
        #expect(vm.activeModelID == InferenceProvider.deepSeekDefaultModel)
        #expect(vm.activeModelDisplay == ModelProfile.displayName(forModelID: InferenceProvider.deepSeekDefaultModel))
    }

    @Test func anUncuratedIdIsItsOwnDisplayName() {
        #expect(ModelProfile.displayName(forModelID: "older-model") == "older-model")
        #expect(ModelProfile.displayName(forModelID: "deepseek-v4-pro") == "DeepSeek V4 Pro")
        #expect(ModelProfile.displayName(forModelID: "DEEPSEEK-FLASH") == "DeepSeek V4.1 Flash", "ids come back from servers in any case")
        #expect(ModelProfile.displayName(forModelID: "") == "")
    }

    // MARK: - Ask User Question setting

    @Test func theAskToolIsAbsentUnlessTheSettingIsOn() throws {
        let off = make()
        #expect(!off.settings.quickAIClarifyingQuestionsEnabled, "off by default")
        let provider = try #require(off.settings.providers.first { $0.id == InferenceProvider.deepSeekID })
        off.service = nil
        let offService = try #require(
            off.makeService(provider: provider, model: provider.selectedModel) as? OpenAICompatibleService
        )
        #expect(!offService.offersAskUserQuestion)

        let on = make { $0.quickAIClarifyingQuestionsEnabled = true }
        on.service = nil
        let onService = try #require(
            on.makeService(provider: provider, model: provider.selectedModel) as? OpenAICompatibleService
        )
        #expect(onService.offersAskUserQuestion)
    }

    @Test func theAskToolDescriptionTellsTheModelWhenNotToAsk() throws {
        let function = try #require(
            OpenAICompatibleService.askUserQuestionToolDefinition["function"] as? [String: Any]
        )
        let description = try #require(function["description"] as? String)
        #expect(description.contains("only when"))
        #expect(description.contains("one reasonable reading"))
        #expect(description.contains("Do not ask which kind of help is wanted."))
        #expect(!description.contains("Prefer this over guessing"))
    }

    @Test func theSettingRoundTrips() throws {
        var settings = QuickSettings()
        settings.quickAIClarifyingQuestionsEnabled = true
        let back = try JSONDecoder().decode(QuickSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.quickAIClarifyingQuestionsEnabled)
        let legacy = try JSONDecoder().decode(QuickSettings.self, from: Data(#"{"configurationVersion":22}"#.utf8))
        #expect(!legacy.quickAIClarifyingQuestionsEnabled)
    }
}
