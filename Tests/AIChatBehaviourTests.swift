// AIChatBehaviourTests — package W2 of the AI Chat walkthrough
// (docs/ai-chat-walkthrough-20260911.md): how the window's view model
// behaves. Follow-ups never start a new chat in the window (1), a good area
// capture brings the window back (2), Focused Window and Selected Text read
// the app in front before the window (4), the model is per chat (5), a ⌘J
// hand-off into a busy window (6), New Chat during a stream (7), two views
// on one store (10), "Answer ready" (15), any message's Copy and Capture
// (18), and Continue in pi during a stream (22).

import AppKit
import Foundation
import Synchronization
import Testing
@testable import QuickLaunch

/// A presenter that counts every call, the restore after a capture too.
@MainActor
final class RestoreCountingPresenter: OverlayPresenting {
    var presentations = 0
    var dismissals = 0
    var restores = 0
    func presentOverlay() { presentations += 1 }
    func dismissOverlay() { dismissals += 1 }
    func openSettings() {}
    func openTranslator() {}
    func openTypeToClick() {}
    func restoreAfterExternalAction() { restores += 1 }
}

/// The area selector: an image, or nil for Escape.
@MainActor
private final class FakeAreaCapture: ScreenAwarenessReading {
    var area: QuickImageAttachment?
    init(area: QuickImageAttachment?) { self.area = area }
    func readContext(for target: SelectionTarget) -> CaptureContext {
        CaptureContext(appName: target.applicationName)
    }
    func captureArea() async -> QuickImageAttachment? { area }
}

/// The app in front before Quick Launch, and the text selected there.
@MainActor
private final class FakeFrontApp: SelectedTextServicing {
    var front: SelectionTarget?
    var selection = "the selected words"
    init(front: SelectionTarget?) { self.front = front }
    var isAccessibilityTrusted: Bool { true }
    func currentExternalTarget() -> SelectionTarget? { front }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        SelectedTextContext(target: target, text: selection)
    }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { true }
    func openAccessibilitySettings() {}
}

/// Continue in pi without tmux: records the thread it was given.
private final class RecordingPiHandoff: PiHandoffServicing {
    private let requests = Mutex<[PiHandoffRequest]>([])
    var handedOff: [PiHandoffRequest] { requests.withLock { $0 } }
    func handOff(_ request: PiHandoffRequest) async throws -> PiHandoffResult {
        requests.withLock { $0.append(request) }
        return PiHandoffResult(
            sessionName: "ql-test01",
            threadFile: URL(fileURLWithPath: "/tmp/ql-test01.md"),
            openedGhostty: true
        )
    }
}

@Suite("AI Chat behaviour (W2)", .serialized)
@MainActor
struct AIChatBehaviourTests {

    /// The launcher and the window on one store. The window's view model
    /// may have its own service (a gated one, to hold an answer open).
    struct Rig {
        let launcher: QuickViewModel
        let chat: QuickViewModel
        let window: AIChatWindowModel
        let fake: FakeAIChatWindow
        let service: MockQuickService
        let launcherPresenter: RecordingPresenter
        let chatPresenter: RestoreCountingPresenter
        let recorded: Recorded
    }

    @MainActor
    final class Recorded {
        var announcements: [String] = []
    }

    private func makeRig(
        chatService: (any QuickService)? = nil,
        configure: (inout QuickSettings) -> Void = { _ in }
    ) -> Rig {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        configure(&settings)
        let service = MockQuickService()
        let launcher = QuickViewModel(settings: settings, service: service)
        let launcherPresenter = RecordingPresenter()
        launcher.overlayPresenter = launcherPresenter
        let chat = QuickViewModel(store: launcher.store, service: chatService ?? service)
        // Never this Mac's Manage Models choices.
        launcher.modelPreferences = ModelPreferenceStore(fileURL: nil)
        chat.modelPreferences = ModelPreferenceStore(fileURL: nil)
        let chatPresenter = RestoreCountingPresenter()
        chat.overlayPresenter = chatPresenter
        let recorded = Recorded()
        chat.announce = { recorded.announcements.append($0) }
        launcher.announce = { recorded.announcements.append("launcher: \($0)") }
        let suite = "AIChatBehaviourTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        let fake = FakeAIChatWindow()
        window.window = fake
        launcher.aiChatOpener = { handoff in window.open(handoff: handoff) }
        return Rig(
            launcher: launcher, chat: chat, window: window, fake: fake, service: service,
            launcherPresenter: launcherPresenter, chatPresenter: chatPresenter, recorded: recorded
        )
    }

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, reply: String) async {
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    /// Asks in the window and holds the answer open after `head`.
    private func streaming(
        _ rig: Rig,
        _ gated: GatedQuickService,
        _ question: String = "tell me about Lima"
    ) async -> Task<Void, Never> {
        rig.chat.input = question
        let submit = Task { await rig.chat.submit() }
        await gated.waitUntilHolding()
        _ = await waitFor { rig.chat.output == gated.head }
        return submit
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

    private func chat(
        _ question: String,
        _ answer: String,
        model: String = InferenceProvider.deepSeekDefaultModel,
        age: TimeInterval = 60
    ) -> QuickConversation {
        QuickConversation(
            updatedAt: Date(timeIntervalSinceNow: -age),
            providerID: InferenceProvider.deepSeekID,
            model: model,
            messages: [
                QuickMessage(role: .user, content: question),
                QuickMessage(role: .assistant, content: answer),
            ]
        )
    }

    private static let image = QuickImageAttachment(data: Data([1, 2, 3]), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1)

    // MARK: - 1. The new-chat interval never applies in the window

    @Test func aFollowUpAfterTheIntervalStaysInTheWindowsChat() async throws {
        let rig = makeRig { $0.newChatInterval = .fiveMinutes }
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "first", reply: "One.")
        let id = try #require(rig.chat.currentConversation?.id)
        // Six minutes of reading.
        rig.chat.currentConversation?.updatedAt = Date(timeIntervalSinceNow: -360)
        #expect(!rig.chat.shouldStartNewConversation)
        await ask(rig.chat, rig.service, "a follow-up", reply: "Two.")
        #expect(rig.chat.currentConversation?.id == id)
        #expect(rig.chat.conversationMessages.map(\.content) == ["first", "One.", "a follow-up", "Two."])

        // Quick AI keeps the interval.
        await ask(rig.launcher, rig.service, "in the launcher", reply: "L.")
        rig.launcher.currentConversation?.updatedAt = Date(timeIntervalSinceNow: -360)
        #expect(rig.launcher.shouldStartNewConversation)
    }

    @Test func reopeningKeepsTheDraftAndANewChat() async {
        let rig = makeRig()
        rig.launcher.history = [chat("Older", "Old.")]
        rig.window.open(handoff: nil)
        #expect(rig.chat.currentConversation != nil, "the first open lands on the last chat")

        rig.chat.input = "half a question"
        rig.window.open(handoff: nil)
        #expect(rig.chat.input == "half a question", "reopening never clears the draft")

        // A new chat by hand, then the window closes and comes back.
        rig.chat.startNewChatKeepingAnswer()
        rig.chat.input = "a new start"
        rig.window.open(handoff: nil)
        #expect(rig.chat.currentConversation == nil, "the window keeps the new chat it held")
        #expect(rig.chat.input == "a new start")
    }

    // MARK: - 2. A good area capture brings the window back

    @Test func selectedAreaFromTheWindowShowsTheWindowAgain() async {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        var hides = 0
        rig.chat.prepareForExternalAction = { hides += 1 }
        var recoveries = 0
        rig.chat.recoverFromExternalActionFailure = { recoveries += 1 }
        let area = FakeAreaCapture(area: Self.image)
        rig.chat.screenAwareness = area
        rig.chat.input = "what is this"

        await rig.chat.addContext(.selectedArea)
        #expect(hides == 1)
        #expect(rig.chatPresenter.restores == 1, "a good capture restores the window")
        #expect(recoveries == 0)
        #expect(rig.chat.pendingImages == [Self.image])
        #expect(rig.chat.input == "what is this")

        // Escape in the selector: the failure path, never the restore.
        area.area = nil
        await rig.chat.addContext(.selectedArea)
        #expect(recoveries == 1)
        #expect(rig.chatPresenter.restores == 1)
    }

    @Test func theRestoreDefaultsToPresentingTheOverlay() async {
        // The launcher's presenter has no restore of its own: Quick AI's
        // panel comes back as the command path brings it back.
        let vm = QuickViewModel(service: MockQuickService())
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        vm.screenAwareness = FakeAreaCapture(area: Self.image)
        vm.openQuickAI()
        await vm.addContext(.selectedArea)
        #expect(presenter.presentations == 1)
        #expect(vm.pendingImages == [Self.image])
    }

    // MARK: - 4. Focused Window and Selected Text in the window

    @Test func theWindowReadsTheAppInFrontBeforeIt() {
        let rig = makeRig()
        let safari = SelectionTarget(processIdentifier: 4242, applicationName: "Safari")
        let front = FakeFrontApp(front: nil)
        rig.chat.selectedTextService = front
        rig.window.open(handoff: nil)

        // No app known: the two entries are not offered.
        rig.chat.aiChatWindowDidBecomeKey()
        #expect(rig.chat.addContextOptions == [.selectedArea, .entireScreen])

        front.front = safari
        rig.chat.aiChatWindowDidBecomeKey()
        #expect(rig.chat.selectionTarget == safari)
        #expect(rig.chat.addContextOptions == AddContextEntry.allCases)
        #expect(rig.chat.attachSelectedText())
        #expect(rig.chat.pendingContext?.appName == "Safari")
        #expect(rig.chat.pendingContext?.selectedText == "the selected words")

        // The launcher offers all four whatever it knows.
        #expect(rig.launcher.addContextOptions == AddContextEntry.allCases)
    }

    @Test func theEntriesNoLongerSayBehindTheOverlay() {
        for entry in AddContextEntry.allCases {
            #expect(!entry.detail.contains("overlay"), "\(entry.title)")
        }
        #expect(AddContextEntry.focusedWindow.needsPreviousApp)
        #expect(AddContextEntry.selectedText.needsPreviousApp)
        #expect(!AddContextEntry.selectedArea.needsPreviousApp)
    }

    // MARK: - 5. The model is per chat

    @Test func theChooserWritesTheOpenChatsModelOnly() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "question", reply: "Answer.")
        let before = rig.chat.settings
        let id = try #require(rig.chat.currentConversation?.id)

        rig.chat.setActiveModel(providerID: InferenceProvider.deepSeekID, model: "deepseek-v4-pro")
        #expect(rig.chat.activeModelID == "deepseek-v4-pro")
        #expect(rig.chat.settings.quickAIProviderID == before.quickAIProviderID, "the default is untouched")
        #expect(rig.chat.settings.quickAIModel == before.quickAIModel)
        #expect(rig.chat.settings.selectedModel == before.selectedModel)
        #expect(rig.chat.history.first { $0.id == id }?.model == "deepseek-v4-pro", "kept with the chat")

        // The next message uses it.
        await ask(rig.chat, rig.service, "follow-up", reply: "Again.")
        #expect(rig.chat.currentConversation?.model == "deepseek-v4-pro")
        #expect(rig.launcher.activeModelID == InferenceProvider.deepSeekDefaultModel, "the launcher is on the default")
    }

    @Test func openingAChatUsesItsModelAndLeavesTheDefault() {
        let rig = makeRig()
        let pro = chat("On pro", "P.", model: "deepseek-v4-pro")
        let flash = chat("On flash", "F.")
        rig.launcher.history = [pro, flash]
        func defaults(_ settings: QuickSettings) -> [String] {
            [settings.selectedProviderID.uuidString, settings.selectedModel,
             settings.quickAIProviderID?.uuidString ?? "", settings.quickAIModel]
        }
        let before = defaults(rig.launcher.settings)

        rig.launcher.continueConversation(itemID: pro.id.uuidString)
        #expect(rig.launcher.activeModelID == "deepseek-v4-pro")
        #expect(rig.launcher.activeModelDisplay == ModelProfile.displayName(forModelID: "deepseek-v4-pro"))
        #expect(defaults(rig.launcher.settings) == before, "opening a chat never saves a new default")
        rig.launcher.continueConversation(itemID: flash.id.uuidString)
        #expect(rig.launcher.activeModelID == InferenceProvider.deepSeekDefaultModel)
        #expect(defaults(rig.launcher.settings) == before)
    }

    @Test func aModelChangeInOneWindowLeavesTheOther() async {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "in the window", reply: "W.")
        await ask(rig.launcher, rig.service, "in the launcher", reply: "L.")
        rig.chat.setActiveModel(providerID: InferenceProvider.deepSeekID, model: "deepseek-v4-pro")
        #expect(rig.chat.activeModelID == "deepseek-v4-pro")
        #expect(rig.launcher.activeModelID == InferenceProvider.deepSeekDefaultModel)
        rig.launcher.setActiveModel(providerID: InferenceProvider.deepSeekID, model: "deepseek-reasoner")
        #expect(rig.chat.activeModelID == "deepseek-v4-pro")
    }

    @Test func aPickOnTheEmptySurfaceStartsTheNextChatAndTravels() async {
        let rig = makeRig()
        rig.launcher.openQuickAI()
        rig.launcher.setActiveModel(providerID: InferenceProvider.deepSeekID, model: "deepseek-v4-pro")
        #expect(rig.launcher.pendingModelChoice == ChatModelChoice(providerID: InferenceProvider.deepSeekID, model: "deepseek-v4-pro"))
        #expect(rig.launcher.activeModelID == "deepseek-v4-pro")
        #expect(rig.launcher.settings.quickAIModel.isEmpty)

        // ⌘J on the empty surface carries it to the window.
        rig.launcher.input = "draft"
        rig.launcher.continueInAIChat()
        #expect(rig.chat.activeModelID == "deepseek-v4-pro")
        await ask(rig.chat, rig.service, "draft", reply: "Yes.")
        #expect(rig.chat.currentConversation?.model == "deepseek-v4-pro")
        #expect(rig.chat.pendingModelChoice == nil, "the chat took it")
    }

    // MARK: - 6. ⌘J into a busy window

    @Test func aHandOffWithNoDraftKeepsTheWindowsDraftAndItsAnswer() async throws {
        let gated = GatedQuickService(head: "Lima is the capital", tail: " of Peru.")
        let rig = makeRig(chatService: gated)
        let other = chat("From the launcher", "L.")
        rig.window.open(handoff: nil)
        rig.launcher.history = [other]
        let submit = await streaming(rig, gated)
        let streamingID = try #require(rig.chat.currentConversation?.id)
        rig.chat.input = "my own draft"
        rig.chat.pendingImage = Self.image

        rig.launcher.openChatInAIChat(itemID: other.id.uuidString)
        await submit.value

        #expect(rig.chat.currentConversation?.id == other.id)
        #expect(rig.chat.input == "my own draft", "the hand-off brought none")
        #expect(rig.chat.pendingImages == [Self.image])
        let saved = try #require(rig.chat.history.first { $0.id == streamingID })
        #expect(saved.messages.map(\.content) == ["tell me about Lima", "Lima is the capital"], "the partial answer is kept")
        #expect(rig.chat.threadNotice == QuickViewModel.stoppedForHandoffNotice(chatTitle: rig.chat.title(of: saved)))
        #expect(rig.chat.threadNotice == "Stopped the answer in “Tell me about Lima”. What arrived is saved.")
        #expect(rig.chat.threadNoticeSymbol == QuickViewModel.chatNoticeSymbol)
    }

    @Test func aHandOffWithADraftReplacesTheWindowsDraft() {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        rig.chat.input = "the window's draft"
        rig.launcher.openQuickAI()
        rig.launcher.input = "the launcher's draft"
        rig.launcher.continueInAIChat()
        #expect(rig.chat.input == "the launcher's draft")
        #expect(rig.chat.threadNotice == nil, "nothing streamed, nothing to say")
    }

    @Test func aHandOffOfTheChatTheWindowHoldsLeavesItAlone() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "held", reply: "Here.")
        let id = try #require(rig.chat.currentConversation?.id)
        rig.chat.input = "typing"
        rig.window.open(handoff: AIChatHandoff(
            conversation: rig.chat.currentConversation,
            pendingChatTools: nil, input: "", pendingImages: [], pendingContext: nil
        ))
        #expect(rig.chat.currentConversation?.id == id)
        #expect(rig.chat.input == "typing")
    }

    // MARK: - 7. New Chat in the header during a stream

    @Test func newChatDuringAStreamKeepsTheTurn() async throws {
        let gated = GatedQuickService(head: "Half an answer")
        let rig = makeRig(chatService: gated)
        rig.window.open(handoff: nil)
        let submit = await streaming(rig, gated, "a long question")
        let id = try #require(rig.chat.currentConversation?.id)

        rig.chat.startNewChatKeepingAnswer()
        await submit.value

        #expect(!rig.chat.isStreaming)
        #expect(rig.chat.currentConversation == nil, "a new chat")
        let saved = try #require(rig.chat.history.first { $0.id == id })
        #expect(saved.messages.map(\.content) == ["a long question", "Half an answer"])
    }

    // MARK: - 10. Two views, one store

    @Test func theWindowFollowsTheStoreWithoutComingBack() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "first", reply: "One.")
        let id = try #require(rig.chat.currentConversation?.id)
        // A race leaves both views on the chat.
        rig.launcher.loadConversation(id: id)
        await ask(rig.launcher, rig.service, "asked in the launcher", reply: "A.")
        #expect(rig.chat.conversationMessages.map(\.content) == ["first", "One.", "asked in the launcher", "A."],
                "no window key event needed")
        #expect(rig.chat.output == "A.")

        rig.launcher.renameConversation(id: id, title: "Renamed")
        #expect(rig.chat.quickAITitle == "Renamed")
    }

    @Test func openingAChatTheOtherViewHasHandsItOver() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "in the window", reply: "W.")
        let id = try #require(rig.chat.currentConversation?.id)
        rig.chat.input = "the window's draft"

        rig.launcher.continueChatInQuickAI(itemID: id.uuidString)
        #expect(rig.launcher.currentConversation?.id == id)
        #expect(rig.chat.currentConversation == nil, "one chat, one view")
        #expect(rig.chat.input == "the window's draft")
        #expect(rig.chat.threadNotice == QuickViewModel.movedChatNotice(to: "Quick AI"))

        // And back: the rail takes it from the launcher.
        rig.window.openChat(itemID: id.uuidString)
        #expect(rig.chat.currentConversation?.id == id)
        #expect(rig.launcher.currentConversation == nil)
        #expect(rig.launcher.threadNotice == QuickViewModel.movedChatNotice(to: "AI Chat"))
        #expect(rig.chat.threadNotice == nil)
    }

    @Test func aStreamInTheViewThatLetsGoIsKept() async throws {
        let gated = GatedQuickService(head: "Partly")
        let rig = makeRig(chatService: gated)
        let existing = chat("Old question", "Old answer.")
        rig.launcher.history = [existing]
        rig.window.open(handoff: nil)
        #expect(rig.chat.currentConversation?.id == existing.id)
        let submit = await streaming(rig, gated, "and more?")

        rig.launcher.continueChatInQuickAI(itemID: existing.id.uuidString)
        await submit.value
        #expect(rig.launcher.conversationMessages.map(\.content)
            == ["Old question", "Old answer.", "and more?", "Partly"])
    }

    @Test func aChatDeletedWhileItStreamsSaysSo() async throws {
        let gated = GatedQuickService(head: "Lima is", tail: " the capital.", followUp: "New.")
        let rig = makeRig(chatService: gated)
        let existing = chat("Peru", "A country.")
        rig.launcher.history = [existing]
        rig.window.open(handoff: nil)
        let submit = await streaming(rig, gated, "its capital?")

        rig.launcher.deleteConversation(id: existing.id)
        #expect(rig.chat.isStreaming, "the stream is left alone")
        gated.release()
        await submit.value

        #expect(!rig.chat.history.contains { $0.id == existing.id }, "never brought back")
        #expect(rig.chat.threadNotice == QuickViewModel.deletedWhileAnsweringNotice)
        #expect(rig.chat.threadNotice?.hasPrefix("This chat was deleted") == true)
        #expect(rig.chat.output == "Lima is the capital.", "the answer stays on screen")
        #expect(rig.chat.quickAIDetachedAnswer == "Lima is the capital.")
        #expect(rig.chat.currentConversation == nil)

        // A refresh (the window coming back) keeps it on screen.
        rig.chat.aiChatWindowDidBecomeKey()
        #expect(rig.chat.output == "Lima is the capital.")

        // The next question starts a new chat.
        rig.chat.input = "new question"
        await rig.chat.submit()
        #expect(rig.chat.conversationMessages.map(\.content) == ["new question", "New."])
        #expect(rig.chat.threadNotice == nil)
    }

    @Test func aChatDeletedInTheOtherViewLeavesALine() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "doomed", reply: "Yes.")
        let id = try #require(rig.chat.currentConversation?.id)
        rig.chat.input = "kept"
        rig.launcher.deleteConversation(id: id)
        #expect(rig.chat.currentConversation == nil)
        #expect(rig.chat.threadNotice == QuickViewModel.deletedChatNotice)
        #expect(rig.chat.input == "kept")
        #expect(rig.chat.quickAIEmptyStateHints.isEmpty, "the line, not the hints")
    }

    // MARK: - 15. "Answer ready"

    @Test func answerReadyIsAnnouncedInTheWindowOnly() async {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "q", reply: "A.")
        #expect(rig.recorded.announcements == ["Answer ready"])
        await ask(rig.launcher, rig.service, "q", reply: "A.")
        #expect(rig.recorded.announcements == ["Answer ready"], "Quick AI stays quiet")
    }

    // MARK: - 18. Copy and Capture any message

    @Test func commandKCopiesAndCapturesAnyMessage() async throws {
        let rig = makeRig()
        let pasteboard = FakePasteboard()
        rig.chat.pasteboard = pasteboard
        let memory = FakeMemory()
        rig.chat.memoryCapture = memory
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "first question", reply: "First answer.")
        await ask(rig.chat, rig.service, "second question", reply: "Second answer.")

        rig.chat.handleCommandK()
        #expect(rig.chat.paletteSurfaceActions.suffix(2) == [.copyMessage, .captureMessage])
        rig.chat.performQuickAISurfaceAction(.copyMessage)
        #expect(rig.chat.isActionPalettePresented, "the palette stays, on the list")
        #expect(rig.chat.actionPaletteSubmenu == .messages(.copy))
        #expect(rig.chat.paletteMessageRows.map(\.content)
            == ["Second answer.", "second question", "First answer.", "first question"], "newest first")
        #expect(rig.chat.actionPaletteEntryCount == 4)
        rig.chat.actionQuery = "first answer"
        let older = try #require(rig.chat.paletteMessageRows.first)
        #expect(rig.chat.paletteMessageRows.count == 1)

        await rig.chat.performMessageAction(.copy, on: older)
        #expect(pasteboard.string == "First answer.")
        #expect(pasteboard.isTransient, "an AI answer")
        #expect(!rig.chat.isActionPalettePresented)
        #expect(rig.chat.composerConfirmation == "Copied")

        let question = try #require(rig.chat.conversationMessages.first)
        await rig.chat.performMessageAction(.copy, on: question)
        #expect(pasteboard.string == "first question")
        #expect(!pasteboard.isTransient, "the user's own text")

        rig.chat.handleCommandK()
        rig.chat.performQuickAISurfaceAction(.captureMessage)
        #expect(rig.chat.actionPaletteSubmenu == .messages(.capture))
        await rig.chat.performMessageAction(.capture, on: older)
        #expect(await memory.captured == ["First answer."])
        let stored = try #require(rig.chat.conversationMessages.first { $0.id == older.id })
        #expect(stored.tools.contains { $0.kind == .capture }, "the older answer gets the line")
        let newest = try #require(rig.chat.conversationMessages.last)
        #expect(!newest.tools.contains { $0.kind == .capture })
    }

    @Test func noMessageNoMessageActions() {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        #expect(!rig.chat.paletteSurfaceActions.contains(.copyMessage))
        #expect(QuickAISurfaceAction.copyMessage.shortcut == nil, "no key taken")
        #expect(QuickAISurfaceAction.captureMessage.shortcut == nil)
    }

    // MARK: - 22. Continue in pi while streaming

    @Test func continueInPiWhileStreamingStopsKeepsAndHandsOff() async throws {
        let gated = GatedQuickService(head: "The plan has")
        let rig = makeRig(chatService: gated)
        let pi = RecordingPiHandoff()
        rig.chat.piHandoff = pi
        rig.window.open(handoff: nil)
        let submit = await streaming(rig, gated, "walk me through the plan")
        let id = try #require(rig.chat.currentConversation?.id)

        #expect(rig.chat.resultActions == [.continueInPi], "the one action while streaming")
        #expect(rig.chat.resultActionDetail(.continueInPi) == "Stop the answer, then open pi")
        #expect(rig.chat.performShortcut(characters: "p", keyCode: 35, modifiers: [.command, .option]))
        _ = await waitFor { !pi.handedOff.isEmpty && rig.chat.threadNotice != nil }
        await submit.value

        #expect(!rig.chat.isStreaming)
        let request = try #require(pi.handedOff.first)
        #expect(request.markdown.contains("The plan has"), "pi gets what arrived")
        #expect(rig.chat.history.first { $0.id == id }?.messages.map(\.content)
            == ["walk me through the plan", "The plan has"])
        #expect(rig.chat.threadNotice == "Answer stopped. Opened in pi · tmux session ql-test01")
        #expect(rig.chat.threadNoticeSymbol == QuickViewModel.piNoticeSymbol)
    }

    @Test func continueInPiWithoutAStreamSaysNothingAboutStopping() async {
        let rig = makeRig()
        let pi = RecordingPiHandoff()
        rig.chat.piHandoff = pi
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "q", reply: "A.")
        await rig.chat.continueInPi()
        #expect(rig.chat.threadNotice == "Opened in pi · tmux session ql-test01")
    }
}
