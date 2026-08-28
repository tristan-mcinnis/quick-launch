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

    @Test func answerWidensThePanel() async {
        let (vm, _) = await answered("hello")
        #expect(vm.currentPanelWidth == QuickViewModel.panelWidthForAnswer)
        vm.startNewConversation()
        #expect(vm.currentPanelWidth == QuickViewModel.panelWidth)
    }

    @Test func chatHistoryActionOpensTheChatsCatalog() async {
        let (vm, _) = await answered("hello")
        #expect(vm.resultActions.contains(.chatHistory), "a saved chat means history is browsable")
        vm.openChatHistory()
        #expect(vm.catalogScope == .chats)
        #expect(!vm.isAnswerActive)
        #expect(vm.output.isEmpty)
        #expect(vm.currentConversation == nil)
        #expect(vm.launcherMatches.count == 1, "the saved chat shows as a row")
    }

    @Test func paletteOffersAttachCommandsEverywhere() async {
        let (vm, _) = await answered("hello")
        let titles = vm.paletteAttachCommands.map(\.title)
        #expect(titles.contains("Attach Latest Screenshot"))
        #expect(titles.contains("Send Focused Window to AI"))
        // The filter narrows by title, best match first.
        vm.actionQuery = "attach"
        #expect(vm.paletteCommandMatches.first?.title == "Attach Latest Screenshot")
        #expect(
            vm.actionPaletteEntryCount
                >= vm.paletteResultActions.count + vm.paletteCommandMatches.count
        )
    }

    @Test func paletteAttachKeepsTheTypedQuestion() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-palette-attach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ScreenAwarenessTests.writeImage(
            to: folder.appendingPathComponent("Screenshot 2026-08-27 at 11.00.00.png"),
            text: "Palette"
        )
        let vm = QuickViewModel(service: MockQuickService())
        vm.screenshotsFolder = folder
        vm.isActionPalettePresented = true
        vm.input = "what is in this shot"
        guard let latest = vm.paletteAttachCommands.first(where: {
            $0.itemID == LatestScreenshotFinder.commandID
        }) else {
            Issue.record("Attach Latest Screenshot missing from the palette")
            return
        }
        await vm.runPaletteCommand(latest)
        #expect(vm.pendingImage != nil)
        #expect(vm.input == "what is in this shot", "the half-typed question survives the attach")
        #expect(!vm.isActionPalettePresented)
    }
}
