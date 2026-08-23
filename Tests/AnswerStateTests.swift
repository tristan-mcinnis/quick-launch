import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Answer state", .serialized)
@MainActor
struct AnswerStateTests {
    private func answered(_ question: String, reply: String = "Argentina.") async -> (QuickViewModel, MockQuickService) {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        let vm = QuickViewModel(service: mock)
        vm.settings.autoCopy = false
        vm.input = question
        await vm.submit()
        return (vm, mock)
    }

    @Test func answerHidesTheLauncherAndShowsTheQuestion() async {
        let (vm, _) = await answered("who won the world cup")
        #expect(vm.output == "Argentina.")
        #expect(vm.isAnswerActive)
        #expect(vm.lastQuestion == "who won the world cup")
        #expect(vm.launcherMatches.isEmpty)
        #expect(vm.footerHints.map(\.label) == ["Paste back", "Copy", "Actions"])
        vm.input = "and"
        #expect(vm.footerHints.first?.label == "Follow up")
        vm.input = ""
        #expect(vm.resultActions.contains(.pasteBack) && vm.resultActions.contains(.renameChat))
        #expect(!vm.resultActions.contains(.previousChat), "one chat: nothing to browse")
        #expect(vm.footerContext == vm.activeModelDisplay)
    }

    @Test func backspaceOnEmptyPopsToTheRoot() async {
        let (vm, _) = await answered("hello")
        vm.startNewConversation()
        #expect(!vm.isAnswerActive)
        #expect(vm.lastQuestion == nil)
        #expect(vm.launcherMatches.count == LauncherCatalogScope.allCases.count + 1)
    }

    @Test func copyShortcutCopiesTheAnswerAndCloses() async {
        let (vm, _) = await answered("hello", reply: "Bonjour")
        var dismissed = 0
        let token = NotificationCenter.default.addObserver(forName: .dismissOverlay, object: nil, queue: nil) { _ in dismissed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(vm.performShortcut(characters: "c", keyCode: 8, modifiers: [.command, .shift]))
        try? await Task.sleep(for: .milliseconds(30))
        // Other suites share the pasteboard and the notification center, so
        // assert on this view model's own state.
        #expect(vm.justCopied)
        #expect(dismissed >= 1)
    }

    @Test func followUpKeepsTheThreadAndUpdatesTheQuestion() async {
        let (vm, mock) = await answered("first")
        await mock.setResponses([StreamDelta(text: "Second answer", finishReason: "stop")])
        vm.input = "and then?"
        await vm.submit()
        #expect(vm.lastQuestion == "and then?")
        #expect(vm.output == "Second answer")
        #expect(vm.currentConversation?.messages.count == 4)
        #expect(vm.launcherMatches.isEmpty)
    }

    @Test func commandKOnAnAnswerOpensThePaletteWithAnswerActionsFirst() async {
        let (vm, _) = await answered("hello")
        vm.handleCommandK()
        #expect(vm.isActionPalettePresented)
        #expect(!vm.isItemActionPanePresented)
        #expect(vm.resultActions.first == .pasteBack)
    }
}
