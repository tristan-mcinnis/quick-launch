// QuickAIThreadTests — the medium Quick AI fixes of v1.5.0 (plan Phase A2,
// docs/ai-chat-plan-20260911.md section 3): local answers back in root search
// and a source name for command and Vault Search answers (16), ↑ recall and
// the thread's own scroll keys (5), Stop keeps the turn and ⌘R asks it again
// (3), the thread follows the bottom only when the reader is there (4), a
// provider error stays with its question with Retry (11), Return while
// streaming queues one follow-up (13), and ⌘K in Recent Chats acts on the
// highlighted row (14).
//
// The real key events for ⌘↑ ⌘↓ ⌥↑, ⌘R, ⌘K, and ⇧⌘P are in
// QuickAIKeyboardTests.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Quick AI thread", .serialized)
@MainActor
struct QuickAIThreadTests {

    // MARK: - Fixtures

    private func make(
        service: (any QuickService)? = MockQuickService(),
        pasteboard: FakePasteboard = FakePasteboard(),
        configure: (inout QuickSettings) -> Void = { _ in }
    ) -> QuickViewModel {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        configure(&settings)
        return QuickViewModel(settings: settings, service: service, pasteboard: pasteboard)
    }

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, reply: String) async {
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    /// Starts an ask on a gated model and returns once its first words are
    /// on screen and the stream is held open.
    private func streaming(
        _ question: String = "tell me about Lima",
        head: String = "Lima is the capital",
        tail: String = " of Peru.",
        configure: (inout QuickSettings) -> Void = { _ in }
    ) async -> (QuickViewModel, GatedQuickService, Task<Void, Never>) {
        let gated = GatedQuickService(head: head, tail: tail)
        let vm = make(service: gated, configure: configure)
        vm.openQuickAI()
        vm.input = question
        let submit = Task { await vm.submit() }
        await gated.waitUntilHolding()
        _ = await waitFor { vm.output == head }
        return (vm, gated, submit)
    }

    /// Starts a `search web …` ask whose search has returned and whose model
    /// call is held open after sending `head`.
    private func webStreaming(
        head: String = ""
    ) async -> (QuickViewModel, GatedQuickService, GatedWebSearchService, Task<Void, Never>) {
        let search = GatedWebSearchService(result: "## [1] Raycast\nURL: https://www.raycast.com/about")
        let gated = GatedQuickService(head: head)
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: gated, webSearchService: search)
        vm.openQuickAI()
        vm.input = "search web raycast founder"
        let submit = Task { await vm.submit() }
        await search.waitUntilSearching()
        await search.release()
        await gated.waitUntilHolding()
        return (vm, gated, search, submit)
    }

    /// ⌘R on a web answer: the search runs again, then the model answers.
    /// Needs the question in the thread (else nothing searches, and the
    /// wait would never end).
    private func reaskWebAnswer(_ vm: QuickViewModel, _ search: GatedWebSearchService) async throws {
        try #require(vm.conversationMessages.last?.role == .user, "no turn for ⌘R to ask again")
        let reask = Task { await vm.regenerateLastAnswer() }
        await search.waitUntilSearching()
        await search.release()
        await reask.value
    }

    private func waitFor(
        _ timeout: Duration = .seconds(15),
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        // Generous on purpose: this box may be running several builds and
        // suites at once, and a correct test that waits longer costs nothing.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        if await condition() { return true }
        // Say the timeout out loud. A silent give-up lets the caller's own
        // assertions report the symptom instead of the wait that failed.
        Issue.record("waitFor timed out after \(timeout)")
        return false
    }

    private func chat(_ question: String, _ answer: String, pinned: Bool = false) -> QuickConversation {
        QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: InferenceProvider.deepSeekDefaultModel,
            messages: [
                QuickMessage(role: .user, content: question),
                QuickMessage(role: .assistant, content: answer),
            ],
            isPinned: pinned
        )
    }

    // MARK: - 16. Local answers in root search; sources in the header

    @Test func twoPlusTwoShowsInlineInRootAndNeverOpensTheSurface() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        vm.input = "2+2"

        #expect(vm.handleTab())
        #expect(!vm.isQuickAIPresented, "Tab never opens Quick AI for math")
        #expect(vm.tabSubmitTask == nil, "nothing is sent")
        #expect(vm.rootAnswer == QuickViewModel.RootAnswer(question: "2+2", answer: "4"))
        #expect(vm.output.isEmpty)
        #expect(vm.input.isEmpty)
        #expect(vm.launcherMatches.isEmpty, "the answer stands in for the rows, as in v1.3.0")
        #expect(vm.footerContext == QuickViewModel.rootAnswerContext)
        #expect(vm.footerHints.map(\.label) == ["Copy", "Clear"])
        #expect(vm.currentPanelWidth == PanelSizing.panelWidth)
        #expect(vm.estimatedWindowHeight > PanelSizing.inputHeight + PanelSizing.footerHeight,
                "the window grows for the answer block")
        #expect(await mock.sendCallCount == 0)

        // Return copies it, as the inline answer row does, and closes.
        #expect(vm.classifySubmit() == .rootAnswerIdle)
        await vm.submitResolvingFuzzyAlias()
        #expect((vm.pasteboard as? FakePasteboard)?.string == "4")
        #expect(presenter.dismissals == 1)
        #expect(vm.rootAnswer == nil)
    }

    @Test func mathFromTheComposerStaysInTheChat() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock) { $0.historyEnabled = true }
        vm.openQuickAI()
        await ask(vm, mock, "what is the capital of Peru", reply: "Lima.")
        let before = try #require(vm.currentConversation)

        vm.input = "2+2"
        await vm.submitResolvingFuzzyAlias()

        #expect(vm.isQuickAIPresented, "math asked in a chat never leaves it")
        #expect(vm.rootAnswer == nil)
        #expect(vm.conversationMessages == before.messages, "a local answer never joins a chat")
        #expect(vm.history.first?.messages == before.messages, "nor its history")
        #expect(vm.quickAIDetachedAnswer == "4", "its own answer after the thread")
        #expect(vm.pendingQuestion == "2+2")
        #expect(vm.answerSourceTitle == "Local answer", "the header names the source")
        #expect(vm.input.isEmpty)
        #expect(await mock.sendCallCount == 1, "the model was not asked")
    }

    @Test func theAskAIRowWithMathStaysInRoot() async {
        let vm = make()
        await vm.performLauncherItem(vm.askAIItem(query: "7*6"))
        #expect(!vm.isQuickAIPresented)
        #expect(vm.rootAnswer?.answer == "42")
    }

    @Test func aKeystrokeOrEscapeClearsTheRootAnswer() async {
        let vm = make()
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        vm.input = "2+2"
        #expect(vm.handleTab())
        #expect(vm.topLayer == .localAnswer)

        // Escape clears the answer first; the next Escape hides the overlay.
        #expect(vm.handleEscapeKey())
        #expect(vm.rootAnswer == nil)
        #expect(presenter.dismissals == 0)
        #expect(!vm.launcherMatches.isEmpty, "the rows come back")

        vm.input = "2+2"
        #expect(vm.handleTab())
        vm.input = "s"
        vm.rootInputDidChange(vm.input)
        #expect(vm.rootAnswer == nil, "typing starts a new search")
    }

    @Test func mathThatCannotBeComputedStaysInRootWithItsError() {
        let vm = make()
        vm.input = "1/0"
        #expect(vm.handleTab())
        #expect(!vm.isQuickAIPresented)
        #expect(vm.errorMessage?.hasPrefix("Math error") == true)
        #expect(vm.input == "1/0", "the expression stays to fix")
    }

    @Test func aCommandActionsHeaderNamesTheCommand() async {
        let mock = MockQuickService()
        let vm = make(service: mock) { settings in
            settings.historyEnabled = true
            settings.savedPrompts.append(SavedPrompt(
                name: "Echo It",
                alias: "echo-it",
                prompt: "{input}",
                commandExecutable: "/bin/echo",
                commandArguments: ["{input}"]
            ))
        }
        await ask(vm, mock, "first", reply: "One.")
        let before = vm.currentConversation

        vm.input = "/echo-it hello"
        await vm.submit()

        #expect(vm.isQuickAIPresented)
        #expect(vm.output.contains("hello"))
        #expect(vm.quickAIHeaderSubtitle == "Echo It", "the header names the command, not the model")
        #expect(vm.answerSourceTitle == "Echo It")
        #expect(vm.pendingQuestion == "/echo-it hello", "the command's output draws under its own pill")
        #expect(vm.quickAIDetachedAnswer?.contains("hello") == true, "not a turn of the chat")
        #expect(vm.currentConversation == before, "the chat is untouched")
        #expect(vm.history.count == 1)
        #expect(vm.history.first?.messages.map(\.content) == ["first", "One."], "never a model turn in history")
        #expect(await mock.sendCallCount == 1, "the command never reached the model")

        // The next model answer names the model again.
        await ask(vm, mock, "and then", reply: "Two.")
        #expect(vm.answerSourceTitle == nil)
        #expect(vm.quickAIHeaderSubtitle == vm.activeModelDisplay)
    }

    @Test func aVaultSearchHeaderNamesVaultSearchAndItsMode() async {
        let vault = ThreadVaultSearchService()
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), vaultSearchService: vault)
        vm.enterInputMode(.vaultSearch(.current))
        vm.input = "Acme Launch where do we stand?"

        #expect(await vm.submitInputMode())
        #expect(vm.isQuickAIPresented)
        #expect(vm.output == "Vault result")
        #expect(vm.quickAIHeaderSubtitle == "Vault Search · Current Project")
        #expect(vm.pendingQuestion == "Acme Launch where do we stand?")
        #expect(vm.conversationMessages.isEmpty)
        #expect(vm.history.isEmpty, "a Vault Search is not a chat, as in v1.3.0")
    }

    // MARK: - 5. ↑ recall, and the thread's own scroll keys

    @Test func upOnAnEmptyComposerRecallsTheLastQuestion() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "what is the capital of Peru", reply: "Lima.")
        await ask(vm, mock, "and its population", reply: "About ten million.")
        vm.history = [vm.currentConversation!, chat("older", "Older.")]
        let chatID = vm.currentConversation?.id

        #expect(vm.handleComposerArrow(1), "↓ is taken, and does nothing")
        #expect(vm.input.isEmpty)
        #expect(vm.currentConversation?.id == chatID, "↓ no longer switches chats")

        #expect(vm.handleComposerArrow(-1))
        #expect(vm.input == "and its population", "↑ puts the last question back")
        #expect(vm.currentConversation?.id == chatID, "↑ no longer switches chats")

        #expect(!vm.handleComposerArrow(-1), "with text in the field the keys are the field's")
    }

    @Test func pageKeysAndTheirArrowFormsScrollTheThread() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "hello", reply: "Hi.")

        #expect(vm.handleThreadKey(.pageUp, command: false, option: false))
        #expect(vm.threadScrollRequest?.target == .pageUp)
        #expect(!vm.isThreadFollowingBottom, "reading up stops following at once")
        #expect(vm.handleThreadKey(.pageDown, command: false, option: false))
        #expect(vm.threadScrollRequest?.target == .pageDown)
        #expect(vm.handleThreadKey(.up, command: false, option: true))
        #expect(vm.threadScrollRequest?.target == .pageUp, "⌥↑ is a page up")
        #expect(vm.handleThreadKey(.down, command: false, option: true))
        #expect(vm.threadScrollRequest?.target == .pageDown, "⌥↓ is a page down")
        #expect(vm.handleThreadKey(.up, command: true, option: false))
        #expect(vm.threadScrollRequest?.target == .top, "⌘↑ jumps to the top")
        #expect(vm.handleThreadKey(.down, command: true, option: false))
        #expect(vm.threadScrollRequest?.target == .bottom, "⌘↓ jumps to the bottom")
        #expect(vm.isThreadFollowingBottom)
        #expect(!vm.handleThreadKey(.up, command: false, option: false), "a plain ↑ is not a scroll key")

        let revision = vm.threadScrollRequest?.revision ?? 0
        vm.handleThreadKey(.down, command: true, option: false)
        #expect(vm.threadScrollRequest?.revision == revision + 1, "asking twice scrolls twice")
    }

    @Test func theScrollKeysLeaveListsAndChoosersAlone() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "hello", reply: "Hi.")
        vm.history = [vm.currentConversation!, chat("older", "Older.")]

        vm.openRecentChats()
        #expect(!vm.handleThreadKey(.pageDown, command: false, option: false))
        let highlighted = vm.recentChatsIndex
        vm.moveRecentChatsSelection(1)
        #expect(vm.recentChatsIndex != highlighted, "↑↓ keep moving the Recent Chats list")
        vm.closeRecentChats()

        vm.isModelChooserPresented = true
        #expect(!vm.handleThreadKey(.down, command: true, option: false), "the chooser keeps its keys")
        vm.isModelChooserPresented = false

        vm.closeQuickAI()
        #expect(!vm.handleThreadKey(.pageDown, command: false, option: false), "root search has no thread")
        #expect(!vm.handleComposerArrow(-1), "root search's ↑ moves its rows")
    }

    // MARK: - 3. Stop keeps the turn; ⌘R asks it again

    @Test func stopKeepsTheQuestionAndThePartialAnswer() async {
        let (vm, gated, submit) = await streaming(configure: { $0.historyEnabled = true })
        #expect(vm.isStreaming)

        vm.cancel()
        await submit.value

        #expect(!vm.isStreaming)
        #expect(vm.conversationMessages.map(\.role) == [.user, .assistant])
        #expect(vm.conversationMessages.map(\.content) == ["tell me about Lima", "Lima is the capital"],
                "the question stays, and what arrived is its answer")
        #expect(vm.output == "Lima is the capital")
        #expect(vm.quickAIDetachedAnswer == nil, "the partial answer is a turn, not a loose answer")
        #expect(vm.input.isEmpty, "the question stays in the thread, not back in the field")
        #expect(vm.history.first?.messages.count == 2, "a stopped answer is saved like any other")

        // The held stream ending late changes nothing.
        gated.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(vm.conversationMessages.map(\.content) == ["tell me about Lima", "Lima is the capital"])
    }

    @Test func stopThenCommandRAsksTheSameTurnAgain() async {
        let (vm, gated, submit) = await streaming()
        vm.cancel()
        await submit.value
        #expect(vm.resultActions.contains(.regenerate))

        await vm.regenerateLastAnswer()

        #expect(vm.conversationMessages.map(\.content) == ["tell me about Lima", "The follow-up answer."],
                "⌘R replaced the stopped answer of the same question")
        let sent = gated.sentMessages
        #expect(sent.count == 2)
        #expect(sent.last?.map(\.content) == ["tell me about Lima"], "the stopped turn was asked again")
    }

    @Test func stopBeforeAnyTextKeepsTheQuestionAndCommandRStillWorks() async {
        let (vm, gated, submit) = await streaming(head: "")
        vm.cancel()
        await submit.value
        #expect(vm.conversationMessages.map(\.content) == ["tell me about Lima"])
        #expect(vm.hasUnansweredTurn)
        #expect(vm.output.isEmpty)
        #expect(vm.resultActions.contains(.regenerate), "⌘R is offered with no answer on screen")
        #expect(!vm.resultActions.contains(.copy), "nothing to copy")

        await vm.regenerateLastAnswer()
        #expect(vm.conversationMessages.map(\.content) == ["tell me about Lima", "The follow-up answer."])
        #expect(gated.sendCallCount == 2)
    }

    @Test func aStopBeforeAnyTextOnAWebAnswerKeepsTheTurn() async throws {
        let (vm, gated, search, submit) = await webStreaming()
        vm.cancel()
        await submit.value

        #expect(vm.conversationMessages.map(\.content) == ["search web raycast founder"],
                "the search ended, so the question is a turn and stays one")
        #expect(vm.hasUnansweredTurn)
        #expect(vm.output.isEmpty, "no search results in place of the stopped answer")
        #expect(vm.errorMessage == nil, "no model error the user never had")
        #expect(vm.input.isEmpty)

        try await reaskWebAnswer(vm, search)
        #expect(vm.conversationMessages.map(\.content) == ["search web raycast founder", "The follow-up answer."],
                "⌘R asked that same question again")
        #expect(gated.sendCallCount == 2)
    }

    @Test func aProviderErrorOnAWebAnswerKeepsTheTurnWithRetry() async throws {
        let (vm, gated, search, submit) = await webStreaming()
        gated.fail()
        await submit.value

        let failed = try #require(vm.conversationMessages.last)
        #expect(vm.conversationMessages.map(\.content) == ["search web raycast founder"])
        #expect(vm.threadError?.messageID == failed.id, "the error is drawn under the question")
        #expect(vm.errorMessage == nil, "not the search-results fallback line")
        #expect(vm.output.isEmpty)
        #expect(vm.resultActions.contains(.regenerate), "Retry ⌘R")

        try await reaskWebAnswer(vm, search)
        #expect(vm.threadError == nil)
        #expect(vm.conversationMessages.map(\.content) == ["search web raycast founder", "The follow-up answer."])
        #expect(gated.sendCallCount == 2)
    }

    @Test func commandRPastTheNewChatIntervalStaysInTheSameChat() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "first", reply: "One.")
        await ask(vm, mock, "follow up q", reply: "Two.")
        let chatID = try #require(vm.currentConversation?.id)
        // Last touched ten minutes ago: past the default five-minute interval
        // after which a new question starts a new chat.
        #expect(vm.settings.newChatInterval == .fiveMinutes)
        vm.currentConversation?.updatedAt = Date().addingTimeInterval(-600)
        vm.input = "half typed"
        await mock.setResponses([StreamDelta(text: "Two again.", finishReason: "stop")])

        await vm.regenerateLastAnswer()

        #expect(vm.currentConversation?.id == chatID, "⌘R stays in the chat it asks again")
        #expect(vm.conversationMessages.map(\.content) == ["first", "One.", "follow up q", "Two again."])
        #expect(await mock.lastMessages.map(\.content) == ["first", "One.", "follow up q"],
                "the earlier turns went with it")
        #expect(vm.input == "half typed", "the composer keeps what was typed")
    }

    @Test func aTransformDuringAStreamStopsTheAnswerFirst() async throws {
        let (vm, gated, submit) = await streaming(configure: { $0.historyEnabled = true })
        vm.launchSelection = QuickViewModel.LaunchSelection(text: "A long line of selected words.", appName: "Notes")
        let first = try #require(vm.chipTransformOptions.first)
        guard case .saved = first.kind else {
            Issue.record("the first transform is a saved prompt")
            return
        }

        vm.openTransformChooser()
        #expect(!vm.isTransformChooserPresented, "the chooser waits for the answer to end")

        // Reached anyway (a chooser already open, or the chip menu): the
        // answer stops first and keeps what arrived, then the transform runs.
        vm.isTransformChooserPresented = true
        vm.transformChooserIndex = 0
        await vm.runTransformChooserSelection()
        await submit.value

        #expect(gated.sendCallCount == 2, "one model request at a time")
        #expect(vm.history.contains { $0.messages.map(\.content) == ["tell me about Lima", "Lima is the capital"] },
                "the stopped answer is kept")
        #expect(vm.output == "The follow-up answer.", "no text of the first answer leaks into the second")
        #expect(!vm.isStreaming)
    }

    @Test func aStopDuringTheWebSearchStillPutsTheQuestionBack() async {
        let search = GatedWebSearchService(result: "## [1] Raycast\nURL: https://www.raycast.com/about")
        let mock = MockQuickService()
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: mock, webSearchService: search)
        vm.input = "search web raycast founder"
        #expect(vm.handleTab())
        let submit = vm.tabSubmitTask
        await search.waitUntilSearching()

        vm.cancel()
        #expect(vm.input == "search web raycast founder", "the question comes back")
        #expect(vm.conversationMessages.isEmpty, "it never became a turn")
        await search.release()
        await submit?.value
        #expect(await mock.sendCallCount == 0)
    }

    // MARK: - 4. Follow the bottom only when the reader is there

    @Test func theThreadFollowsTheBottomOnlyNearIt() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "hello", reply: "Hi.")
        #expect(vm.isThreadFollowingBottom)
        #expect(!vm.showsJumpToLatest)

        vm.threadDidScroll(distanceFromBottom: QuickViewModel.threadFollowThreshold)
        #expect(vm.isThreadFollowingBottom, "within about 40 pt still follows")
        vm.threadDidScroll(distanceFromBottom: QuickViewModel.threadFollowThreshold + 1)
        #expect(!vm.isThreadFollowingBottom, "further up the reader stays put")
        #expect(vm.showsJumpToLatest, "the Latest chip shows")

        // The chip (and ⌘↓) goes back to the bottom and follows it.
        vm.scrollThread(.bottom)
        #expect(vm.isThreadFollowingBottom)
        #expect(vm.threadScrollRequest?.target == .bottom)
        #expect(!vm.showsJumpToLatest)

        // A new question follows the bottom again, wherever the reader was.
        vm.threadDidScroll(distanceFromBottom: 500)
        await ask(vm, mock, "and then", reply: "Then this.")
        #expect(vm.isThreadFollowingBottom)
    }

    @Test func showMoreStopsFollowingSoAStreamDoesNotPullTheReaderBack() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let long = (1...14).map { "line \($0) of the notes I pasted in" }.joined(separator: "\n")
        await ask(vm, mock, long, reply: "Short.")
        let id = try #require(vm.keyboardToggleMessageID)
        vm.toggleTranscriptMessage(id)
        #expect(vm.threadScrollRequest?.target == .messageTop(id))
        #expect(!vm.isThreadFollowingBottom)
    }

    // MARK: - 11. A provider error stays with its question

    @Test func aProviderErrorKeepsTheTurnWithRetry() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "first", reply: "One.")
        await mock.setShouldThrow(true)
        vm.input = "second"
        await vm.submit()

        let failed = try #require(vm.conversationMessages.last)
        #expect(failed.role == .user && failed.content == "second", "the question stays a turn")
        #expect(vm.threadError?.messageID == failed.id, "the error is drawn under that question")
        #expect(vm.errorMessage == nil, "not on the bottom line")
        #expect(vm.input.isEmpty)
        #expect(vm.resultActions.contains(.regenerate), "Retry ⌘R")

        await mock.setShouldThrow(false)
        await mock.setResponses([StreamDelta(text: "Two.", finishReason: "stop")])
        vm.retryFailedTurn()
        await vm.retryTask?.value
        #expect(vm.threadError == nil)
        #expect(vm.conversationMessages.map(\.content) == ["first", "One.", "second", "Two."])
    }

    @Test func aNewQuestionAfterAnErrorLeavesTheFailedOneOutOfTheRequest() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "first", reply: "One.")
        await mock.setShouldThrow(true)
        vm.input = "failed one"
        await vm.submit()
        await mock.setShouldThrow(false)
        await ask(vm, mock, "a new one", reply: "Three.")

        #expect(vm.conversationMessages.map(\.content) == ["first", "One.", "failed one", "a new one", "Three."],
                "the failed question stays in the thread")
        #expect(await mock.lastMessages.map(\.content) == ["first", "One.", "a new one"],
                "the model gets alternating turns")
        #expect(vm.threadError == nil, "the error went with the new question")
    }

    @Test func errorsThatBelongToNoTurnKeepTheBottomLine() async {
        let vm = QuickViewModel(service: nil)
        vm.settings.historyEnabled = false
        vm.apiKeyProvider = { _ in nil }
        vm.openQuickAI()
        vm.input = "hello"
        await vm.submit()
        #expect(vm.errorMessage?.contains("needs an API key") == true)
        #expect(vm.threadError == nil)
        #expect(vm.input == "hello")
    }

    @Test func commandROnAnUnavailableProviderLeavesTheComposerAlone() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "first", reply: "One.")
        // The endpoint breaks: the provider has a key but no usable URL.
        vm.service = nil
        vm.apiKeyProvider = { _ in "test-key" }
        let index = try #require(vm.settings.providers.firstIndex { $0.id == vm.activeProvider?.id })
        vm.settings.providers[index].baseURL = ""
        vm.input = "half typed"

        await vm.regenerateLastAnswer()

        #expect(vm.errorMessage?.contains("not available") == true)
        #expect(vm.input == "half typed", "the old question never lands on what was typed")
        #expect(vm.pendingImages.isEmpty, "nothing is attached")
        #expect(vm.conversationMessages.map(\.content) == ["first", "One."], "the thread is as it was")
        #expect(vm.output == "One.")
    }

    @Test func commandRThatCannotAskLeavesTheThreadAsItWas() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "first", reply: "One.")
        // The provider loses its key: the ask cannot go out.
        vm.service = nil
        vm.apiKeyProvider = { _ in nil }
        vm.input = "half typed"

        await vm.regenerateLastAnswer()

        #expect(vm.conversationMessages.map(\.content) == ["first", "One."], "nothing was lost")
        #expect(vm.output == "One.")
        #expect(vm.errorMessage?.contains("needs an API key") == true)
        #expect(vm.input == "half typed", "the composer keeps what was typed")
    }

    // MARK: - 13. Return while streaming queues one follow-up

    @Test func returnWhileStreamingQueuesAndSendsWhenTheStreamEnds() async {
        let (vm, gated, submit) = await streaming()
        vm.input = "and its population?"
        #expect(vm.quickAIComposerAction.label == "Stop")

        vm.submitFromComposer()
        await vm.streamingReturnTask?.value
        #expect(vm.isFollowUpQueued)
        #expect(vm.input == "and its population?", "the queued text waits in the field")
        #expect(vm.quickAIComposerAction == .init(label: "Queued", keys: ["↩"]))
        #expect(gated.sendCallCount == 1, "nothing is sent while the answer streams")

        gated.release()
        await submit.value

        #expect(!vm.isFollowUpQueued)
        #expect(vm.input.isEmpty)
        #expect(vm.conversationMessages.map(\.content) == [
            "tell me about Lima", "Lima is the capital of Peru.",
            "and its population?", "The follow-up answer.",
        ])
        #expect(gated.sendCallCount == 2)
    }

    @Test func escapeWhileQueuedStopsAndKeepsTheTextUnsent() async {
        let (vm, gated, submit) = await streaming()
        vm.input = "and its population?"
        vm.submitFromComposer()
        await vm.streamingReturnTask?.value
        #expect(vm.isFollowUpQueued)

        #expect(vm.handleEscapeKey())
        await submit.value

        #expect(!vm.isStreaming)
        #expect(!vm.isFollowUpQueued)
        #expect(vm.input == "and its population?", "the queued text stays in the composer")
        #expect(vm.conversationMessages.map(\.content) == ["tell me about Lima", "Lima is the capital"])
        #expect(vm.isQuickAIPresented)
        gated.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(gated.sendCallCount == 1, "a stopped stream never sends the queued text")

        // ⌘R now asks the stopped turn again and leaves the typed text alone.
        await vm.regenerateLastAnswer()
        #expect(vm.input == "and its population?")
        #expect(vm.conversationMessages.map(\.content) == ["tell me about Lima", "The follow-up answer."])
    }

    @Test func clearingTheQueuedTextUnqueuesIt() async {
        let (vm, gated, submit) = await streaming()
        vm.input = "and its population?"
        vm.submitFromComposer()
        await vm.streamingReturnTask?.value
        vm.input = ""
        vm.quickAIComposerDidChange("")
        #expect(!vm.isFollowUpQueued)
        #expect(vm.quickAIComposerAction.label == "Stop")
        gated.release()
        await submit.value
        #expect(gated.sendCallCount == 1)
    }

    @Test func aProviderErrorDropsTheQueueAndKeepsTheText() async {
        let (vm, gated, submit) = await streaming()
        vm.input = "and its population?"
        vm.submitFromComposer()
        await vm.streamingReturnTask?.value
        gated.fail()
        await submit.value
        #expect(vm.threadError != nil)
        #expect(!vm.isFollowUpQueued)
        #expect(vm.input == "and its population?")
        #expect(gated.sendCallCount == 1)
    }

    @Test func returnPicksInAChooserDuringAStreamTheComposerStarted() async throws {
        let gated = GatedQuickService(head: "Lima is")
        let vm = make(service: gated)
        vm.openQuickAI()
        vm.input = "tell me about Lima"
        vm.submitFromComposer()
        let started = try #require(vm.composerSubmitTask, "the composer's own submit is in flight")
        await gated.waitUntilHolding()
        _ = await waitFor { vm.output == "Lima is" }

        vm.modelChooserOptions = [
            ModelChooserOption(providerID: InferenceProvider.deepSeekID, providerName: "DeepSeek API", model: "deepseek-v4-pro"),
        ]
        vm.modelChooserIndex = 0
        vm.modelChooserPurpose = .change
        vm.isModelChooserPresented = true
        vm.submitFromComposer()
        await vm.streamingReturnTask?.value

        #expect(!vm.isModelChooserPresented, "Return picked in the chooser")
        #expect(vm.activeModelID == "deepseek-v4-pro")
        #expect(vm.isStreaming, "the answer keeps streaming")
        gated.release()
        await started.value
    }

    @Test func aQueuedFollowUpWaitsForAnOpenChooserAndGoesWhenItCloses() async {
        let (vm, gated, submit) = await streaming()
        vm.input = "and its population?"
        vm.submitFromComposer()
        await vm.streamingReturnTask?.value
        #expect(vm.isFollowUpQueued)

        // ⇧⌘O while the answer streams: the model chooser opens.
        vm.modelChooserOptions = [
            ModelChooserOption(providerID: InferenceProvider.deepSeekID, providerName: "DeepSeek API", model: "deepseek-v4-pro"),
        ]
        vm.modelChooserIndex = 0
        vm.modelChooserPurpose = .change
        vm.isModelChooserPresented = true
        let modelBefore = vm.activeModelID

        gated.release()
        await submit.value

        #expect(vm.isModelChooserPresented, "the stream's end never picks in the chooser")
        #expect(vm.activeModelID == modelBefore)
        #expect(vm.isFollowUpQueued, "the follow-up waits for the chooser")
        #expect(vm.input == "and its population?")
        #expect(gated.sendCallCount == 1)

        // Return picks the model; the chooser closes and the follow-up goes.
        await vm.submitResolvingFuzzyAlias()
        await vm.queuedFollowUpTask?.value
        #expect(!vm.isModelChooserPresented)
        #expect(vm.activeModelID == "deepseek-v4-pro", "asked on the model just picked")
        #expect(!vm.isFollowUpQueued)
        #expect(vm.input.isEmpty)
        #expect(gated.sendCallCount == 2, "sent once")
        #expect(vm.conversationMessages.map(\.content) == [
            "tell me about Lima", "Lima is the capital of Peru.",
            "and its population?", "The follow-up answer.",
        ])
    }

    @Test func aQueuedFollowUpBehindTheCommandKPaletteGoesWhenItCloses() async {
        let (vm, gated, submit) = await streaming()
        vm.input = "and its population?"
        vm.submitFromComposer()
        await vm.streamingReturnTask?.value
        vm.toggleActionPalette()
        #expect(vm.isActionPalettePresented)

        gated.release()
        await submit.value
        #expect(vm.isFollowUpQueued)
        #expect(gated.sendCallCount == 1)

        // Escape closes the palette: the follow-up goes as typed.
        #expect(vm.handleEscapeKey())
        await vm.queuedFollowUpTask?.value
        #expect(!vm.isActionPalettePresented)
        #expect(gated.sendCallCount == 2)
        #expect(vm.conversationMessages.last?.content == "The follow-up answer.")
    }

    @Test func aHeldFollowUpIsNotSentWhenTheSurfaceCloses() async {
        let (vm, gated, submit) = await streaming()
        vm.input = "and its population?"
        vm.submitFromComposer()
        await vm.streamingReturnTask?.value
        vm.toggleActionPalette()
        gated.release()
        await submit.value
        #expect(vm.isFollowUpQueued, "held behind the palette")

        // The back chevron closes the palette on the way out: in root search
        // the text is a search, and nothing is sent.
        vm.closeQuickAI()
        await vm.queuedFollowUpTask?.value
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!vm.isQuickAIPresented)
        #expect(!vm.isFollowUpQueued)
        #expect(gated.sendCallCount == 1)
    }

    @Test func theStreamingPlaceholderSaysReturnQueues() {
        let vm = make()
        vm.openQuickAI()
        vm.isStreaming = true
        #expect(vm.quickAIComposerPlaceholder == "Type a follow-up; it sends when this answer ends")
    }

    // MARK: - 14. ⌘K in Recent Chats acts on the highlighted row

    @Test func commandKInRecentChatsTargetsTheHighlightedRow() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "the open chat", reply: "Open.")
        let other = chat("the other chat", "Other.")
        vm.history = [vm.currentConversation!, other]
        let openID = try #require(vm.currentConversation?.id)

        vm.openRecentChats()
        vm.recentChatsIndex = vm.recentChatItems.firstIndex { $0.itemID == other.id.uuidString } ?? 0
        vm.handleCommandK()
        #expect(vm.isCatalogActionPanePresented, "the row's own ⌘K pane, not the answer palette")
        #expect(!vm.isActionPalettePresented)
        guard case .item(let focused) = vm.focusedLauncherResult else {
            Issue.record("no focused row")
            return
        }
        #expect(focused.itemID == other.id.uuidString)
        #expect(vm.focusedItemActions.map(\.title).contains("Pin to Top"))

        // Pin acts on the highlighted chat, and the highlight follows it up.
        let pin = try #require(vm.focusedItemActions.first { $0.kind == .pin })
        await vm.perform(pin, on: .item(focused))
        #expect(vm.history.first { $0.id == other.id }?.isPinned == true)
        #expect(vm.history.first { $0.id == openID }?.isPinned == false, "the open chat is untouched")
        #expect(vm.isRecentChatsPresented, "the list stays up")
        #expect(vm.recentChatItems[vm.recentChatsIndex].itemID == other.id.uuidString)
        #expect(vm.recentChatItems.first?.itemID == other.id.uuidString, "pinned first")
        #expect(vm.recentChatItems.first?.detail.hasPrefix("1 question · ") == true, "no Pinned text")
        #expect(vm.recentChatItems.first?.isPinned == true, "the row draws the pin glyph")
    }

    @Test func renameFromRecentChatsRenamesTheRowAndComesBack() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "the open chat", reply: "Open.")
        let other = chat("the other chat", "Other.")
        vm.history = [vm.currentConversation!, other]
        let openID = try #require(vm.currentConversation?.id)

        vm.openRecentChats()
        vm.recentChatsIndex = vm.recentChatItems.firstIndex { $0.itemID == other.id.uuidString } ?? 0
        #expect(vm.performShortcut(characters: "e", keyCode: 14, modifiers: [.command]))
        #expect(vm.inputMode == .renameChat(other.id), "⌘E renames the highlighted chat")
        vm.input = "Renamed"
        #expect(await vm.submitInputMode())
        #expect(vm.history.first { $0.id == other.id }?.customTitle == "Renamed")
        #expect(vm.history.first { $0.id == openID }?.customTitle == nil)
        #expect(vm.isQuickAIPresented && vm.isRecentChatsPresented, "back in Recent Chats")
        #expect(vm.recentChatItems[vm.recentChatsIndex].title == "Renamed")
        #expect(vm.currentConversation?.id == openID, "the open chat is still open")
    }

    @Test func rowKeysWithNoRowHighlightedNeverTouchTheOpenChat() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock) { $0.historyEnabled = true }
        vm.openQuickAI()
        await ask(vm, mock, "the open chat", reply: "Open.")
        let openID = try #require(vm.currentConversation?.id)

        vm.openRecentChats()
        vm.input = "zzzz-no-match"
        vm.quickAIComposerDidChange(vm.input)
        #expect(vm.recentChatItems.isEmpty)
        #expect(vm.focusedLauncherResult == nil)

        #expect(vm.performShortcut(characters: "x", keyCode: 7, modifiers: [.control]), "⌃X is taken")
        #expect(vm.performShortcut(characters: "x", keyCode: 7, modifiers: [.control]))
        #expect(vm.performShortcut(characters: "e", keyCode: 14, modifiers: [.command]), "⌘E is taken")
        #expect(vm.performShortcut(characters: "p", keyCode: 35, modifiers: [.command, .shift]), "⇧⌘P is taken")
        vm.handleCommandK()
        // Anything the keys started would have run by now.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(vm.currentConversation?.id == openID, "the open chat is not deleted")
        #expect(vm.history.contains { $0.id == openID })
        #expect(vm.history.first { $0.id == openID }?.isPinned == false, "nor pinned")
        #expect(vm.inputMode == nil, "nor renamed")
        #expect(!vm.isActionPalettePresented, "⌘K opens no palette for the open chat")
        #expect(!vm.isItemActionPanePresented)
        #expect(vm.isRecentChatsPresented, "the list stays up")
    }

    @Test func deleteFromRecentChatsDeletesTheRowNotTheOpenChat() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "the open chat", reply: "Open.")
        let other = chat("the other chat", "Other.")
        vm.history = [vm.currentConversation!, other]
        let openID = try #require(vm.currentConversation?.id)

        vm.openRecentChats()
        vm.recentChatsIndex = vm.recentChatItems.firstIndex { $0.itemID == other.id.uuidString } ?? 0
        // ⌃X twice: the first arms, the second deletes, as in the Chats catalog.
        #expect(vm.performShortcut(characters: "x", keyCode: 7, modifiers: [.control]))
        #expect(vm.performShortcut(characters: "x", keyCode: 7, modifiers: [.control]))
        #expect(!vm.history.contains { $0.id == other.id })
        #expect(vm.currentConversation?.id == openID)
        #expect(vm.isRecentChatsPresented)
        #expect(vm.recentChatItems.indices.contains(vm.recentChatsIndex))
    }
}

private actor ThreadVaultSearchService: VaultSearchServicing {
    func search(mode: VaultSearchMode, query: String) async throws -> String { "Vault result" }
}
