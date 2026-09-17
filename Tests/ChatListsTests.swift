// ChatListsTests — the chat lists after the v1.5 consistency audit
// (group G1): one search and one order for the Chats catalog, Recent Chats,
// and the AI Chat rail; one set of row actions with Open in AI Chat (⌘J);
// ⌘J in Recent Chats moving the highlighted chat; ⌘H and ⌘K › Recent Chats
// opening Recent Chats inside Quick AI; the ⋯ menu's chat entries; AI Chat
// as a fallback command keeping the typed text; chat actions in the ⌘K
// palette that no longer read "Answer"; and the names the audit asked to
// agree.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Chat lists", .serialized)
@MainActor
struct ChatListsTests {

    /// A launcher view model and the AI Chat window on one store, as the
    /// app wires them.
    struct Rig {
        let launcher: QuickViewModel
        let chat: QuickViewModel
        let window: AIChatWindowModel
        let fake: FakeAIChatWindow
        let service: MockQuickService
        let presenter: RecordingPresenter
    }

    private func makeRig() -> Rig {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        settings.newChatInterval = .never
        let service = MockQuickService()
        let launcher = QuickViewModel(settings: settings, service: service, pasteboard: FakePasteboard())
        let presenter = RecordingPresenter()
        launcher.overlayPresenter = presenter
        let chat = QuickViewModel(store: launcher.store, service: service)
        let suite = "ChatListsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        let fake = FakeAIChatWindow()
        window.window = fake
        launcher.aiChatOpener = { handoff in window.open(handoff: handoff) }
        return Rig(launcher: launcher, chat: chat, window: window, fake: fake, service: service, presenter: presenter)
    }

    private func conversation(
        _ question: String,
        answer: String,
        pinned: Bool = false,
        age: TimeInterval
    ) -> QuickConversation {
        var conversation = QuickConversation(
            providerID: QuickSettings().providers[0].id,
            model: "model",
            messages: [
                QuickMessage(role: .user, content: question),
                QuickMessage(role: .assistant, content: answer),
            ]
        )
        conversation.isPinned = pinned
        conversation.updatedAt = Date(timeIntervalSinceNow: -age)
        return conversation
    }

    /// Three saved chats: the pinned one is the oldest, so pinning is what
    /// puts it first.
    private func threeChats() -> [QuickConversation] {
        [
            conversation("capital of Peru", answer: "Lima is the capital.", age: 60),
            conversation("Q3 plan", answer: "Three priorities, Lima office first.", pinned: true, age: 7_200),
            conversation("release notes", answer: "Two fixes.", age: 600),
        ]
    }

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, reply: String) async {
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    private let commandJ: (characters: String, keyCode: UInt16) = ("j", 38)

    // MARK: - Item 1: ⌘J in Recent Chats moves the highlighted chat

    @Test func commandJInRecentChatsMovesTheHighlightedChatNotTheOneBehind() async throws {
        let rig = makeRig()
        rig.launcher.openQuickAI()
        await ask(rig.launcher, rig.service, "the open chat", reply: "Open.")
        let open = try #require(rig.launcher.currentConversation?.id)
        rig.launcher.history += threeChats()

        rig.launcher.openRecentChats()
        let target = try #require(rig.launcher.recentChatItems.first { $0.itemID != open.uuidString })
        rig.launcher.recentChatsIndex = try #require(rig.launcher.recentChatItems.firstIndex(of: target))
        #expect(rig.launcher.performShortcut(characters: commandJ.characters, keyCode: commandJ.keyCode, modifiers: [.command]))

        #expect(rig.fake.shows == 1)
        #expect(rig.chat.currentConversation?.id.uuidString == target.itemID, "the highlighted chat")
        #expect(rig.chat.input.isEmpty, "the list's search is not a draft")
        #expect(rig.presenter.dismissals == 1)
        #expect(rig.launcher.currentConversation?.id == open, "the chat behind the list stays here")
        #expect(!rig.launcher.isRecentChatsPresented)
    }

    @Test func theHeaderButtonInRecentChatsMovesTheHighlightedChat() async throws {
        let rig = makeRig()
        rig.launcher.history = threeChats()
        rig.launcher.openRecentChats()
        rig.launcher.moveRecentChatsSelection(1)
        let highlighted = try #require(rig.launcher.recentChatItems[safe: rig.launcher.recentChatsIndex])
        // The header's Open in AI Chat button calls the same method.
        rig.launcher.continueInAIChat()
        #expect(rig.chat.currentConversation?.id.uuidString == highlighted.itemID)
    }

    @Test func commandJOnTheOpenChatsRowMovesItAndTheLauncherLetsItGo() async throws {
        let rig = makeRig()
        rig.launcher.openQuickAI()
        await ask(rig.launcher, rig.service, "the open chat", reply: "Open.")
        let open = try #require(rig.launcher.currentConversation?.id)
        rig.launcher.openRecentChats()
        #expect(rig.launcher.recentChatItems[safe: rig.launcher.recentChatsIndex]?.itemID == open.uuidString,
                "the list opens on the open chat")
        #expect(rig.launcher.performShortcut(characters: commandJ.characters, keyCode: commandJ.keyCode, modifiers: [.command]))
        #expect(rig.chat.currentConversation?.id == open)
        #expect(rig.chat.conversationMessages.map(\.content) == ["the open chat", "Open."])
        #expect(rig.launcher.currentConversation == nil, "one chat, one window")
    }

    @Test func commandJInRecentChatsWithNoMatchMovesNothing() {
        let rig = makeRig()
        rig.launcher.history = threeChats()
        rig.launcher.openRecentChats()
        rig.launcher.input = "no chat says this"
        #expect(rig.launcher.recentChatItems.isEmpty)
        #expect(rig.launcher.performShortcut(characters: commandJ.characters, keyCode: commandJ.keyCode, modifiers: [.command]))
        #expect(rig.fake.shows == 0, "nothing moves")
        #expect(rig.launcher.isRecentChatsPresented)
    }

    @Test func everyChatRowOffersOpenInAIChatWithCommandJ() throws {
        let rig = makeRig()
        rig.launcher.history = threeChats()
        let expected = ["Continue Chat", "Open in AI Chat", "Copy Last Answer", "Rename Chat", "Unpin", "Hide from Quick Launch", "Delete Chat"]

        // The root Chats catalog.
        rig.launcher.input = ""
        rig.launcher.enterCatalog(.chats)
        #expect(rig.launcher.focusedItemActions.map(\.title) == expected)
        let open = try #require(rig.launcher.focusedItemActions.first { $0.kind == .openInAIChat })
        #expect(open.shortcut == .command("j"))
        #expect(open.shortcut == ResultAction.continueInAIChat.defaultShortcut)

        // Recent Chats: the same actions, in the same order.
        rig.launcher.openRecentChats()
        rig.launcher.recentChatsIndex = 0
        #expect(rig.launcher.focusedItemActions.map(\.title) == expected)

        // Without a window to open, the row does not offer it.
        let bare = QuickViewModel(service: MockQuickService())
        bare.history = threeChats()
        bare.input = ""
        bare.enterCatalog(.chats)
        #expect(!bare.focusedItemActions.contains { $0.kind == .openInAIChat })
    }

    @Test func commandJOnAChatsCatalogRowOpensThatChatInAIChat() throws {
        let rig = makeRig()
        rig.launcher.history = threeChats()
        rig.launcher.input = ""
        rig.launcher.enterCatalog(.chats)
        rig.launcher.applicationSelectionIndex = 2
        guard case .item(let row)? = rig.launcher.focusedLauncherResult else {
            Issue.record("a chat row is highlighted")
            return
        }
        #expect(rig.launcher.performShortcut(characters: commandJ.characters, keyCode: commandJ.keyCode, modifiers: [.command]))
        #expect(rig.fake.shows == 1)
        #expect(rig.chat.currentConversation?.id.uuidString == row.itemID)
        #expect(rig.presenter.dismissals == 1)
    }

    @Test func openInAIChatFromTheRowPaneMovesThatRow() async throws {
        let rig = makeRig()
        rig.launcher.history = threeChats()
        rig.launcher.openRecentChats()
        rig.launcher.recentChatsIndex = 2
        let row = try #require(rig.launcher.recentChatItems[safe: 2])
        rig.launcher.handleCommandK()
        #expect(rig.launcher.isCatalogActionPanePresented)
        let action = try #require(rig.launcher.focusedItemActions.first { $0.kind == .openInAIChat })
        await rig.launcher.perform(action, on: .item(row))
        #expect(rig.chat.currentConversation?.id.uuidString == row.itemID)
        #expect(!rig.launcher.isCatalogActionPanePresented)
    }

    // MARK: - Item 2: one search, one order, one set of actions

    @Test func theSharedSearchMatchesTitlesAndMessagesInOrder() {
        let chats = threeChats()
        let title: (QuickConversation) -> String = { $0.messages.first?.content ?? "" }
        #expect(QuickHistoryStore.matching(chats, query: "", title: title).map(\.id)
            == QuickHistoryStore.ordered(chats).map(\.id))
        // "lima" is in two answers, never in a title; pinned first.
        #expect(QuickHistoryStore.matching(chats, query: "LIMA", title: title).map { $0.messages[0].content }
            == ["Q3 plan", "capital of Peru"])
        // Every word must match, accents and case folded.
        #expect(QuickHistoryStore.matching(chats, query: "péru capital", title: title).map { $0.messages[0].content }
            == ["capital of Peru"])
        #expect(QuickHistoryStore.matching(chats, query: "peru release", title: title).isEmpty)
    }

    @Test func theCatalogRecentChatsAndTheRailShowTheSameRows() {
        let rig = makeRig()
        rig.launcher.history = threeChats()
        let expectedOrder = QuickHistoryStore.ordered(rig.launcher.history).map(\.id.uuidString)

        rig.launcher.input = ""
        rig.launcher.enterCatalog(.chats)
        #expect(rig.launcher.catalogMatches.map(\.itemID) == expectedOrder)
        rig.launcher.input = "lima"
        let catalog = rig.launcher.catalogMatches.map(\.itemID)
        #expect(catalog.count == 2, "the catalog searches message text too")

        rig.launcher.openRecentChats()
        #expect(rig.launcher.recentChatItems.map(\.itemID) == expectedOrder)
        rig.launcher.input = "lima"
        #expect(rig.launcher.recentChatItems.map(\.itemID) == catalog)

        rig.window.railQuery = "lima"
        #expect(rig.window.railItems.map(\.itemID) == catalog)
        rig.window.railQuery = ""
        #expect(rig.window.railItems.map(\.itemID) == expectedOrder)
    }

    @Test func learnedFavouritesNeverReorderTheChatsCatalog() async {
        let rig = makeRig()
        rig.launcher.settings.launcherLearningEnabled = true
        rig.launcher.history = threeChats()
        rig.launcher.input = ""
        rig.launcher.enterCatalog(.chats)
        // Continue the oldest unpinned chat a few times: learning sees it.
        let oldest = rig.launcher.catalogMatches[2]
        for _ in 0..<3 {
            rig.launcher.enterCatalog(.chats)
            rig.launcher.learn(.item(oldest))
        }
        rig.launcher.closeQuickAI()
        rig.launcher.input = ""
        rig.launcher.enterCatalog(.chats)
        #expect(rig.launcher.catalogMatches.map(\.itemID)
            == QuickHistoryStore.ordered(rig.launcher.history).map(\.id.uuidString))
    }

    @Test func returnOnAChatsCatalogRowContinuesItInQuickAI() async throws {
        let rig = makeRig()
        rig.launcher.history = threeChats()
        rig.launcher.input = ""
        rig.launcher.enterCatalog(.chats)
        rig.launcher.applicationSelectionIndex = 1
        let result = try #require(rig.launcher.focusedLauncherResult)
        guard case .item(let row) = result else {
            Issue.record("a chat row is highlighted")
            return
        }
        await rig.launcher.performLauncherResult(result)
        #expect(rig.launcher.isQuickAIPresented)
        #expect(rig.launcher.catalogScope == nil)
        #expect(rig.launcher.currentConversation?.id.uuidString == row.itemID)
        #expect(rig.launcher.lastQuestion == rig.launcher.currentConversation?.messages.first?.content,
                "↑ has the last question to recall")
        #expect(rig.fake.shows == 0, "Return stays in Quick AI; ⌘J is the window")
    }

    @Test func commandPOpensRecentChatsInsideQuickAIAndCommandHDoesNot() async {
        let rig = makeRig()
        rig.launcher.openQuickAI()
        await ask(rig.launcher, rig.service, "a question", reply: "An answer.")

        // `⌘H` was the v1.4 alias. It is Hide now, and inside Quick AI it
        // must reach nothing at all: no layer, no notice.
        #expect(!rig.launcher.performShortcut(characters: "h", keyCode: 4, modifiers: [.command]))
        #expect(!rig.launcher.isRecentChatsPresented)
        #expect(rig.launcher.errorMessage == nil)

        #expect(rig.launcher.performShortcut(characters: "p", keyCode: 35, modifiers: [.command]))
        #expect(rig.launcher.isRecentChatsPresented)
        #expect(rig.launcher.isQuickAIPresented)
        #expect(rig.launcher.catalogScope == nil, "never the root Chats catalog")
        #expect(rig.launcher.currentConversation != nil, "the chat stays behind the list")
    }

    @Test func thePaletteListsRecentChatsWithCommandP() async {
        let rig = makeRig()
        rig.launcher.history = threeChats()
        // The empty surface, before the first answer.
        rig.launcher.openQuickAI()
        rig.launcher.handleCommandK()
        #expect(rig.launcher.isActionPalettePresented)
        #expect(rig.launcher.paletteResultActions.contains(.recentChats))
        #expect(ResultAction.recentChats.title == "Recent Chats")
        #expect(ResultAction.recentChats.defaultShortcut == QuickViewModel.recentChatsShortcut)
        #expect(ResultAction.recentChats.defaultShortcut.keyCaps == ["⌘", "P"])
        await rig.launcher.performResultAction(.recentChats)
        #expect(rig.launcher.isRecentChatsPresented)
        #expect(!rig.launcher.isActionPalettePresented)
        #expect(rig.launcher.catalogScope == nil)
    }

    @Test func theAIChatWindowLeavesRecentChatsToItsRail() async {
        let rig = makeRig()
        rig.launcher.history = threeChats()
        rig.window.open(handoff: nil)
        rig.chat.handleCommandK()
        #expect(!rig.chat.paletteResultActions.contains(.recentChats))
    }

    // MARK: - Item 3: the names agree

    @Test func theNamesAgree() {
        #expect(LauncherCatalogScope.chats.title == "Chats")
        let row = LauncherCatalogItem(kind: .conversation, itemID: UUID().uuidString, title: "A chat", detail: "", value: "")
        #expect(LauncherResultRow.typeLabel(for: .item(row)) == "Chat")
        #expect(ResultAction.continueInAIChat.title == "Open in AI Chat")
        #expect(ResultAction.continueInAIChat.defaultShortcut.keyCaps == ["⌘", "J"])
        #expect(ChatMenuEntry.allCases.map(\.title) == ["New Chat", "Recent Chats", "Open AI Chat"])
        #expect(ChatMenuEntry.recentChats.menuTitle(.defaults) == "Recent Chats  ⌘P")
        let actions = ItemActionCatalog.actions(for: .item(row), pasteTarget: nil)
        #expect(actions.first { $0.kind == .openInAIChat }?.title == "Open in AI Chat")
        // "AI Chat" names the window only: its root command.
        #expect(makeRig().launcher.aiChatCommand.title == "AI Chat")
    }

    // MARK: - Item 4: the ⋯ menu's chat entries

    @Test func newChatKeepsTheChatInHistoryAndOpensQuickAIEmpty() async throws {
        let rig = makeRig()
        rig.launcher.openQuickAI()
        await ask(rig.launcher, rig.service, "keep me", reply: "Kept.")
        let kept = try #require(rig.launcher.currentConversation?.id)
        // Escape keeps the chat; the menu is in root search.
        rig.launcher.closeQuickAI()
        rig.launcher.input = "half typed search"

        rig.launcher.performChatMenuEntry(.newChat)
        #expect(rig.launcher.isQuickAIPresented, "New Chat opens Quick AI")
        #expect(rig.launcher.currentConversation == nil)
        #expect(rig.launcher.conversationMessages.isEmpty)
        #expect(rig.launcher.input.isEmpty)
        #expect(rig.launcher.history.contains { $0.id == kept }, "the kept chat stays in history")
        #expect(rig.launcher.recentChatItems.contains { $0.itemID == kept.uuidString })
    }

    @Test func recentChatsEntryIsCommandPsPath() async throws {
        let rig = makeRig()
        rig.launcher.history = threeChats()
        // From the root Chats catalog: the scope clears.
        rig.launcher.input = ""
        rig.launcher.enterCatalog(.chats)
        #expect(rig.launcher.isChatMenuEntryEnabled(.recentChats))
        rig.launcher.performChatMenuEntry(.recentChats)
        #expect(rig.launcher.isRecentChatsPresented)
        #expect(rig.launcher.isQuickAIPresented)
        #expect(rig.launcher.catalogScope == nil)
        #expect(rig.launcher.recentChatItems.map(\.itemID)
            == QuickHistoryStore.ordered(rig.launcher.history).map(\.id.uuidString), "the ordered list")
        rig.launcher.recentChatsIndex = 1
        let picked = try #require(rig.launcher.recentChatItems[safe: 1])
        rig.launcher.openSelectedRecentChat()
        #expect(rig.launcher.currentConversation?.id.uuidString == picked.itemID)
        #expect(rig.launcher.lastQuestion == rig.launcher.currentConversation?.messages.first?.content,
                "↑ recalls the chat's last question")

        let empty = QuickViewModel(service: MockQuickService())
        #expect(!empty.isChatMenuEntryEnabled(.recentChats), "nothing to list")
    }

    @Test func openAIChatEntryOpensTheWindowWhenThereIsOne() {
        let rig = makeRig()
        #expect(rig.launcher.chatMenuEntries == [.newChat, .recentChats, .openAIChat])
        rig.launcher.performChatMenuEntry(.openAIChat)
        #expect(rig.fake.shows == 1)
        #expect(rig.presenter.dismissals == 1)

        let bare = QuickViewModel(service: MockQuickService())
        #expect(bare.chatMenuEntries == [.newChat, .recentChats], "no window to open")
    }

    // MARK: - Item 9: AI Chat as a fallback command

    @Test func aiChatAsAFallbackCommandCarriesTheTypedText() async {
        let rig = makeRig()
        rig.launcher.history = [conversation("an old chat", answer: "Old.", age: 60)]
        rig.launcher.input = "plan the offsite agenda"
        await rig.launcher.runFallbackCommand(
            FallbackCommandID.command(QuickViewModel.aiChatCommandID),
            text: "plan the offsite agenda"
        )
        #expect(rig.fake.shows == 1)
        #expect(rig.chat.input == "plan the offsite agenda", "the text is the window's draft")
        #expect(rig.chat.conversationMessages.isEmpty, "a new chat; nothing is sent")
        #expect(await rig.service.sendCallCount == 0)
        #expect(rig.launcher.input.isEmpty)
        #expect(rig.presenter.dismissals == 1)
    }

    @Test func theAIChatRowRunFromSearchIsNotADraft() async throws {
        let rig = makeRig()
        rig.launcher.input = "ai chat"
        let command = try #require(rig.launcher.systemCommands.first { $0.itemID == QuickViewModel.aiChatCommandID })
        await rig.launcher.performLauncherItem(command)
        #expect(rig.fake.shows == 1)
        #expect(rig.chat.input.isEmpty, "the search that found the command is not a question")
    }

    // MARK: - Item 14: the palette groups chat actions as "Chat"

    @Test func chatActionsReadChatInThePalette() async {
        let rig = makeRig()
        rig.launcher.openQuickAI()
        await ask(rig.launcher, rig.service, "a question", reply: "An answer.")
        let chatLevel: [ResultAction] = [
            .copyChat, .continueInPi, .continueInAIChat, .changeModel, .changeAssistant, .newChat,
            .recentChats, .previousChat, .nextChat, .renameChat, .pinChat, .deleteChat, .tools,
        ]
        for action in chatLevel {
            #expect(action.paletteGroup == "Chat", "\(action.title)")
        }
        for action in [ResultAction.copy, .pasteBack, .regenerate, .readAloud, .saveSnippet, .searchWeb] {
            #expect(action.paletteGroup == "Answer", "\(action.title)")
        }
        // What the palette draws: an action's own detail, else its group.
        rig.launcher.handleCommandK()
        let drawn = rig.launcher.paletteResultActions.map { rig.launcher.resultActionDetail($0) ?? $0.paletteGroup }
        for (action, detail) in zip(rig.launcher.paletteResultActions, drawn) where chatLevel.contains(action) {
            #expect(detail != "Answer", "\(action.title) reads \(detail)")
        }
        // Each chat action says what it does; none repeats its title's noun.
        for action in [ResultAction.copyChat, .newChat, .recentChats, .renameChat, .pinChat, .deleteChat] {
            let detail = rig.launcher.resultActionDetail(action)
            #expect(detail != nil, "\(action.title) has its own line")
            #expect(detail != "Answer" && detail != "Chat")
        }
        #expect(rig.launcher.resultActionDetail(.pinChat) == "Keep this chat at the top")
        await rig.launcher.performResultAction(.pinChat)
        #expect(rig.launcher.resultActionDetail(.pinChat) == "Unpin this chat")
        // An answer action with nothing to add still reads "Answer".
        #expect(rig.launcher.resultActionDetail(.copy) == nil)
        #expect(ResultAction.copy.paletteGroup == "Answer")
    }

    // MARK: - Item 17: the old conversation view is gone

    @Test func theOldConversationViewLeftNoCode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = [
            "Sources/ViewModels/QuickViewModel.swift",
            "Sources/App/AppDelegate.swift",
            "Sources/Views/CodeBlockView.swift",
            "Sources/Views/MarkdownTextView.swift",
        ]
        for path in sources {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(!text.contains("isConversationHistoryPresented"), "\(path)")
            #expect(!text.contains("toggleConversationHistory"), "\(path)")
            #expect(!text.contains("overlay answer"), "\(path)")
            #expect(!text.contains("openChatHistory"), "\(path)")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
