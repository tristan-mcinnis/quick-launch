import Testing
import Foundation
@testable import QuickLaunch

@MainActor
final class RecordingPresenter: OverlayPresenting {
    var dismissals = 0
    var presentations = 0
    func presentOverlay() { presentations += 1 }
    func dismissOverlay() { dismissals += 1 }
    func openSettings() {}
    func openTranslator() {}
    func openTypeToClick() {}
}

@MainActor
@Suite("Overlay layer stack", .serialized)
struct OverlayLayerTests {

    private func makeModel() -> (QuickViewModel, RecordingPresenter) {
        let vm = QuickViewModel(service: MockQuickService())
        vm.settings.autoCopy = false
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        return (vm, presenter)
    }

    @Test("Escape clears typed text before it closes the overlay")
    func escapeClearsTypedTextFirst() {
        let (vm, presenter) = makeModel()
        vm.input = "half typed"
        #expect(vm.topLayer == .typedText)
        vm.handleEscapeKey()
        #expect(vm.input.isEmpty)
        #expect(presenter.dismissals == 0)
        vm.handleEscapeKey()
        #expect(presenter.dismissals == 1)
    }

    @Test("Escape on a finished answer returns to root search and keeps the thread")
    func escapeOnAnswerReturnsToRoot() {
        let (vm, presenter) = makeModel()
        vm.output = "42"
        #expect(vm.isQuickAIPresented, "an answer presents the Quick AI surface")
        #expect(vm.topLayer == .answer)
        vm.handleEscapeKey()
        #expect(presenter.dismissals == 0)
        #expect(!vm.isQuickAIPresented)
        #expect(vm.output == "42", "the thread is kept behind root search")
        #expect(vm.topLayer == .root)
        vm.handleEscapeKey()
        #expect(presenter.dismissals == 1)
    }

    @Test("Empty Backspace and Escape pop the same stack in the same order")
    func backspaceAndEscapeShareStack() {
        let (vm, _) = makeModel()
        vm.enterCatalog(.chats)
        vm.enterInputMode(.caffeinateUntil)
        vm.input = "text"
        #expect(vm.topLayer == .typedText)
        vm.handleEscapeKey()
        #expect(vm.topLayer == .inputMode)
        #expect(vm.popLayerForEmptyBackspace())
        #expect(vm.inputMode == nil)
        #expect(vm.topLayer == .root)
        #expect(!vm.popLayerForEmptyBackspace())
    }

    @Test("Escape cancels a stream before anything else")
    func escapeCancelsStream() {
        let (vm, presenter) = makeModel()
        vm.isStreaming = true
        vm.streamingStatus = "Thinking"
        vm.input = "typed"
        vm.handleEscapeKey()
        #expect(!vm.isStreaming)
        #expect(vm.streamingStatus == nil)
        #expect(vm.input == "typed")
        #expect(presenter.dismissals == 0)
    }

    @Test("Panes and the palette are exclusive by construction")
    func presentedLayerIsExclusive() {
        let (vm, _) = makeModel()
        vm.isActionPalettePresented = true
        vm.isCatalogActionPanePresented = true
        #expect(!vm.isActionPalettePresented)
        #expect(vm.isCatalogActionPanePresented)
        vm.isCatalogActionPanePresented = false
        #expect(vm.presentedLayer == nil)
    }

    @Test("reset(.all) leaves no stale state behind")
    func resetAllClearsEverything() {
        let (vm, _) = makeModel()
        vm.enterCatalog(.chats)
        vm.input = "x"
        vm.output = "y"
        vm.errorMessage = "e"
        vm.isStreaming = true
        vm.streamingStatus = "s"
        vm.lastQuestion = "q"
        vm.isActionPalettePresented = true
        vm.actionQuery = "a"
        vm.reset(.all)
        #expect(vm.catalogScope == nil)
        #expect(vm.input.isEmpty)
        #expect(vm.output.isEmpty)
        #expect(vm.errorMessage == nil)
        #expect(!vm.isStreaming)
        #expect(vm.streamingStatus == nil)
        #expect(vm.lastQuestion == nil)
        #expect(vm.presentedLayer == nil)
        #expect(vm.actionQuery.isEmpty)
        #expect(vm.topLayer == .root)
    }

    @Test("Quick Link hotkey entry goes through one entry point")
    func enterQuickLinkInputResetsModes() {
        let (vm, _) = makeModel()
        vm.enterInputMode(.caffeinateUntil)
        vm.enterQuickLinkInput(itemID: "ql")
        #expect(vm.inputMode == nil)
        #expect(vm.catalogScope == nil)
        #expect(vm.pendingQuickLinkID == "ql")
        #expect(vm.topLayer == .quickLinkInput)
    }

    @Test("Bare Return on an answer does nothing")
    func bareReturnOnAnswerIsNoOp() async {
        let (vm, presenter) = makeModel()
        vm.output = "answer"
        #expect(vm.classifySubmit() == .answerIdle)
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.output == "answer")
        #expect(presenter.dismissals == 0)
    }

    @Test("Return and the live row agree on a local answer")
    func returnMatchesLocalAnswerRow() async {
        let (vm, _) = makeModel()
        vm.input = "2+2"
        let rowAnswer = vm.launcherMatches.compactMap { result -> String? in
            if case .item(let item) = result, item.kind == .answer { return item.value }
            return nil
        }.first
        #expect(rowAnswer == "4")
        // Return runs the highlighted answer row: copy and close, like any row.
        #expect(vm.classifySubmit() == .launcherRow(0))
        // With no row highlighted (direct submit) the same resolver answers.
        vm.input = "2+2"
        await vm.submit()
        #expect(vm.output == "4")
    }
}
