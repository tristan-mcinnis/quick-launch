// QuickAIPolishTests — the small Quick AI fixes of v1.5.0 (plan Phase A1,
// docs/ai-chat-plan-20260911.md section 3): answers never collapse, Show more
// and Collapse anchor the message head, the collapse threshold fits the
// thread's width, Recent Chats searches, titles are cleaned up, the composer
// placeholder follows the state, Copy Answer stays open and Copy Chat copies a
// labelled transcript, the empty surface names its ways in, and the header's
// model line opens the model chooser.
//
// The real key events for ⇧⌘M, ⇧⌘C, ⌥⌘C, and ⇧⌘O are in QuickAIKeyboardTests.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Quick AI polish", .serialized)
@MainActor
struct QuickAIPolishTests {

    // MARK: - Fixtures

    private func make(
        service: MockQuickService = MockQuickService(),
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

    /// The saved-prompt aliases a fresh install has.
    private static let aliases = Set(SavedPrompt.defaults.map(\.alias))

    private func lines(_ count: Int, _ text: String = "a line with a few more words in it") -> String {
        (1...count).map { "\(text) \($0)" }.joined(separator: "\n")
    }

    private func conversation(_ turns: [(String, String)], model: String = "deepseek-v4-pro") -> QuickConversation {
        QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: model,
            messages: turns.flatMap { question, answer in
                [QuickMessage(role: .user, content: question), QuickMessage(role: .assistant, content: answer)]
            }
        )
    }

    // MARK: - 1. Answers never collapse

    @Test func aLongAnswerStaysInFullWhenTheStreamEnds() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let answer = lines(30)
        await ask(vm, mock, "explain it all", reply: answer)

        let message = try #require(vm.conversationMessages.last)
        #expect(message.role == .assistant)
        #expect(message.content == answer)
        let state = vm.collapseState(for: message)
        #expect(!state.isCollapsible, "an answer never grows Show more")
        #expect(!state.isCollapsed)
        #expect(state.displayedText == answer)
        #expect(state.controlTitle == nil)
        #expect(vm.keyboardToggleMessageID == nil, "⇧⌘M has no answer to fold")
    }

    @Test func aLongQuestionStillCollapses() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let question = lines(14)
        await ask(vm, mock, question, reply: "Short.")

        let message = try #require(vm.conversationMessages.first)
        #expect(message.role == .user)
        #expect(vm.collapseState(for: message).isCollapsed)
        #expect(vm.collapseState(for: message).controlTitle == "Show more")
    }

    @Test func aStateThatDoesNotCollapseIgnoresLength() {
        let long = lines(40)
        #expect(MessageCollapseState(text: long).isCollapsible)
        let fixed = MessageCollapseState(text: long, collapses: false)
        #expect(!fixed.isCollapsible)
        #expect(fixed.displayedText == long)
        #expect(fixed.controlTitle == nil, "the pending question pill never offers a dead Collapse")
    }

    // MARK: - 2. Show more and Collapse anchor the head

    @Test func showMoreAndCollapseAskTheThreadForTheMessageHead() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, lines(14), reply: "Short.")
        let id = try #require(vm.keyboardToggleMessageID)
        #expect(vm.threadScrollRequest == nil, "nothing asked before a toggle")

        #expect(vm.toggleTranscriptMessage(id))
        #expect(vm.threadScrollRequest == .init(messageID: id, revision: 1))
        #expect(vm.collapseState(for: vm.conversationMessages[0]).isExpanded)

        #expect(vm.toggleTranscriptMessage(id))
        #expect(vm.threadScrollRequest == .init(messageID: id, revision: 2), "Collapse lands on the same head")
        #expect(vm.collapseState(for: vm.conversationMessages[0]).isCollapsed)
    }

    @Test func theShortcutTargetsTheNewestCollapsibleTurn() {
        let vm = make()
        vm.currentConversation = conversation([
            (lines(14, "older long question"), lines(30, "a long answer")),
            (lines(14, "newer long question"), lines(30, "another long answer")),
            ("a short question", lines(30, "the newest long answer")),
        ])
        let newerQuestion = vm.conversationMessages[2]
        #expect(vm.keyboardToggleMessageID == newerQuestion.id,
                "the newest long question, past the short one and every long answer")
    }

    @Test func onlyTheNewestLongQuestionShowsTheShortcut() {
        let vm = make()
        vm.currentConversation = conversation([
            (lines(14, "older long question"), "Short."),
            (lines(14, "newer long question"), "Short too."),
        ])
        let older = vm.conversationMessages[0]
        let newer = vm.conversationMessages[2]
        #expect(vm.collapseState(for: older).controlTitle == "Show more")
        #expect(vm.collapseState(for: newer).controlTitle == "Show more")
        #expect(!vm.showsCollapseShortcut(for: older), "⇧⌘M would fold the other pill")
        #expect(vm.showsCollapseShortcut(for: newer))
        #expect(!vm.showsCollapseShortcut(for: vm.conversationMessages[1]), "an answer has no control")

        // Expanded, the newest keeps the key: its Collapse is what ⇧⌘M does.
        #expect(vm.toggleTranscriptMessage(newer.id))
        #expect(vm.collapseState(for: newer).controlTitle == "Collapse")
        #expect(vm.showsCollapseShortcut(for: newer))
        #expect(!vm.showsCollapseShortcut(for: older))
    }

    // MARK: - 6. The threshold fits the thread

    @Test func theThreadHoldsAboutAHundredCharactersALine() {
        // The review estimated about 95 at 690 pt; measured, the pill's
        // 666 pt column of 13 pt text holds about 105, and 690 pt of 14 pt
        // prose about 102. Either way, not the old 60.
        let perLine = MessageCollapsePolicy.charactersPerLine
        #expect((92...115).contains(perLine), "measured \(perLine) characters a line in the thread pill")
        let prose = MessageCollapsePolicy.measuredCharactersPerLine(
            width: House.Layout.quickAIAnswerMaxWidth,
            fontSize: House.TypeToken.Size.body
        )
        #expect((90...110).contains(prose), "measured \(prose) at 690 pt of body text")
        #expect(prose <= perLine, "the larger prose type holds fewer characters in a wider column")
        // The measure follows the width: half the column holds about half.
        let narrow = MessageCollapsePolicy.measuredCharactersPerLine(
            width: House.Layout.quickAIAnswerMaxWidth / 2,
            fontSize: House.TypeToken.Size.bodySmall
        )
        #expect(narrow < perLine)
        #expect(abs(narrow * 2 - perLine) <= perLine / 5)
    }

    @Test func aSevenHundredCharacterQuestionNoLongerFolds() {
        // At the old 60 characters a line this was twelve lines and folded;
        // in the thread it wraps to about seven.
        let paragraph = String(String(repeating: "tell me more about the trip ", count: 25).prefix(700))
        #expect(!MessageCollapsePolicy.shouldCollapse(paragraph))
        #expect(MessageCollapsePolicy.estimatedLineCount(of: paragraph) <= 8)
        let longer = String(repeating: "tell me more about the trip ", count: 50)
        #expect(MessageCollapsePolicy.shouldCollapse(longer))
    }

    // MARK: - 7. Recent Chats search

    private func withThreeChats() async -> (QuickViewModel, [QuickConversation]) {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "raycast founder", reply: "Thomas Paul Mann.")
        let peru = conversation([("what is the capital of Peru", "Lima.")])
        let plan = conversation([("summarise the Q3 plan", "Three priorities: hiring, pricing, launch.")])
        let chats = [vm.currentConversation!, plan, peru]
        vm.history = chats
        return (vm, chats)
    }

    @Test func openingRecentChatsClearsTheComposer() async {
        let (vm, chats) = await withThreeChats()
        vm.input = "a half-typed follow-up"
        vm.openRecentChats()
        #expect(vm.isRecentChatsPresented)
        #expect(vm.input.isEmpty, "the list opens on every chat")
        #expect(vm.recentChatItems.count == chats.count)
    }

    @Test func theComposerFiltersByTitleAndByMessageText() async {
        let (vm, chats) = await withThreeChats()
        vm.openRecentChats()

        vm.input = "peru"
        vm.quickAIComposerDidChange(vm.input)
        #expect(vm.recentChatItems.map(\.itemID) == [chats[2].id.uuidString], "a title match")

        vm.input = "PRICING"
        vm.quickAIComposerDidChange(vm.input)
        #expect(vm.recentChatItems.map(\.itemID) == [chats[1].id.uuidString], "an answer's text, any case")

        vm.input = "thomas mann"
        #expect(vm.recentChatItems.map(\.itemID) == [chats[0].id.uuidString], "every word must appear")

        vm.input = "nothing like this"
        #expect(vm.recentChatItems.isEmpty)
    }

    @Test func typingMovesTheHighlightToTheFirstMatch() async {
        let (vm, _) = await withThreeChats()
        vm.openRecentChats()
        vm.recentChatsIndex = 2
        vm.input = "q"
        vm.quickAIComposerDidChange(vm.input)
        #expect(vm.recentChatsIndex == 0)
    }

    @Test func openingWithTypedTextStillHighlightsTheOpenChat() async {
        let (vm, chats) = await withThreeChats()
        vm.input = "half typed"
        vm.openRecentChats()
        let open = vm.recentChatsIndex
        #expect(vm.recentChatItems[open].itemID == chats[0].id.uuidString)
        // The view reports the cleared field after the fact.
        vm.quickAIComposerDidChange(vm.input)
        #expect(vm.recentChatsIndex == open, "clearing the field is not a search")
    }

    @Test func returnOpensTheHighlightedFilteredChatAndClearsTheText() async {
        let (vm, chats) = await withThreeChats()
        vm.openRecentChats()
        vm.input = "capital"
        vm.quickAIComposerDidChange(vm.input)

        await vm.submitResolvingFuzzyAlias()
        #expect(!vm.isRecentChatsPresented)
        #expect(vm.currentConversation?.id == chats[2].id, "the filtered row, not the row at that index unfiltered")
        #expect(vm.output == "Lima.")
        #expect(vm.input.isEmpty, "the search text never becomes a follow-up")
    }

    @Test func returnOnASearchWithNoMatchKeepsTheList() async {
        let (vm, chats) = await withThreeChats()
        vm.openRecentChats()
        vm.input = "zzz"
        vm.quickAIComposerDidChange(vm.input)
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.isRecentChatsPresented)
        #expect(vm.currentConversation?.id == chats[0].id, "no chat was opened")
        #expect(vm.input == "zzz")
    }

    @Test func escapeClearsTheSearchFirstThenClosesTheList() async {
        let (vm, _) = await withThreeChats()
        vm.openRecentChats()
        vm.input = "peru"
        #expect(vm.handleEscapeKey())
        #expect(vm.isRecentChatsPresented, "the first Escape clears the search")
        #expect(vm.input.isEmpty)
        #expect(vm.handleEscapeKey())
        #expect(!vm.isRecentChatsPresented, "the second returns to the thread")
        #expect(vm.isQuickAIPresented)
    }

    @Test func anAtInTheSearchIsText() async {
        let (vm, _) = await withThreeChats()
        vm.openRecentChats()
        vm.input = "@"
        vm.quickAIComposerDidChange(vm.input)
        #expect(!vm.isAddContextMenuPresented, "the composer is a search field here")
        #expect(vm.input == "@")
    }

    @Test func leavingRecentChatsTakesTheSearchWithIt() async {
        let (vm, _) = await withThreeChats()
        vm.openRecentChats()
        vm.input = "peru"
        vm.toggleRecentChats()
        #expect(!vm.isRecentChatsPresented)
        #expect(vm.input.isEmpty)

        vm.openRecentChats()
        vm.input = "peru"
        vm.closeQuickAI()
        #expect(vm.input.isEmpty, "root search does not inherit the chat search")
    }

    // MARK: - 8. Titles

    @Test(arguments: [
        ("raycast founder", "Raycast founder"),
        ("why is the sky blue?", "Why is the sky blue"),
        ("  what is 2+2.  ", "What is 2+2"),
        ("/translate hello world", "Hello world"),
        ("/etc/hosts is not updating", "/etc/hosts is not updating"),
        ("/nosuchalias keep it", "/nosuchalias keep it"),
        ("search web raycast founder", "Raycast founder"),
        ("Search the web for the latest Swift release?", "The latest Swift release"),
        ("look up: weather in Paris", "Weather in Paris"),
        ("find online cheap flights to Lima", "Cheap flights to Lima"),
        ("searching for meaning", "Searching for meaning"),
        ("\n\nsecond line wins when the first is blank\nthird", "Second line wins when the first is blank"),
        ("élan vital", "Élan vital"),
    ])
    func aQuestionBecomesATitle(question: String, title: String) {
        #expect(QuickConversation.cleanTitle(from: question, aliasPrefix: "/", aliases: Self.aliases) == title)
    }

    @Test func aLongQuestionIsCutAtAWordUnderSixtyCharacters() throws {
        let question = "can you compare the three pricing options for the new plan and tell me which one is best"
        let title = try #require(QuickConversation.cleanTitle(from: question, aliasPrefix: "/", aliases: Self.aliases))
        #expect(title.count < QuickConversation.titleCharacterLimit)
        #expect(title == "Can you compare the three pricing options for the new plan")
        #expect(question.capitalizedFirst.hasPrefix(title))
        #expect(title.last?.isLetter == true, "never ends mid-word or on a space")

        let oneWord = String(repeating: "x", count: 90)
        #expect(QuickConversation.cleanTitle(from: oneWord, aliasPrefix: "/", aliases: Self.aliases)?.count
            == QuickConversation.titleCharacterLimit - 1)
    }

    @Test func nothingLeftFallsBack() {
        #expect(QuickConversation.cleanTitle(from: "/translate", aliasPrefix: "/", aliases: Self.aliases) == nil)
        #expect(QuickConversation.cleanTitle(from: "???", aliasPrefix: "/", aliases: Self.aliases) == nil)
        let chat = QuickConversation(providerID: UUID(), model: "m", messages: [QuickMessage(role: .user, content: "  ")])
        #expect(chat.title == "New quick action")
    }

    @Test func aRenamedChatKeepsItsName() {
        var chat = conversation([("search web raycast founder", "Thomas.")])
        #expect(chat.title == "Raycast founder")
        chat.customTitle = "founders, as asked?"
        #expect(chat.title == "founders, as asked?", "Rename Chat wins, exactly as typed")
    }

    @Test func theHeaderAndTheRowsUseTheConfiguredPrefix() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock) { settings in
            settings.savedPromptPrefix = ";"
            settings.historyEnabled = true
        }
        await ask(vm, mock, ";zh good morning", reply: "早上好")
        let chat = try #require(vm.currentConversation)
        #expect(chat.messages.first?.content.hasPrefix("Translate the following text") == true,
                "the model got the expanded template")
        #expect(chat.titleSource == ";zh good morning", "the title reads what was typed")
        #expect(vm.quickAITitle == "Good morning")
        #expect(vm.conversationItems.first?.title == "Good morning")
    }

    // The titles below go through the real submit path, so they read what
    // the conversation actually stores.

    @Test func aSavedPromptChatIsNamedForItsTextNotItsTemplate() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "/grammar teh text is rong", reply: "The text is wrong.")
        let chat = try #require(vm.currentConversation)
        #expect(chat.messages.first?.content.hasPrefix("Fix grammar and spelling") == true)
        #expect(vm.quickAITitle == "Teh text is rong")
    }

    @Test func aBareAliasFallsBackToThePromptItSent() async {
        let mock = MockQuickService()
        let vm = make(service: mock) { settings in
            settings.savedPrompts.append(SavedPrompt(alias: "standup", prompt: "Write my standup notes for today."))
        }
        await ask(vm, mock, "/standup", reply: "Yesterday: shipped.")
        #expect(vm.currentConversation?.titleSource == "/standup")
        #expect(vm.quickAITitle == "Write my standup notes for today",
                "the typed text is only an alias, so the prompt it ran names the chat")
    }

    @Test func aContextChatIsNamedForTheQuestionNotThePreamble() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.pendingContext = CaptureContext(
            appName: "Safari",
            windowTitle: "Inbox",
            pageURL: "https://mail.example.com/inbox"
        )
        await ask(vm, mock, "what does this email ask for?", reply: "A reply by Friday.")
        let chat = try #require(vm.currentConversation)
        let sent = try #require(chat.messages.first?.content)
        #expect(sent.contains("Safari") && sent.contains("Question: what does this email ask for?"),
                "the model got the context preamble")
        #expect(vm.quickAITitle == "What does this email ask for")
    }

    @Test func aQuestionThatStartsWithAPathKeepsIt() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "/etc/hosts is not updating", reply: "Flush the DNS cache.")
        #expect(vm.quickAITitle == "/etc/hosts is not updating", "/etc is not a saved prompt")
    }

    @Test func aFirstQuestionThatFailedStaysTheTitleWhenRetried() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await mock.setShouldThrow(true)
        vm.input = "first try"
        await vm.submit()
        // v1.5.0 (Phase A2): a provider error keeps the question as a turn,
        // with the error under it, instead of putting it back in the field.
        #expect(vm.input.isEmpty)
        #expect(vm.conversationMessages.map(\.content) == ["first try"])
        #expect(vm.currentConversation?.titleSource == "first try")

        await mock.setShouldThrow(false)
        await mock.setResponses([StreamDelta(text: "Hi.", finishReason: "stop")])
        await vm.regenerateLastAnswer()
        #expect(vm.conversationMessages.map(\.content) == ["first try", "Hi."])
        #expect(vm.quickAITitle == "First try")
    }

    @Test func aChatSavedBeforeTitleSourceStillDecodes() throws {
        let saved = conversation([("an old question", "An old answer.")])
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
        )
        #expect(object["titleSource"] == nil, "nil is not written")
        object.removeValue(forKey: "titleSource")
        let decoded = try JSONDecoder().decode(
            QuickConversation.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.titleSource == nil)
        #expect(decoded.title == "An old question")

        var typed = saved
        typed.titleSource = "/zh an old question"
        let roundTrip = try JSONDecoder().decode(QuickConversation.self, from: JSONEncoder().encode(typed))
        #expect(roundTrip.titleSource == "/zh an old question")
        #expect(roundTrip.title(aliasPrefix: "/", aliases: Self.aliases) == "An old question")
    }

    // MARK: - 9. Placeholder

    @Test func thePlaceholderSaysWhatTypingWillDo() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.input = ""
        #expect(vm.handleTab())
        #expect(vm.quickAIComposerPlaceholder == "Ask anything, @ tools, or / for commands…")

        await ask(vm, mock, "hello", reply: "Hi.")
        #expect(vm.quickAIComposerPlaceholder == "Ask a follow-up…", "a thread exists")

        vm.history = [vm.currentConversation!]
        vm.openRecentChats()
        #expect(vm.quickAIComposerPlaceholder == "Search chats…")
        vm.closeRecentChats()

        vm.isStreaming = true
        #expect(vm.quickAIComposerPlaceholder == "Type a follow-up; it sends when this answer ends")
        vm.isStreaming = false

        vm.startNewConversation()
        #expect(vm.quickAIComposerPlaceholder == "Ask anything, @ tools, or / for commands…")
    }

    @Test func theQuestionCardSaysTheWaitIsYours() {
        let vm = make()
        vm.openQuickAI()
        vm.isStreaming = true
        vm.pendingAskQuestion = AskUserQuestion(
            question: "Which folder?",
            options: [AskUserQuestionOption(label: "Code"), AskUserQuestionOption(label: "Vault")]
        )
        #expect(vm.quickAIComposerPlaceholder == "Pick an option above… esc stops")
        vm.pendingAskQuestion = nil
        #expect(vm.quickAIComposerPlaceholder == "Type a follow-up; it sends when this answer ends")
    }

    @Test func aFollowUpThatStartsANewChatIsNotCalledOne() async {
        let mock = MockQuickService()
        let vm = make(service: mock) { $0.newChatInterval = .always }
        await ask(vm, mock, "hello", reply: "Hi.")
        #expect(vm.quickAIComposerPlaceholder == "Ask anything, @ tools, or / for commands…",
                "with New Chat set to always, the next question starts its own chat")
    }

    // MARK: - 10. Copy Answer and Copy Chat

    @Test func copyAnswerKeepsTheSurfaceAndChecksTheComposer() async {
        let mock = MockQuickService()
        let pasteboard = FakePasteboard()
        let vm = make(service: mock, pasteboard: pasteboard)
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        vm.composerConfirmationDuration = .milliseconds(60)
        await ask(vm, mock, "hello", reply: "Bonjour")

        vm.handleCommandK()
        #expect(vm.isActionPalettePresented)
        await vm.performResultAction(.copy)
        #expect(pasteboard.string == "Bonjour")
        #expect(presenter.dismissals == 0)
        #expect(vm.isQuickAIPresented)
        #expect(!vm.isActionPalettePresented)
        #expect(vm.composerConfirmation == "Copied")

        try? await Task.sleep(for: .milliseconds(200))
        #expect(vm.composerConfirmation == nil, "the checkmark goes after its moment")
    }

    @Test func aSecondCopyRestartsTheCheckmark() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.composerConfirmationDuration = .milliseconds(150)
        await ask(vm, mock, "hello", reply: "Bonjour")

        vm.copyAnswerOnSurface()
        try? await Task.sleep(for: .milliseconds(100))
        vm.copyChatTranscript()
        #expect(vm.composerConfirmation == "Chat copied")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(vm.composerConfirmation == "Chat copied", "the first copy's timer was cancelled")
        try? await Task.sleep(for: .milliseconds(250))
        #expect(vm.composerConfirmation == nil)
    }

    @Test func thePrimaryCopyResponseAlsoChecksTheComposer() async {
        let mock = MockQuickService()
        let pasteboard = FakePasteboard()
        let vm = make(service: mock, pasteboard: pasteboard) { $0.quickAIPrimaryAction = .copyToClipboard }
        await ask(vm, mock, "hello", reply: "Bonjour")
        vm.input = ""
        await vm.submitResolvingFuzzyAlias()
        #expect(pasteboard.string == "Bonjour")
        #expect(vm.composerConfirmation == "Copied")
    }

    @Test func copyChatCopiesTheLabelledTranscript() async {
        let mock = MockQuickService()
        let pasteboard = FakePasteboard()
        let vm = make(service: mock, pasteboard: pasteboard)
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        await ask(vm, mock, "who founded Raycast", reply: "Thomas Paul Mann and Petr Nikolaev.")
        await ask(vm, mock, "when?", reply: "In 2020.")
        let model = ModelProfile.displayName(forModelID: vm.currentConversation?.model ?? "")
        #expect(!model.isEmpty)

        #expect(vm.resultActions.contains(.copyChat))
        await vm.performResultAction(.copyChat)
        #expect(pasteboard.string == """
        You: who founded Raycast

        \(model): Thomas Paul Mann and Petr Nikolaev.

        You: when?

        \(model): In 2020.
        """)
        #expect(presenter.dismissals == 0)
        #expect(vm.composerConfirmation == "Chat copied")
    }

    @Test func theTranscriptNamesTheCuratedModelNotItsID() {
        let chat = conversation([("hi", "Hello.")], model: InferenceProvider.deepSeekDefaultModel)
        let name = ModelProfile.displayName(forModelID: InferenceProvider.deepSeekDefaultModel)
        #expect(name != InferenceProvider.deepSeekDefaultModel, "the curated table names the default model")
        #expect(chat.labelledTranscript == "You: hi\n\n\(name): Hello.")
    }

    @Test func copyChatIsInTheCommandKPaletteOnOptionCommandC() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "hello", reply: "Hi.")
        #expect(ResultAction.copyChat.title == "Copy Chat")
        #expect(ResultAction.copyChat.shortcut == .commandOption("c"))
        #expect(ResultAction.copyChat.shortcut.keyCaps == ["⌥", "⌘", "C"])
        vm.handleCommandK()
        #expect(vm.paletteResultActions.contains(.copyChat))
        vm.actionQuery = "copy chat"
        #expect(vm.paletteResultActions.first == .copyChat)
    }

    /// ⌥⌘C was checked against every key table: the answer actions, the
    /// overlay's own keys, the ⌘K row actions of every kind, and the default
    /// global hotkeys.
    @Test func optionCommandCIsFreeEverywhere() {
        let copyChat = ResultAction.copyChat.shortcut
        let answerKeys = ResultAction.allCases.filter { $0 != .copyChat }.map(\.shortcut)
        let overlayKeys: [KeyShortcut] = [
            QuickViewModel.recentChatsShortcut,
            QuickViewModel.transformChooserShortcut,
            QuickViewModel.transcriptCollapseShortcut,
        ]
        let kinds: [LauncherItemKind] = [
            .snippet, .quickLink, .clipboard, .command, .emoji, .screenshot,
            .conversation, .askAI, .folder, .answer, .screenHistory, .color,
        ]
        var results: [LauncherSearchResult] = kinds.map { kind in
            .item(LauncherCatalogItem(
                kind: kind,
                itemID: kind == .color ? "#FF0000" : "item",
                title: "Item",
                detail: "",
                value: "https://example.com/?utm_source=proof",
                keywords: "has-local-file"
            ))
        }
        results.append(.catalog(.chats, count: 1))
        let app = LaunchableApplication(name: "Notes", bundleIdentifier: "com.apple.Notes", url: URL(fileURLWithPath: "/Applications/Notes.app"))
        results.append(.application(app))
        var rowKeys = results.flatMap { ItemActionCatalog.actions(for: $0, pasteTarget: nil).compactMap(\.shortcut) }
        rowKeys += ItemActionCatalog.actions(for: .application(app), pasteTarget: nil, isRunning: true).compactMap(\.shortcut)

        #expect(!answerKeys.contains(copyChat))
        #expect(!overlayKeys.contains(copyChat))
        #expect(!rowKeys.contains(copyChat))
        #expect(Set(answerKeys.map(\.keyCaps)).count == answerKeys.count, "every answer action has its own key")

        // Global hotkeys are key codes: C is 8, ⌥⌘ is 1_572_864.
        let optionCommandC = ActionHotkey(keyCode: 8, modifiers: 1_572_864)
        let settings = QuickSettings()
        var globals = [settings.clipboardHistoryHotkey, settings.translatorHotkey, settings.typeToClickHotkey]
        globals += settings.savedPrompts.compactMap(\.hotkey)
        globals += settings.launcherItemConfigurations.compactMap(\.hotkey)
        #expect(!globals.contains(optionCommandC))
        #expect(!(settings.hotkeyKeyCode == 8 && settings.hotkeyModifiers == 1_572_864))
    }

    // MARK: - 12. Empty-state hints

    @Test func theEmptySurfaceNamesItsWaysInWithTheirRealKeys() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.input = ""
        #expect(vm.handleTab())
        #expect(vm.quickAIEmptyStateHints == [
            "@ adds a window, a selection, or a screen",
            "⌘J opens recent chats",
            "⇧⌘O changes the model",
        ])
        // The keys come from the tables, so a rebind renames the hint.
        #expect(vm.quickAIEmptyStateHints[1].hasPrefix(QuickViewModel.recentChatsShortcut.keyCaps.joined()))
        #expect(vm.quickAIEmptyStateHints[2].hasPrefix(ResultAction.changeModel.shortcut.keyCaps.joined()))
        #expect(vm.quickAIEmptyStateHints[0].first == QuickViewModel.addContextTrigger)

        vm.input = "@"
        #expect(vm.addContextTriggerDidChange(vm.input), "the @ it names opens Add Context")
        vm.closeAddContextMenu()

        await ask(vm, mock, "hello", reply: "Hi.")
        #expect(vm.quickAIEmptyStateHints.isEmpty, "gone after the first turn")
        vm.startNewConversation()
        #expect(vm.quickAIEmptyStateHints.count == 3, "back on a new chat")
    }

    @Test func theHintsWaitWhileAQuestionIsInFlight() {
        let vm = make()
        vm.openQuickAI()
        vm.pendingQuestion = "search web raycast"
        #expect(vm.quickAIEmptyStateHints.isEmpty)
        vm.pendingQuestion = nil
        vm.isStreaming = true
        #expect(vm.quickAIEmptyStateHints.isEmpty)
    }

    // MARK: - 15. The model line

    @Test func theModelLineOpensTheChooserInChangeMode() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        vm.toggleModelChooserFromHeader()
        #expect(vm.isModelChooserPresented)
        #expect(vm.modelChooserPurpose == .change, "picking only changes the model, it asks nothing")
        #expect(vm.modelChooserOptions.contains { $0.model == vm.activeModelID }, "the row in use is offered")
        vm.toggleModelChooserFromHeader()
        #expect(!vm.isModelChooserPresented, "a second click closes it")

        await ask(vm, mock, "hello", reply: "Hi.")
        vm.toggleModelChooserFromHeader()
        #expect(vm.modelChooserPurpose == .change)
        let other = vm.modelChooserOptions.firstIndex { $0.model != vm.activeModelID } ?? 0
        vm.modelChooserIndex = other
        let picked = vm.modelChooserOptions[other].model
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.activeModelID == picked)
        #expect(await mock.sendCallCount == 1, "changing the model sends nothing")
    }

    @Test func returnPicksTheModelWhenTheChooserIsOverRecentChats() async throws {
        let (vm, chats) = await withThreeChats()
        vm.openRecentChats()
        let before = vm.activeModelID
        vm.toggleModelChooserFromHeader()
        #expect(vm.isModelChooserPresented)
        #expect(vm.topLayer == .modelChooser, "the chooser is drawn over the list")
        try #require(vm.modelChooserOptions.count > 1)
        vm.moveModelChooserSelection(1)
        let picked = vm.modelChooserOptions[vm.modelChooserIndex].model
        #expect(picked != before)

        await vm.submitResolvingFuzzyAlias()
        #expect(vm.activeModelID == picked, "Return picked the model under the keys")
        #expect(vm.currentConversation?.id == chats[0].id, "no chat was opened")
        #expect(!vm.isModelChooserPresented)
        #expect(vm.isRecentChatsPresented, "the list under it is still there, as after Escape")
    }

    @Test func theChangeModelKeyOverRecentChatsAlsoPicksTheModel() async throws {
        let (vm, chats) = await withThreeChats()
        vm.openRecentChats()
        #expect(vm.performShortcut(characters: "o", keyCode: 31, modifiers: [.command, .shift]))
        #expect(vm.isModelChooserPresented)
        try #require(vm.modelChooserOptions.count > 1)
        vm.moveModelChooserSelection(1)
        let picked = vm.modelChooserOptions[vm.modelChooserIndex].model
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.activeModelID == picked)
        #expect(vm.currentConversation?.id == chats[0].id)
        #expect(!vm.isModelChooserPresented)
    }

    @Test func theChooserStaysShutWhileTheQuestionCardWaits() async {
        let vm = make()
        vm.openQuickAI()
        vm.isStreaming = true
        let before = vm.activeModelID
        vm.presentAskQuestion(AskUserQuestion(
            question: "Which folder?",
            options: [AskUserQuestionOption(label: "Code"), AskUserQuestionOption(label: "Vault")]
        ))
        #expect(vm.isAskQuestionActive)

        vm.toggleModelChooserFromHeader()
        #expect(!vm.isModelChooserPresented, "the header click does not open a chooser over the card")
        #expect(vm.performShortcut(characters: "o", keyCode: 31, modifiers: [.command, .shift]),
                "the key is taken, not passed to another action")
        #expect(!vm.isModelChooserPresented)

        vm.moveAskQuestionSelection(1)
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.pendingAskQuestion?.selectedIndex == 1, "Return answered the card")
        #expect(vm.activeModelID == before)
    }

    @Test func theQuestionCardClosesAChooserThatWasAlreadyOpen() {
        let vm = make()
        vm.openQuickAI()
        vm.isStreaming = true
        vm.toggleModelChooserFromHeader()
        #expect(vm.isModelChooserPresented, "a chooser may open while an answer streams")
        vm.presentAskQuestion(AskUserQuestion(
            question: "Which folder?",
            options: [AskUserQuestionOption(label: "Code"), AskUserQuestionOption(label: "Vault")]
        ))
        #expect(!vm.isModelChooserPresented, "the card owns ↑↓ and Return, so nothing stays over it")
        #expect(vm.quickAIComposerAction.label == "Pick")
    }

    // MARK: - The composer names what Return does in a chooser

    @Test func theComposerSaysUseModelWhileTheChooserIsOpen() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "hello", reply: "Hi.")
        vm.input = ""
        #expect(vm.quickAIComposerAction.label == "Paste Response")
        vm.toggleModelChooserFromHeader()
        #expect(vm.quickAIComposerAction == .init(label: "Use Model", keys: ["↩"]),
                "the same words as the chooser's own header")
        vm.closeModelChooser()
        vm.openModelChooser(.regenerate)
        #expect(vm.quickAIComposerAction == .init(label: ModelChooserPurpose.regenerate.confirmTitle, keys: ["↩"]))
        vm.closeModelChooser()

        // Over Recent Chats, and while an answer streams, the chooser still
        // takes Return, so its words win there too.
        vm.history = [vm.currentConversation!]
        vm.openRecentChats()
        vm.toggleModelChooserFromHeader()
        #expect(vm.quickAIComposerAction.label == "Use Model")
        vm.closeModelChooser()
        vm.closeRecentChats()
        vm.isStreaming = true
        vm.toggleModelChooserFromHeader()
        #expect(vm.quickAIComposerAction.label == "Use Model")
        vm.isStreaming = false
    }

    @Test func theComposerSaysAddWhileAddContextIsOpen() {
        let vm = make()
        vm.openQuickAI()
        vm.openAddContextMenu()
        #expect(vm.isAddContextMenuPresented)
        #expect(vm.quickAIComposerAction == .init(label: "Add", keys: ["↩"]))
        #expect(QuickViewModel.addContextConfirmTitle == "Add", "the menu's header reads the same")
    }

    @Test func theComposerSaysRunWhileTheTransformChooserIsOpen() {
        let vm = make()
        vm.openQuickAI()
        // Opening it needs a captured selection; the render proof covers
        // that path. Here only the hint is under test.
        vm.isTransformChooserPresented = true
        #expect(vm.quickAIComposerAction == .init(label: "Run", keys: ["↩"]))
        #expect(QuickViewModel.transformChooserConfirmTitle == "Run")
    }

    // MARK: - The question leaves the composer while the web search runs

    @Test func theComposerEmptiesForTheSearchAndGetsTheQuestionBackOnStop() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let search = GatedWebSearchService(result: "## [1] Raycast\nURL: https://www.raycast.com/about")
        vm.webSearchService = search
        vm.openQuickAI()
        vm.input = "search web raycast founder"
        vm.submitFromComposer()
        let submit = vm.composerSubmitTask
        await search.waitUntilSearching()

        #expect(vm.input.isEmpty, "the question is a pill now, not text still to send")
        #expect(vm.pendingQuestion == "search web raycast founder")
        #expect(vm.quickAIComposerPlaceholder == QuickViewModel.streamingPlaceholder)

        #expect(vm.handleEscapeKey())
        #expect(vm.input == "search web raycast founder", "a stopped search gives the question back")
        await search.release()
        await submit?.value
        #expect(vm.input == "search web raycast founder", "the late search result does not touch it again")
        #expect(await mock.sendCallCount == 0)
    }

    @Test func theQuestionComesBackWhenTheSearchFails() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.webSearchService = FailingWebSearchService()
        vm.openQuickAI()
        vm.input = "search web raycast founder"
        await vm.submit()
        #expect(vm.errorMessage == FailingWebSearchService.message)
        #expect(vm.input == "search web raycast founder")
        #expect(await mock.sendCallCount == 0)
    }

    @Test func theComposerStaysEmptyOnceTheSearchedQuestionIsATurn() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.webSearchService = GatedWebSearchService(result: "## [1] Raycast")
        let search = vm.webSearchService as? GatedWebSearchService
        await mock.setResponses([StreamDelta(text: "Thomas Paul Mann.", finishReason: "stop")])
        vm.openQuickAI()
        vm.input = "search web raycast founder"
        vm.submitFromComposer()
        let submit = vm.composerSubmitTask
        await search?.waitUntilSearching()
        await search?.release()
        await submit?.value
        #expect(vm.output == "Thomas Paul Mann.")
        #expect(vm.input.isEmpty)
        #expect(vm.conversationMessages.first?.content == "search web raycast founder")
    }
}

/// A web search that always fails with one known message.
private struct FailingWebSearchService: WebSearchServicing {
    static let message = "SearXNG did not answer."

    struct Failure: LocalizedError {
        var errorDescription: String? { FailingWebSearchService.message }
    }

    func search(_ query: String) async throws -> String { throw Failure() }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
