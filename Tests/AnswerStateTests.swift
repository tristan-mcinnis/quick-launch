import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Answer state", .serialized)
@MainActor
struct AnswerStateTests {
    /// A fake pasteboard, and chat history off unless a test needs it.
    /// History never has a file here (no `historyFileURL`), so even with it
    /// on a run never writes the user's clipboard or chat file.
    private func answered(
        _ question: String,
        reply: String = "Argentina.",
        keepsHistory: Bool = false
    ) async -> (QuickViewModel, MockQuickService) {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        var settings = QuickSettings()
        settings.historyEnabled = keepsHistory
        let vm = QuickViewModel(settings: settings, service: mock, pasteboard: FakePasteboard())
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
        #expect(vm.isQuickAIPresented, "an answer lives on the Quick AI surface")
        // The surface has no footer: the composer names what Return does.
        #expect(vm.quickAIComposerAction == .init(label: "Paste Response", keys: ["↩"]))
        vm.input = "and"
        #expect(vm.quickAIComposerAction.label == "Ask")
        vm.input = ""
        #expect(vm.resultActions.contains(.pasteBack) && vm.resultActions.contains(.renameChat))
        #expect(!vm.resultActions.contains(.previousChat), "one chat: nothing to browse")
        #expect(vm.quickAITitle == "Who won the world cup", "the question, cleaned up into a title")
    }

    @Test func backspaceOnEmptyPopsToTheRootAndKeepsTheThread() async {
        let (vm, _) = await answered("hello")
        #expect(vm.popLayerForEmptyBackspace())
        #expect(!vm.isAnswerActive)
        #expect(!vm.isQuickAIPresented)
        #expect(vm.output == "Argentina.", "the thread is kept behind root search")
        #expect(vm.currentConversation != nil)
        #expect(vm.launcherMatches.count == LauncherCatalogScope.allCases.count + 1)
        #expect(!vm.popLayerForEmptyBackspace(), "root: nothing left to pop")
    }

    @Test func newChatKeepsTheSurfaceAndEmptiesTheThread() async {
        let (vm, _) = await answered("hello")
        vm.startNewConversation()
        #expect(vm.isQuickAIPresented, "⌘N starts a new chat on the surface")
        #expect(vm.lastQuestion == nil)
        #expect(vm.output.isEmpty)
        #expect(vm.quickAITitle == "Quick AI")
        #expect(vm.launcherMatches.isEmpty)
    }

    @Test func copyShortcutCopiesTheAnswerAndStaysOpen() async {
        let (vm, _) = await answered("hello", reply: "Bonjour")
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        #expect(vm.performShortcut(characters: "c", keyCode: 8, modifiers: [.command, .shift]))
        try? await Task.sleep(for: .milliseconds(30))
        #expect((vm.pasteboard as? FakePasteboard)?.string == "Bonjour")
        #expect(vm.justCopied)
        #expect(presenter.dismissals == 0, "Copy Answer keeps the Quick AI surface open")
        #expect(vm.isQuickAIPresented)
        #expect(vm.composerConfirmation == "Copied", "the composer shows the checkmark")
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

    @Test func anAnswerOpensTheFixedQuickAISurface() async {
        let (vm, _) = await answered("hello")
        #expect(vm.currentPanelWidth == PanelSizing.panelWidth)
        #expect(vm.estimatedWindowHeight == PanelSizing.quickAIHeight)
        vm.closeQuickAI()
        #expect(vm.currentPanelWidth == PanelSizing.panelWidth)
        #expect(
            vm.estimatedWindowHeight == PanelSizing.panelHeight(
                errorMessage: nil,
                suggestionCount: vm.launcherMatches.count,
                showsFooter: true,
                launcherRowCount: vm.launcherMatches.count
            ),
            "root search measures its rows again"
        )
    }

    @Test func recentChatsActionOpensRecentChatsInsideQuickAI() async {
        let (vm, _) = await answered("hello", keepsHistory: true)
        #expect(vm.resultActions.contains(.recentChats), "a saved chat means history is browsable")
        let open = vm.currentConversation?.id
        await vm.performResultAction(.recentChats)
        #expect(vm.isRecentChatsPresented, "Recent Chats, inside Quick AI")
        #expect(vm.isQuickAIPresented)
        #expect(vm.catalogScope == nil, "never the root Chats catalog")
        #expect(vm.currentConversation?.id == open, "the chat stays behind the list")
        #expect(vm.recentChatItems.count == 1, "the saved chat shows as a row")
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
