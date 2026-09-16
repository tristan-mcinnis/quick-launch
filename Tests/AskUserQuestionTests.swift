import Foundation
import Testing
@testable import QuickLaunch

/// Raycast's Ask User Question: the tool's argument validation, the card's
/// keyboard contract, and the pick folding back into the thread.
@Suite("Ask user question", .serialized)
@MainActor
struct AskUserQuestionTests {

    private static func card() -> AskUserQuestion {
        AskUserQuestion(
            question: "Which folder should I use?",
            options: [
                AskUserQuestionOption(label: "Work", detail: "~/work"),
                AskUserQuestionOption(label: "Personal"),
                AskUserQuestionOption(label: "Other"),
            ]
        )
    }

    private static func answeredViewModel(primary: QuickAIPrimaryAction) async -> QuickViewModel {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Argentina.", finishReason: "stop")])
        let vm = QuickViewModel(service: mock)
        vm.settings.autoCopy = false
        vm.settings.quickAIPrimaryAction = primary
        vm.input = "who won the world cup"
        await vm.submit()
        return vm
    }

    // MARK: - Argument validation

    @Test func parsesAQuestionWithItsOptions() throws {
        let parsed = try #require(AskUserQuestionParser.parse(arguments: """
        {"question":"Which folder?","options":[{"label":"Work","detail":"~/work"},{"label":"Personal"}]}
        """))
        #expect(parsed.question == "Which folder?")
        #expect(parsed.options.map(\.label) == ["Work", "Personal"])
        #expect(parsed.options.first?.detail == "~/work")
        #expect(parsed.options.last?.detail == nil)
        #expect(!parsed.isAnswered)
    }

    @Test func trimsLabelsAndDropsUnusableOnes() throws {
        let parsed = try #require(AskUserQuestionParser.parse(arguments: """
        {"question":"  Pick  ","options":[{"label":"  A  "},{"label":"   "},{"detail":"no label"},{"label":"B"}]}
        """))
        #expect(parsed.question == "Pick")
        // A blank label and a detail-only option are not options.
        #expect(parsed.options.map(\.label) == ["A", "B"])
        #expect(AskUserQuestionParser.parse(arguments: """
        {"question":"Pick","options":[{"label":"A"}]}
        """) == nil)
    }

    @Test func capsTheCardAtFiveOptions() throws {
        let options = (1...8).map { "{\"label\":\"Option \($0)\"}" }.joined(separator: ",")
        let parsed = try #require(AskUserQuestionParser.parse(arguments: """
        {"question":"Pick","options":[\(options)]}
        """))
        #expect(parsed.options.count == AskUserQuestion.maximumOptions)
        #expect(parsed.options.first?.label == "Option 1")
        #expect(parsed.options.last?.label == "Option 5")
    }

    @Test func rejectsMalformedCallsInsteadOfThrowing() {
        #expect(AskUserQuestionParser.parse(arguments: "not json") == nil)
        #expect(AskUserQuestionParser.parse(arguments: "{}") == nil)
        #expect(AskUserQuestionParser.parse(arguments: "[]") == nil)
        #expect(AskUserQuestionParser.parse(arguments: """
        {"question":"   ","options":[{"label":"A"},{"label":"B"}]}
        """) == nil)
        #expect(AskUserQuestionParser.parse(arguments: """
        {"question":"Pick","options":"A, B"}
        """) == nil)
        #expect(AskUserQuestionParser.parse(arguments: """
        {"options":[{"label":"A"},{"label":"B"}]}
        """) == nil)
    }

    @Test func toolResultsTellTheModelWhatHappened() {
        let question = Self.card()
        let picked = AskUserQuestionResult.picked(
            AskUserQuestionAnswer(label: "Personal", detail: nil),
            in: question
        )
        #expect(picked.contains("Personal"))
        #expect(picked.contains(question.question))
        #expect(AskUserQuestionResult.dismissed.contains("best judgement"))
        #expect(AskUserQuestionResult.unusable("it needs two options").contains("Answer the request normally"))
    }

    // MARK: - The card's keyboard contract

    @Test func everyOptionCarriesAKeyboardAccessibleLabel() {
        let card = Self.card()
        let labels = card.options.enumerated().map { index, option in
            AskUserQuestionAccessibility.optionLabel(
                option,
                index: index,
                count: card.options.count,
                isSelected: index == 0,
                isPicked: false
            )
        }
        #expect(labels[0] == "Option 1 of 3. Work. ~/work. Selected")
        #expect(labels[1] == "Option 2 of 3. Personal")
        #expect(labels[2] == "Option 3 of 3. Other")
        let cardLabel = AskUserQuestionAccessibility.cardLabel(
            question: card.question,
            optionCount: card.options.count
        )
        #expect(cardLabel.contains(card.question))
        #expect(cardLabel.contains("3 options"))
        #expect(cardLabel.contains("up and down arrow keys"))
        #expect(cardLabel.contains("press Return"))
    }

    @Test func arrowKeysWalkTheOptionsAndWrap() {
        let vm = QuickViewModel()
        vm.presentAskQuestion(Self.card())
        #expect(vm.askQuestionSelectionIndex == 0)
        #expect(vm.isAskQuestionActive)
        vm.moveAskQuestionSelection(1)
        #expect(vm.askQuestionSelectionIndex == 1)
        vm.moveAskQuestionSelection(-1)
        vm.moveAskQuestionSelection(-1)
        #expect(vm.askQuestionSelectionIndex == 2, "↑ from the first option wraps to the last")
        vm.moveAskQuestionSelection(1)
        #expect(vm.askQuestionSelectionIndex == 0, "↓ from the last option wraps to the first")
    }

    @Test func returnPicksTheHighlightedOption() async {
        let vm = QuickViewModel()
        vm.currentConversation = QuickConversation(providerID: UUID(), model: "test-model")
        vm.presentAskQuestion(Self.card())
        vm.moveAskQuestionSelection(1)
        // Return runs the same router the panel calls.
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.pendingAskQuestion?.selectedIndex == 1)
        #expect(vm.pendingAskQuestion?.chosenLabel == "Personal")
        #expect(!vm.isAskQuestionActive)
    }

    // MARK: - Folding the pick back into the thread

    @Test func pickingAnOptionFoldsItBackAsTheUsersAnswer() {
        let vm = QuickViewModel()
        vm.currentConversation = QuickConversation(providerID: UUID(), model: "test-model")
        let card = Self.card()
        vm.presentAskQuestion(card)
        vm.moveAskQuestionSelection(1)
        vm.answerAskQuestion(index: 1)

        let messages = vm.conversationMessages
        #expect(messages.count == 2)
        #expect(messages[0].role == .assistant)
        #expect(messages[0].askUserQuestion?.question == card.question)
        #expect(messages[0].askUserQuestion?.selectedIndex == 1)
        #expect(messages[0].askUserQuestion?.chosenLabel == "Personal")
        #expect(messages[1].role == .user)
        #expect(messages[1].content == "Personal")
        // The card stays on screen until the answer finishes, so the thread
        // never blinks, and a second pick cannot overwrite the first.
        #expect(vm.pendingAskQuestion?.chosenLabel == "Personal")
        vm.answerAskQuestion(index: 0)
        #expect(vm.pendingAskQuestion?.chosenLabel == "Personal")
        #expect(vm.conversationMessages.count == 2)
    }

    @Test func aDismissedQuestionRecordsNothing() {        let vm = QuickViewModel()
        vm.currentConversation = QuickConversation(providerID: UUID(), model: "test-model")
        vm.presentAskQuestion(Self.card())
        vm.reset(.thread)
        #expect(vm.pendingAskQuestion == nil)
        #expect(vm.conversationMessages.isEmpty)
    }

    // MARK: - Stored threads

    @Test func aMessageWithAQuestionRoundTripsAndLegacyMessagesStillDecode() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let card = Self.card()
        var answered = card
        answered.selectedIndex = 1
        let message = QuickMessage(role: .assistant, content: card.question, askUserQuestion: answered)
        let back = try decoder.decode(QuickMessage.self, from: try encoder.encode(message))
        #expect(back == message)
        #expect(back.askUserQuestion?.chosenLabel == "Personal")

        // Threads written before the card existed carry no such key.
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","role":"user","content":"hi"}"#.utf8)
        let decoded = try decoder.decode(QuickMessage.self, from: legacy)
        #expect(decoded.content == "hi")
        #expect(decoded.askUserQuestion == nil)
    }

    // MARK: - Composer hint

    @Test func theComposerNamesThePrimaryActionReturnWillRun() async {
        let pasting = await Self.answeredViewModel(primary: .pasteToActiveApp)
        #expect(pasting.quickAIComposerAction == .init(label: "Paste Response", keys: ["↩"]))

        let copying = await Self.answeredViewModel(primary: .copyToClipboard)
        #expect(copying.quickAIComposerAction == .init(label: "Copy Response", keys: ["↩"]))
        // ⌘⇧C stays the explicit copy in both settings.
        #expect(copying.resultActions.contains(.copy))
        #expect(ResultAction.copy.defaultShortcut.keyCaps == ["⇧", "⌘", "C"])
    }
}
