import Foundation
import Testing
@testable import QuickLaunch

/// A dismissal clears what the overlay put on screen (`AppDelegate`
/// `hideOverlay` → `resetOverlaySurface` → `clearTransientDisplay`), either at
/// once ("Do not keep", retention 0) or when the retention window ends.
/// Neither may cut an answer that is still streaming: the request owns its
/// text until the turn ends, so the clear waits and the saved answer keeps
/// its whole prefix. Once the turn ends the surface is cleared as before.
@Suite("Quick AI answer retention across a dismissal", .serialized)
@MainActor
struct QuickAIAnswerRetentionTests {

    private func settings(retention: Int) -> QuickSettings {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        settings.reopenRetentionSeconds = retention
        return settings
    }

    /// Asks in the overlay and returns the submit task once `Head. ` is on
    /// screen and the stream is held open.
    private func streaming(
        _ vm: QuickViewModel,
        _ gated: GatedQuickService,
        question: String = "Q"
    ) async -> Task<Void, Never> {
        vm.openQuickAI()
        vm.input = question
        let submit = Task { await vm.submit() }
        await gated.waitUntilHolding()
        _ = await waitFor { vm.output == gated.head }
        return submit
    }

    private func waitFor(
        _ timeout: Duration = .seconds(15),
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        // Generous on purpose: this Mac may be running several builds and
        // suites at once, and a correct test that waits longer costs nothing.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        if await condition() { return true }
        Issue.record("waitFor timed out after \(timeout)")
        return false
    }

    // MARK: - The two retention routes

    /// `reopenRetentionSeconds == 0` ("Do not keep"): `hideOverlay` clears the
    /// surface at once, which is this call. The answer still streaming keeps
    /// its prefix, and the turn's saved text is the whole answer.
    @Test func zeroRetentionClearDuringAStreamKeepsTheWholeAnswer() async {
        let gated = GatedQuickService(head: "Head. ", tail: "Tail.")
        let vm = QuickViewModel(settings: settings(retention: 0), service: gated)
        let submit = await streaming(vm, gated)

        // What AppDelegate.swift's `guard seconds > 0 else { resetOverlaySurface }`
        // does the moment the panel is dismissed.
        vm.clearTransientDisplay()

        #expect(vm.isStreaming, "the turn kept running, so the clear is the trigger")
        #expect(vm.output == "Head. ", "a live answer keeps the text already shown")
        #expect(vm.lastQuestion == "Q", "the live turn keeps its question")

        await gated.release()
        await submit.value

        #expect(vm.conversationMessages.map(\.content) == ["Q", "Head. Tail."],
                "the saved turn is the whole answer, not its tail")
        #expect(vm.output.isEmpty, "the dismissed surface still clears when the turn ends")
        #expect(vm.lastQuestion == nil)
        #expect(vm.isQuickAIPresented == false, "the cleared surface is not left open")
    }

    /// The default retention (10 s): the timer's clear arrives mid-stream.
    /// Same contract, and the turn's text reaches the persisted chat.
    @Test func defaultRetentionClearDuringAStreamKeepsTheWholeAnswer() async {
        let gated = GatedQuickService(head: "Head. ", tail: "Tail.")
        var settings = settings(retention: 10)
        settings.historyEnabled = true
        let vm = QuickViewModel(settings: settings, service: gated)
        let submit = await streaming(vm, gated)

        // What `overlayClearTask` runs when the retention window ends.
        vm.clearTransientDisplay()

        await gated.release()
        await submit.value

        #expect(vm.conversationMessages.map(\.content) == ["Q", "Head. Tail."])
        let saved = vm.history.first { $0.id == vm.currentConversation?.id }
        #expect(saved?.messages.last?.content == "Head. Tail.",
                "the persisted chat keeps the whole answer")
        #expect(vm.output.isEmpty, "the dismissed surface is cleared once the turn ends")
    }

    /// The reader comes back inside the retention window. The clear was only
    /// waiting for the turn, so returning cancels it: the answer stays on the
    /// surface instead of vanishing under the reader when the stream ends.
    @Test func reopeningBeforeTheDeferredClearKeepsTheAnswerOnScreen() async {
        let gated = GatedQuickService(head: "Head. ", tail: "Tail.")
        let vm = QuickViewModel(settings: settings(retention: 10), service: gated)
        let submit = await streaming(vm, gated)

        vm.clearTransientDisplay()
        // What `AppDelegate.showOverlay()` does when the panel comes back
        // inside the retention window.
        vm.cancelDeferredTransientClear()
        vm.openQuickAI()

        await gated.release()
        await submit.value

        #expect(vm.output == "Head. Tail.", "a reopened surface keeps its answer")
        #expect(vm.isQuickAIPresented)
        #expect(vm.conversationMessages.map(\.content) == ["Q", "Head. Tail."])
    }

    // MARK: - Stop and promotion during the deferred clear

    /// Stop after a dismissal keeps what arrived, as Stop always does, and
    /// the dismissed surface is cleared once the cancelled turn settles.
    @Test func stoppingAfterADismissalKeepsThePartialAnswer() async {
        let gated = GatedQuickService(head: "Head. ", tail: "Tail.")
        let vm = QuickViewModel(settings: settings(retention: 0), service: gated)
        let submit = await streaming(vm, gated)

        vm.clearTransientDisplay()
        vm.cancel()
        await submit.value

        #expect(vm.conversationMessages.map(\.content) == ["Q", "Head. "],
                "Stop keeps the question and what arrived")
        #expect(vm.output.isEmpty)
        #expect(vm.isStreaming == false)
    }

    /// Open in AI Chat moves a chat that is still streaming to the window,
    /// as it always has: the chat stops and keeps what arrived, and the
    /// launcher's waiting clear never touches the window's chat.
    @Test func openingInAIChatAfterADismissalHandsOffThePartialAnswer() async {
        let gated = GatedQuickService(head: "Head. ", tail: "Tail.")
        let vm = QuickViewModel(settings: settings(retention: 0), service: gated)
        var handedOff: AIChatHandoff?
        vm.aiChatOpener = { handoff in handedOff = handoff }
        let submit = await streaming(vm, gated)

        vm.clearTransientDisplay()
        vm.continueInAIChat()
        await submit.value

        #expect(handedOff?.conversation?.messages.last?.content == "Head. ",
                "the window gets the stopped chat with what arrived")
        #expect(vm.output.isEmpty, "the launcher let the chat go")
        #expect(vm.isTransientClearDeferred == false,
                "the launcher holds no clear for a chat it handed off")
    }

    /// A dismissed surface with a live answer takes no new clear request
    /// after the turn settles: the deferred clear runs once, and a finished
    /// turn still clears immediately as it always did.
    @Test func aFinishedTurnStillClearsAtOnce() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Head. Tail.", finishReason: "stop")])
        let vm = QuickViewModel(settings: settings(retention: 0), service: service)
        vm.openQuickAI()
        vm.input = "Q"
        await vm.submit()

        #expect(vm.output == "Head. Tail.")
        vm.clearTransientDisplay()
        #expect(vm.output.isEmpty)
        #expect(vm.conversationMessages.map(\.content) == ["Q", "Head. Tail."],
                "clearing the surface keeps the saved chat")
    }

    // MARK: - A waiting clear never outlives the turn it was made for

    /// A waiting clear belongs to the turn that was streaming when it was
    /// asked for. A question asked on the surface next supersedes it: the old
    /// turn's settle must not clear the new answer off the screen.
    @Test func aNewQuestionSupersedesAClearWaitingOnTheEarlierTurn() async {
        let gated = GatedQuickService(head: "Head. ", tail: "Tail.")
        let vm = QuickViewModel(settings: settings(retention: 0), service: gated)
        let first = await streaming(vm, gated, question: "First")

        vm.clearTransientDisplay()
        #expect(vm.isTransientClearDeferred, "the dismissal is waiting on the live turn")

        // A question asked on the surface (the submit seam every ask uses).
        vm.input = "Second"
        await vm.submit()
        await gated.release()
        await first.value

        #expect(vm.isTransientClearDeferred == false)
        #expect(vm.output == gated.followUp,
                "the earlier turn's waiting clear did not take the new answer")
        #expect(vm.conversationMessages.map(\.content) == ["First", "Second", gated.followUp],
                "both questions and the new answer are in the one chat")
    }

    /// A new chat drops a waiting clear with the thread it described: the old
    /// turn cannot run it over the new chat, and its answer stays put.
    @Test func aNewChatDiscardsAClearWaitingOnTheOldTurn() async {
        let gated = GatedQuickService(head: "Head. ", tail: "Tail.")
        let vm = QuickViewModel(settings: settings(retention: 0), service: gated)
        let first = await streaming(vm, gated, question: "First")

        vm.clearTransientDisplay()
        #expect(vm.isTransientClearDeferred)

        vm.startNewConversation()
        #expect(vm.isTransientClearDeferred == false,
                "the new chat discards the old thread's waiting clear")

        vm.openQuickAI()
        vm.input = "Second"
        await vm.submit()
        await gated.release()
        await first.value

        #expect(vm.output == gated.followUp, "the settled old turn cleared nothing")
        #expect(vm.conversationMessages.map(\.content) == ["Second", gated.followUp])
    }
}
