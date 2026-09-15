// AIChatWindowTests — the AI Chat window (plan Phase B2): one conversation
// window over the same providers and tools, its own view model sharing the
// launcher's store, Open in AI Chat (⌘J) from Quick AI, the chat list
// rail, find in chat, the multi-line composer, Keep on Top, and the keys.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@MainActor
final class FakeAIChatWindow: AIChatWindowPresenting {
    var shows = 0
    var captureHides = 0
    var onTop: [Bool] = []
    func showWindow() { shows += 1 }
    func hideWindowForCapture() { captureHides += 1 }
    func setAlwaysOnTop(_ onTop: Bool) { self.onTop.append(onTop) }
}

@Suite("AI Chat window", .serialized)
@MainActor
struct AIChatWindowTests {

    /// The app's wiring, in memory: a launcher view model and the window's
    /// own view model on one store, the window model, and a fake window.
    struct Rig {
        let launcher: QuickViewModel
        let chat: QuickViewModel
        let window: AIChatWindowModel
        let fake: FakeAIChatWindow
        let service: MockQuickService
        let presenter: RecordingPresenter
        let defaults: UserDefaults
    }

    private func makeRig(configure: (inout QuickSettings) -> Void = { _ in }) -> Rig {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        configure(&settings)
        let service = MockQuickService()
        let launcher = QuickViewModel(settings: settings, service: service)
        let presenter = RecordingPresenter()
        launcher.overlayPresenter = presenter
        let chat = QuickViewModel(store: launcher.store, service: service)
        let suite = "AIChatWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        let fake = FakeAIChatWindow()
        window.window = fake
        launcher.aiChatOpener = { handoff in window.open(handoff: handoff) }
        return Rig(
            launcher: launcher, chat: chat, window: window, fake: fake,
            service: service, presenter: presenter, defaults: defaults
        )
    }

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, reply: String) async {
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    private func conversation(_ title: String, answer: String, pinned: Bool = false, age: TimeInterval) -> QuickConversation {
        var conversation = QuickConversation(
            providerID: QuickSettings().providers[0].id,
            model: "model",
            messages: [
                QuickMessage(role: .user, content: title),
                QuickMessage(role: .assistant, content: answer),
            ]
        )
        conversation.isPinned = pinned
        conversation.updatedAt = Date(timeIntervalSinceNow: -age)
        return conversation
    }

    // MARK: - Contract

    @Test func theContractNamesTheBoundary() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let contract = try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(contract.contains(
            "AI Chat is one conversation window over the same providers and tools. No autonomy, no projects, no automations, no file changes; those belong to pi."
        ))
        #expect(contract.contains("It is not a general chat workspace or an autonomous desktop agent."))
    }

    @Test func bothChatSurfacesOfferAttachFromTheKeyboardAndPalette() throws {
        let rig = makeRig()
        rig.launcher.openQuickAI()
        rig.window.open(handoff: nil)
        for chat in [rig.launcher, rig.chat] {
            chat.input = "a draft to keep"
            #expect(chat.performShortcut(characters: "a", keyCode: 0, modifiers: [.command, .shift]))
            #expect(chat.isAddContextMenuPresented)
            #expect(chat.input == "a draft to keep")
            chat.closeAddContextMenu()
            chat.handleCommandK()
            chat.actionQuery = "attach"
            let action = try #require(chat.paletteSurfaceActions.first { $0.title == "Attach…" })
            chat.performQuickAISurfaceAction(action)
            #expect(chat.isAddContextMenuPresented)
            #expect(!chat.isActionPalettePresented)
            #expect(chat.input == "a draft to keep")
            #expect(chat.handleEscapeKey())
            #expect(!chat.isAddContextMenuPresented)
        }
    }

    // MARK: - One store, two views

    @Test func theWindowSharesTheStoreButNotTheComposer() async {
        let rig = makeRig()
        #expect(rig.chat.store === rig.launcher.store)
        rig.launcher.input = "half a question"
        rig.chat.input = "something else"
        #expect(rig.launcher.input == "half a question", "the window never steals the launcher's composer")
        await ask(rig.chat, rig.service, "asked in the window", reply: "Answer.")
        #expect(rig.launcher.history.contains { $0.messages.first?.content == "asked in the window" })
        #expect(rig.launcher.currentConversation == nil, "the launcher's thread is its own")
        rig.chat.settings.quickAIPrimaryAction = .pasteToActiveApp
        #expect(rig.launcher.settings.quickAIPrimaryAction == .pasteToActiveApp, "one settings value")
    }

    // MARK: - One store, two views: no stale copies

    /// Both views on one chat: the window asks first, then the launcher
    /// loads the same chat. Opening a chat from a list hands it over
    /// (`continueConversation`), so only a race leaves both views on one
    /// chat; the merge is the net under that race.
    private func bothOnOneChat(_ rig: Rig) async throws -> UUID {
        await ask(rig.chat, rig.service, "first", reply: "One.")
        let id = try #require(rig.chat.currentConversation?.id)
        rig.launcher.loadConversation(id: id)
        #expect(rig.launcher.currentConversation?.id == id)
        #expect(rig.chat.currentConversation?.id == id)
        return id
    }

    private func contents(_ vm: QuickViewModel, _ id: UUID) -> [String] {
        vm.history.first { $0.id == id }?.messages.map(\.content) ?? []
    }

    @Test func aFollowUpAskedInTheOtherViewIsKept() async throws {
        let rig = makeRig()
        let id = try await bothOnOneChat(rig)
        await ask(rig.launcher, rig.service, "asked in the launcher", reply: "A.")
        await ask(rig.chat, rig.service, "asked in the window", reply: "B.")
        #expect(contents(rig.chat, id) == ["first", "One.", "asked in the launcher", "A.", "asked in the window", "B."])
        #expect(rig.chat.currentConversation?.messages.map(\.content) == contents(rig.chat, id),
                "the window's thread shows the launcher's turn too")
    }

    @Test func aSaveMergesTheOtherViewsTurnsWrittenSinceItRead() async throws {
        let rig = makeRig()
        let id = try await bothOnOneChat(rig)
        await ask(rig.launcher, rig.service, "asked in the launcher", reply: "A.")
        // The window writes without asking first (a stream that began before
        // the launcher's answer landed).
        rig.chat.currentConversation?.messages.append(QuickMessage(role: .user, content: "late"))
        rig.chat.currentConversation?.messages.append(QuickMessage(role: .assistant, content: "Late."))
        rig.chat.currentConversation?.updatedAt = Date()
        rig.chat.persistCurrentConversation()
        #expect(contents(rig.chat, id) == ["first", "One.", "asked in the launcher", "A.", "late", "Late."])
    }

    @Test func reopeningTheWindowReadsTheStore() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        let id = try await bothOnOneChat(rig)
        await ask(rig.launcher, rig.service, "asked in the launcher", reply: "A.")
        rig.window.open(handoff: nil)
        #expect(rig.chat.currentConversation?.id == id)
        #expect(rig.chat.conversationMessages.map(\.content) == ["first", "One.", "asked in the launcher", "A."])
        #expect(rig.chat.output == "A.")
    }

    @Test func aChatDeletedInTheOtherViewStaysDeleted() async throws {
        let rig = makeRig()
        let id = try await bothOnOneChat(rig)
        rig.launcher.deleteConversation(id: id)
        // A save from the window never brings it back...
        rig.chat.persistCurrentConversation()
        #expect(!rig.chat.history.contains { $0.id == id })
        // ...and the next question starts a new chat.
        await ask(rig.chat, rig.service, "after the delete", reply: "New.")
        #expect(!rig.chat.history.contains { $0.id == id })
        #expect(rig.chat.currentConversation?.id != id)
        #expect(rig.chat.conversationMessages.map(\.content) == ["after the delete", "New."])
    }

    @Test func clearHistoryDropsTheChatTheOtherViewShows() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        _ = try await bothOnOneChat(rig)
        rig.launcher.clearHistory()
        rig.chat.refreshOpenChatFromStore()
        #expect(rig.chat.currentConversation == nil)
        rig.chat.persistCurrentConversation()
        #expect(rig.chat.history.isEmpty)
    }

    @Test func aRenameOrPinInTheOtherViewIsNotReverted() async throws {
        let rig = makeRig()
        let id = try await bothOnOneChat(rig)
        rig.window.showRail()
        rig.window.beginRenamingChat(id: id)
        rig.window.renameText = "Renamed in the window"
        rig.window.commitRename()
        rig.chat.togglePinConversation(id: id)
        await ask(rig.launcher, rig.service, "asked in the launcher", reply: "A.")
        let stored = try #require(rig.launcher.history.first { $0.id == id })
        #expect(stored.customTitle == "Renamed in the window")
        #expect(stored.isPinned)
        #expect(rig.launcher.currentConversation?.customTitle == "Renamed in the window", "the launcher's header follows")
        // And the other way round: the launcher renames, the window asks.
        rig.launcher.renameConversation(id: id, title: "Renamed in the launcher")
        rig.launcher.togglePinConversation(id: id)
        await ask(rig.chat, rig.service, "asked in the window", reply: "B.")
        let after = try #require(rig.chat.history.first { $0.id == id })
        #expect(after.customTitle == "Renamed in the launcher")
        #expect(!after.isPinned)
        #expect(after.messages.map(\.content).suffix(4) == ["asked in the launcher", "A.", "asked in the window", "B."])
    }

    // MARK: - Lifecycle

    @Test func openingShowsTheWindowOnTheLastChat() {
        let rig = makeRig()
        let older = conversation("Older", answer: "Old.", age: 600)
        let newer = conversation("Newer", answer: "New.", pinned: false, age: 30)
        let pinnedOld = conversation("Pinned", answer: "Pin.", pinned: true, age: 900)
        rig.launcher.history = [pinnedOld, older, newer]

        rig.window.open(handoff: nil)
        #expect(rig.fake.shows == 1)
        #expect(rig.chat.currentConversation?.id == newer.id, "the most recently updated chat, not the first pin")
        #expect(rig.chat.isQuickAIPresented)
        #expect(!rig.window.isRailVisible, "the chat list is hidden by default")
    }

    @Test func reopeningKeepsTheSameChat() async {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "first", reply: "One.")
        let id = rig.chat.currentConversation?.id
        #expect(id != nil)
        rig.window.open(handoff: nil)
        #expect(rig.chat.currentConversation?.id == id)
        #expect(rig.fake.shows == 2)
    }

    @Test func aStaleChatStaysOpenInTheWindow() async {
        let rig = makeRig { $0.newChatInterval = .fifteenMinutes }
        let yesterday = conversation("Yesterday", answer: "Old.", age: 86_400)
        rig.launcher.history = [yesterday]
        rig.window.open(handoff: nil)
        #expect(rig.chat.currentConversation?.id == yesterday.id, "the Start New Chat interval never applies in AI Chat")
        #expect(rig.chat.quickAIComposerPlaceholder == QuickViewModel.quickAIFollowUpPlaceholder)
        await ask(rig.chat, rig.service, "and after that?", reply: "New.")
        #expect(rig.chat.currentConversation?.id == yesterday.id, "a follow-up stays in the chat")
        #expect(rig.chat.conversationMessages.map(\.content) == ["Yesterday", "Old.", "and after that?", "New."])
    }

    @Test func theRootCommandOpensTheWindowAndClosesTheLauncher() async throws {
        let rig = makeRig()
        let command = try #require(rig.launcher.systemCommands.first { $0.itemID == QuickViewModel.aiChatCommandID })
        #expect(command.title == "AI Chat")
        await rig.launcher.performLauncherItem(command)
        #expect(rig.fake.shows == 1)
        #expect(rig.presenter.dismissals == 1)

        let bare = QuickViewModel(service: MockQuickService())
        #expect(!bare.systemCommands.contains { $0.itemID == QuickViewModel.aiChatCommandID },
                "no command without a window to open")
    }

    // MARK: - ⌘J: Open in AI Chat

    @Test func commandJHandsTheConversationToTheWindow() async {
        let rig = makeRig()
        rig.launcher.pendingChatTools = [.web]
        rig.launcher.openQuickAI()
        await ask(rig.launcher, rig.service, "what happened", reply: "An answer.")
        let id = rig.launcher.currentConversation?.id
        let model = rig.launcher.activeModelID
        rig.launcher.input = "and then"
        let image = QuickImageAttachment(data: Data([1, 2, 3]), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1)
        rig.launcher.pendingImage = image

        #expect(rig.launcher.resultActions.contains(.continueInAIChat))
        #expect(rig.launcher.performShortcut(characters: "j", keyCode: 38, modifiers: [.command]))

        #expect(rig.fake.shows == 1)
        #expect(rig.chat.currentConversation?.id == id, "the same conversation id")
        #expect(rig.chat.conversationMessages.map(\.content) == ["what happened", "An answer."])
        #expect(rig.chat.activeModelID == model)
        #expect(rig.chat.currentConversation?.enabledTools == [.web], "the chat's tools")
        #expect(rig.chat.pendingImages == [image], "the attachments")
        #expect(rig.chat.input == "and then", "what was typed")
        #expect(rig.chat.output == "An answer.")
        // The launcher lets the chat go and closes.
        #expect(rig.launcher.currentConversation == nil)
        #expect(rig.launcher.input.isEmpty)
        #expect(rig.launcher.pendingImages.isEmpty)
        #expect(rig.presenter.dismissals == 1)
    }

    @Test func commandJCarriesPendingChipsAndAReadStillRunningGoesOnThere() async throws {
        let extractor = FakeAttachmentExtractor()
        await extractor.set(.content(AttachmentFlowTests.document("ready.txt", text: "Ready text.")), for: "ready.txt")
        await extractor.set(.content(AttachmentFlowTests.document("slow.pdf", text: "Slow text.")), for: "slow.pdf")
        await extractor.hold("slow.pdf")
        var settings = QuickSettings()
        settings.autoCopy = false
        let service = MockQuickService()
        let launcher = QuickViewModel(settings: settings, service: service, attachmentExtractor: extractor)
        launcher.overlayPresenter = RecordingPresenter()
        let chat = QuickViewModel(store: launcher.store, service: service, attachmentExtractor: extractor)
        let suite = "AIChatWindowTests.\(UUID().uuidString)"
        let window = AIChatWindowModel(chat: chat, defaults: UserDefaults(suiteName: suite)!)
        window.window = FakeAIChatWindow()
        launcher.aiChatOpener = { handoff in window.open(handoff: handoff) }

        launcher.openQuickAI()
        launcher.attachmentTray.add(.file(AttachmentFlowTests.file("ready.txt")))
        await launcher.attachmentTray.waitUntilRead()
        launcher.attachmentTray.add(.file(AttachmentFlowTests.file("slow.pdf")))
        launcher.input = "compare"
        #expect(launcher.attachmentTray.isReading)

        launcher.continueInAIChat()

        #expect(launcher.attachmentTray.isEmpty, "the chips left the launcher")
        #expect(chat.attachmentTray.items.map(\.name) == ["ready.txt", "slow.pdf"])
        #expect(chat.attachmentTray.items.last?.isReading == true)
        #expect(chat.input == "compare")
        await extractor.release("slow.pdf")
        await chat.attachmentTray.waitUntilRead()
        #expect(chat.attachmentTray.readyContents.map(\.ref.name) == ["ready.txt", "slow.pdf"])
        #expect(await extractor.requested.filter { $0 == "slow.pdf" }.count == 1, "moved over, not read again")
    }

    @Test func commandJKeepsAModelChangedAfterTheLastAnswer() async throws {
        let rig = makeRig()
        rig.launcher.openQuickAI()
        await ask(rig.launcher, rig.service, "question", reply: "Answer.")
        let provider = try #require(rig.launcher.activeProvider)
        rig.launcher.setActiveModel(providerID: provider.id, model: "another-model")
        let chosen = rig.launcher.activeModelID
        #expect(chosen == "another-model")
        rig.launcher.continueInAIChat()
        #expect(rig.chat.activeModelID == chosen)
    }

    @Test func commandJWorksOnTheEmptySurfaceToo() {
        let rig = makeRig()
        rig.launcher.openQuickAI()
        rig.launcher.input = "draft"
        #expect(rig.launcher.performShortcut(characters: "j", keyCode: 38, modifiers: [.command]))
        #expect(rig.fake.shows == 1)
        #expect(rig.chat.input == "draft")
    }

    @Test func commandJWithoutAWindowDoesNothing() async {
        let vm = QuickViewModel(service: MockQuickService())
        vm.openQuickAI()
        #expect(!vm.performShortcut(characters: "j", keyCode: 38, modifiers: [.command]))
        #expect(!vm.resultActions.contains(.continueInAIChat))
    }

    // MARK: - The window's own actions

    @Test func theWindowLeavesOutLauncherOnlyActionsAndCopies() async {
        let rig = makeRig { $0.quickAIPrimaryAction = .pasteToActiveApp }
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "q", reply: "A.")
        rig.chat.input = ""
        let actions = rig.chat.resultActions
        #expect(!actions.contains(.pasteBack))
        #expect(!actions.contains(.recentChats))
        #expect(!actions.contains(.continueInAIChat))
        #expect(actions.contains(.copy))
        #expect(rig.chat.quickAIComposerAction == .init(label: "Copy Response", keys: ["↩"]))
        #expect(rig.launcher.primaryAnswerAction == .pasteToActiveApp, "the launcher keeps its setting")
        #expect(rig.chat.paletteSurfaceActions == [.attach, .showChatList, .findInChat, .keepOnTop, .copyMessage])
    }

    @Test func renameFromThePaletteGoesToTheChatList() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "rename me", reply: "Sure.")
        let id = try #require(rig.chat.currentConversation?.id)
        await rig.chat.performResultAction(.renameChat)
        #expect(rig.chat.inputMode == nil, "never the launcher's rename mode")
        #expect(rig.window.isRailVisible)
        #expect(rig.window.renamingChatID == id)
        #expect(rig.window.focus == .rename)
        rig.window.renameText = "Renamed"
        #expect(rig.window.handleReturn())
        #expect(rig.chat.history.first { $0.id == id }?.customTitle == "Renamed")
        #expect(rig.window.renamingChatID == nil)
    }

    @Test func keepOnTopIsRememberedAndAppliedToTheWindow() {
        let rig = makeRig()
        #expect(!rig.window.isAlwaysOnTop)
        rig.chat.performQuickAISurfaceAction(.keepOnTop)
        #expect(rig.window.isAlwaysOnTop)
        #expect(rig.fake.onTop == [true])
        #expect(rig.defaults.bool(forKey: AIChatWindowModel.alwaysOnTopDefaultsKey))
        let again = AIChatWindowModel(chat: QuickViewModel(store: rig.launcher.store), defaults: rig.defaults)
        #expect(again.isAlwaysOnTop, "remembered")
        #expect(rig.chat.paletteSurfaceActions.contains(.stopKeepingOnTop))
    }

    // MARK: - The chat list rail

    @Test func theRailTogglesOnItsKeyAndTheHeaderButton() {
        let rig = makeRig()
        rig.launcher.history = [conversation("One", answer: "1", age: 10)]
        rig.window.open(handoff: nil)
        #expect(!rig.window.isRailVisible)
        // ⌘\ belongs to RTI's global hotkey; the list is ⌃⌘S, the macOS sidebar key.
        #expect(!rig.window.handleKeyEquivalent(characters: "\\", keyCode: 42, modifiers: [.command]))
        #expect(!rig.window.isRailVisible)
        #expect(rig.window.handleKeyEquivalent(characters: "s", keyCode: 1, modifiers: [.control, .command]))
        #expect(rig.window.isRailVisible)
        #expect(rig.window.focus == .rail, "the keyboard goes to its search")
        #expect(rig.window.handleKeyEquivalent(characters: "s", keyCode: 1, modifiers: [.control, .command]))
        #expect(!rig.window.isRailVisible)
        #expect(rig.window.focus == .composer)
        // The header button runs the same toggle.
        rig.window.toggleRail()
        #expect(rig.window.isRailVisible)
        // ⌘P, Recent Chats in Quick AI, is the chat list here.
        rig.window.hideRail()
        #expect(rig.window.handleKeyEquivalent(characters: "p", keyCode: 35, modifiers: [.command]))
        #expect(rig.window.isRailVisible)
        #expect(!rig.chat.isRecentChatsPresented, "never Quick AI's Recent Chats in the window")
    }

    @Test func theRailListsPinnedThenRecentAndSearches() {
        let rig = makeRig()
        let a = conversation("Budget review", answer: "Numbers.", age: 60)
        let b = conversation("Trip plan", answer: "Kyoto in spring.", pinned: true, age: 600)
        let c = conversation("Release notes", answer: "v1.5.0.", age: 5)
        rig.launcher.history = [a, b, c]
        rig.window.showRail()
        #expect(rig.window.pinnedRailItems.map(\.title) == ["Trip plan"])
        #expect(rig.window.recentRailItems.map(\.title) == ["Release notes", "Budget review"])
        #expect(rig.window.railItems.map(\.title) == ["Trip plan", "Release notes", "Budget review"])
        rig.window.railQuery = "kyoto"
        #expect(rig.window.railItems.map(\.title) == ["Trip plan"], "message text is searched too")
        // Escape clears the search, then slides the list out.
        #expect(rig.window.handleEscape())
        #expect(rig.window.railQuery.isEmpty)
        #expect(rig.window.isRailVisible)
        #expect(rig.window.handleEscape())
        #expect(!rig.window.isRailVisible)
    }

    @Test func arrowsAndReturnOpenAChatAndCommandDigitsJump() {
        let rig = makeRig()
        let a = conversation("Alpha", answer: "A.", age: 30)
        let b = conversation("Beta", answer: "B.", age: 60)
        let c = conversation("Gamma", answer: "C.", age: 90)
        rig.launcher.history = [a, b, c]
        rig.window.open(handoff: nil)
        #expect(rig.chat.currentConversation?.id == a.id)
        rig.window.showRail()
        #expect(rig.window.railIndex == 0, "the open chat is highlighted")
        #expect(rig.window.handleRailArrow(1))
        #expect(rig.window.handleReturn())
        #expect(rig.chat.currentConversation?.id == b.id)
        #expect(rig.window.focus == .composer)
        #expect(rig.window.handleKeyEquivalent(characters: "3", keyCode: 20, modifiers: [.command]))
        #expect(rig.chat.currentConversation?.id == c.id)
        #expect(rig.window.handleKeyEquivalent(characters: "9", keyCode: 25, modifiers: [.command]),
                "a number past the list is still the window's")
        #expect(rig.chat.currentConversation?.id == c.id)
    }

    @Test func commandKOnARowPinsRenamesAndDeletesTwice() throws {
        let rig = makeRig()
        let a = conversation("Alpha", answer: "A.", age: 30)
        let b = conversation("Beta", answer: "B.", age: 60)
        rig.launcher.history = [a, b]
        rig.window.open(handoff: nil)
        rig.window.showRail()
        rig.window.moveRailSelection(1)
        #expect(rig.window.highlightedRailItem?.title == "Beta")

        #expect(rig.window.handleKeyEquivalent(characters: "k", keyCode: 40, modifiers: [.command]))
        #expect(rig.window.railActionsPresented)
        #expect(!rig.chat.isActionPalettePresented, "⌘K on a row is the row's, not the chat's")
        #expect(rig.window.railActions == [.pin, .rename, .delete])
        #expect(rig.window.title(of: .pin) == "Pin Chat")
        rig.window.activateRailSelection()
        #expect(rig.chat.history.first { $0.id == b.id }?.isPinned == true)
        #expect(rig.window.highlightedRailItem?.title == "Beta", "the highlight follows the row into Pinned")

        // The row keys work without the menu: ⌃X twice deletes.
        #expect(rig.window.handleKeyEquivalent(characters: "x", keyCode: 7, modifiers: [.control]))
        #expect(rig.chat.history.contains { $0.id == b.id }, "the first press arms")
        #expect(rig.window.title(of: .delete) == "Press Again to Delete")
        #expect(rig.window.handleKeyEquivalent(characters: "x", keyCode: 7, modifiers: [.control]))
        #expect(!rig.chat.history.contains { $0.id == b.id })
        #expect(rig.chat.currentConversation?.id == a.id, "the open chat stays")

        // ⌘E renames the highlighted row in place.
        #expect(rig.window.handleKeyEquivalent(characters: "e", keyCode: 14, modifiers: [.command]))
        #expect(rig.window.renamingChatID == a.id)
        #expect(rig.window.renameText == "Alpha")
        #expect(rig.window.handleEscape())
        #expect(rig.window.renamingChatID == nil)
    }

    @Test func aRailSearchIsOneRankedResultsListWithSnippets() throws {
        let rig = makeRig()
        let pinned = conversation("Old notes", answer: "The kyoto budget, in short.", pinned: true, age: 60)
        let title = conversation("Kyoto trip", answer: "Temples.", age: 86_400 * 3)
        let body = conversation("Spring plans", answer: "Kyoto in spring is busy.", age: 30)
        rig.launcher.history = [pinned, title, body]
        rig.window.showRail()
        #expect(!rig.window.isRailSearching)
        #expect(rig.window.pinnedRailItems.map(\.title) == ["Old notes"])

        rig.window.railQuery = "kyoto"
        #expect(rig.window.isRailSearching, "Pinned and Recent give way to Results")
        #expect(rig.window.pinnedRailItems.isEmpty)
        #expect(rig.window.recentRailItems.isEmpty)
        let items = rig.window.railItems
        #expect(items.map(\.title) == ["Kyoto trip", "Old notes", "Spring plans"],
                "the title hit first; the pin is only a small boost")
        #expect(items[1].isPinned, "a pinned row keeps its glyph")
        #expect(rig.window.railSnippet(for: items[0]) == nil, "a title hit needs no snippet")
        let snippet = try #require(rig.window.railSnippet(for: items[2]))
        #expect(snippet.label == "Answer:")
        #expect(snippet.runs.filter(\.isMatch).map(\.text) == ["Kyoto"])
        // ⌘1…⌘9 follow the drawn order.
        #expect(rig.window.handleKeyEquivalent(characters: "3", keyCode: 20, modifiers: [.command]))
        #expect(rig.chat.currentConversation?.id == body.id)
        // One letter is not a search.
        rig.window.railQuery = "k"
        #expect(!rig.window.isRailSearching)
        #expect(rig.window.railItems.count == 3)
    }

    @Test func theOpenChatIsMarkedApartFromTheHighlightAndCommandShowsNumbers() {
        let rig = makeRig()
        let a = conversation("Alpha", answer: "A.", age: 30)
        let b = conversation("Beta", answer: "B.", age: 60)
        rig.launcher.history = [a, b]
        rig.window.open(handoff: nil)
        rig.window.showRail()
        rig.window.moveRailSelection(1)
        #expect(rig.window.highlightedRailItem?.title == "Beta")
        #expect(rig.window.openChatItemID == a.id.uuidString, "the open chat is Alpha, not the highlight")
        #expect(rig.window.railNumber(at: 0) == 1)
        #expect(rig.window.railNumber(at: 8) == 9)
        #expect(rig.window.railNumber(at: 9) == nil)
        #expect(!rig.window.isCommandHeld)
        rig.window.isCommandHeld = true
        #expect(rig.window.isCommandHeld)
        #expect(rig.window.railDetail(for: rig.window.railItems[0]).hasPrefix("1 question · "))
    }

    @Test func theRowContextMenuPinsRenamesAndDeletesThatRow() throws {
        let rig = makeRig()
        let a = conversation("Alpha", answer: "A.", age: 30)
        let b = conversation("Beta", answer: "B.", age: 60)
        let c = conversation("Gamma", answer: "C.", age: 90)
        rig.launcher.history = [a, b, c]
        rig.window.open(handoff: nil)
        rig.window.showRail()
        #expect(rig.window.highlightedRailItem?.title == "Alpha")
        let gamma = try #require(rig.window.railItems.first { $0.title == "Gamma" })
        #expect(rig.window.title(of: .pin, for: gamma) == "Pin Chat")

        // The menu acts on its own row, not on the highlighted one.
        rig.window.performRailAction(.pin, itemID: gamma.itemID)
        #expect(rig.chat.history.first { $0.id == c.id }?.isPinned == true)
        #expect(rig.window.highlightedRailItem?.title == "Gamma")
        #expect(rig.window.title(of: .pin, for: rig.window.highlightedRailItem) == "Unpin Chat")

        // Delete twice, as everywhere.
        rig.window.performRailAction(.delete, itemID: b.id.uuidString)
        #expect(rig.chat.history.contains { $0.id == b.id })
        let beta = try #require(rig.window.railItems.first { $0.itemID == b.id.uuidString })
        #expect(rig.window.title(of: .delete, for: beta) == "Press Again to Delete")
        rig.window.performRailAction(.delete, itemID: b.id.uuidString)
        #expect(!rig.chat.history.contains { $0.id == b.id })

        rig.window.performRailAction(.rename, itemID: a.id.uuidString)
        #expect(rig.window.renamingChatID == a.id)
        #expect(rig.window.focus == .rename)
    }

    @Test func theEmptyRailSaysWhyItIsEmpty() {
        let rig = makeRig { $0.historyEnabled = false }
        rig.window.open(handoff: nil)
        rig.window.showRail()
        #expect(rig.window.railItems.isEmpty)
        #expect(rig.window.railEmptyText == "Chat history is off")
        rig.window.railQuery = "anything"
        #expect(rig.window.railEmptyText == "No chats match")
        let on = makeRig()
        #expect(on.window.railEmptyText == "No chats yet")
    }

    // MARK: - Find in chat

    @Test func findCountsHitsAndMovesAcrossMessagesAndOpensAFoldedQuestion() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        let long = String(repeating: "A long question about temples and old gardens. ", count: 30) + "Is kyoto best?"
        await ask(rig.chat, rig.service, long, reply: "Kyoto is lovely in spring. Kyoto has maples too.")
        await ask(rig.chat, rig.service, "and in autumn?", reply: "Autumn in Kyoto has maples.")
        let messages = rig.chat.conversationMessages
        #expect(rig.chat.collapseState(for: messages[0]).isCollapsible)
        #expect(!rig.chat.collapseState(for: messages[0]).displayedText.contains("kyoto"), "the hit is past the preview")

        #expect(rig.window.handleKeyEquivalent(characters: "f", keyCode: 3, modifiers: [.command]))
        #expect(rig.window.isFindPresented)
        #expect(rig.window.focus == .find)
        rig.window.findQuery = "KYOTO"
        // Hits, not messages: one in the question, two in the first answer,
        // one in the last.
        #expect(rig.window.findHits.map(\.messageID) == [messages[0].id, messages[1].id, messages[1].id, messages[3].id])
        #expect(rig.window.findHits.map(\.part) == [.question, .segment(0), .segment(0), .segment(0)])
        #expect(rig.window.findStatus == "1 of 4")
        #expect(rig.window.currentMatchID == messages[0].id)
        #expect(rig.chat.expandedTranscriptMessageIDs.contains(messages[0].id), "a folded question with the hit opens")
        #expect(rig.chat.threadScrollRequest?.target == .messageOffset(messages[0].id, 0),
                "the hit, not the message's head, is what the thread scrolls to")

        #expect(rig.window.handleReturn(), "↩ is the next hit")
        #expect(rig.window.currentHit?.messageID == messages[1].id)
        #expect(rig.window.currentHit?.range == TextRange(location: 0, length: 5))
        #expect(rig.window.handleKeyEquivalent(characters: "g", keyCode: 5, modifiers: [.command]))
        #expect(rig.window.currentHit?.messageID == messages[1].id, "the second hit in the same answer")
        #expect(rig.window.currentHit?.range == TextRange(location: 27, length: 5))
        #expect(rig.window.findStatus == "3 of 4")
        rig.window.findNext()
        #expect(rig.window.currentHit?.messageID == messages[3].id)
        #expect(rig.window.handleShiftReturn() == .handled, "⇧↩ is the previous hit")
        #expect(rig.window.findStatus == "3 of 4")
        rig.window.findNext()
        rig.window.findNext()
        #expect(rig.window.currentMatchID == messages[0].id, "it wraps")

        rig.window.findQuery = "nothing like this"
        #expect(rig.window.findStatus == "No matches")
        #expect(rig.window.currentMatchID == nil)
        #expect(rig.window.findHighlights == nil)

        #expect(rig.window.handleEscape())
        #expect(!rig.window.isFindPresented, "esc closes the bar")
        #expect(rig.window.focus == .composer)
    }

    @Test func findMatchesTheRenderedTextNotTheMarkdown() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        let answer = """
        **Build** the app on _Thursday_. See [the notes](https://example.com/secret-plan) first.

        ```swift
        let build = Build()
        print(build)
        ```

        Then ship.
        """
        await ask(rig.chat, rig.service, "the plan?", reply: answer)
        let answerID = try #require(rig.chat.conversationMessages.last?.id)
        rig.window.openFind()

        // Across bold: the reader sees "Build the".
        rig.window.findQuery = "build the"
        #expect(rig.window.findHits.count == 1)
        #expect(rig.window.findHits.first?.part == .segment(0))
        #expect(rig.window.findHits.first?.range == TextRange(location: 0, length: 9))

        // Markdown syntax and a link's hidden target never match.
        for syntax in ["**", "_Thursday_", "secret-plan", "example.com", "```"] {
            rig.window.findQuery = syntax
            #expect(rig.window.findHits.isEmpty, "\(syntax) is not drawn")
        }
        // The link's text is drawn, so it matches.
        rig.window.findQuery = "the notes"
        #expect(rig.window.findHits.count == 1)

        // Code blocks are searched in their own text: "build" is twice in
        // the code and once in the prose.
        rig.window.findQuery = "build"
        let hits = rig.window.findHits
        #expect(hits.count == 4)
        #expect(hits.map(\.part) == [.segment(0), .segment(1), .segment(1), .segment(1)])
        #expect(hits.allSatisfy { $0.messageID == answerID })
        rig.window.findNext()
        #expect(rig.window.currentHit?.part == .segment(1), "next moves into the code block")
        let highlights = try #require(rig.window.findHighlights)
        #expect(highlights.segmentRanges(in: answerID)[1]?.count == 3)
        #expect(highlights.current(in: answerID)?.part == .segment(1))

        // Accents and width fold, as in the chat search.
        rig.window.findQuery = "ＴＨＵＲＳＤＡＹ"
        #expect(rig.window.findHits.count == 1)
    }

    @Test func aMeasuredHitScrollsAgainOnlyWhenItMoved() async throws {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "question", reply: "one match here, and a match there")
        rig.window.openFind()
        rig.window.findQuery = "match"
        let hit = try #require(rig.window.currentHit)
        #expect(rig.chat.threadScrollRequest?.target == .messageOffset(hit.messageID, 0))
        let revision = rig.chat.threadScrollRequest?.revision

        // The thread measured the hit 120 points under the message's head.
        rig.window.noteFindHitOffset(120, for: hit)
        #expect(rig.chat.threadScrollRequest?.target == .messageOffset(hit.messageID, 120))
        let measured = rig.chat.threadScrollRequest?.revision
        #expect(measured != revision)
        // The same measure again does not scroll again.
        rig.window.noteFindHitOffset(120, for: hit)
        #expect(rig.chat.threadScrollRequest?.revision == measured)
        // A hit that is not current never scrolls.
        let other = try #require(rig.window.findHits.last)
        rig.window.noteFindHitOffset(300, for: other)
        #expect(rig.chat.threadScrollRequest?.revision == measured)
        // Back on a hit that was measured, the scroll uses the measure.
        rig.window.findNext()
        rig.window.findPrevious()
        #expect(rig.chat.threadScrollRequest?.target == .messageOffset(hit.messageID, 120))
    }

    // MARK: - The multi-line composer

    @Test func returnSendsAndShiftReturnIsANewLine() async {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await rig.service.setResponses([StreamDelta(text: "Two lines, got it.", finishReason: "stop")])
        rig.window.noteFocus(.composer, true)
        #expect(rig.window.handleShiftReturn() == .insertNewline)
        rig.chat.input = "first line\nsecond line"
        #expect(rig.window.handleReturn())
        await rig.chat.composerSubmitTask?.value
        #expect(rig.chat.conversationMessages.first?.content == "first line\nsecond line")
        #expect(rig.chat.output == "Two lines, got it.")
    }

    @Test func returnInThePaletteIsThePalettes() {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        rig.chat.handleCommandK()
        #expect(rig.chat.isActionPalettePresented)
        rig.window.noteFocus(.composer, false)
        #expect(rig.window.focus == .other)
        #expect(!rig.window.handleReturn(), "the palette's search keeps Return")
        // Escape still closes it, and never closes the chat.
        #expect(rig.window.handleEscape())
        #expect(!rig.chat.isActionPalettePresented)
        #expect(rig.chat.isQuickAIPresented)
    }

    @Test func escapeNeverLeavesTheThread() async {
        let rig = makeRig()
        rig.window.open(handoff: nil)
        await ask(rig.chat, rig.service, "q", reply: "A.")
        rig.chat.input = "a draft"
        #expect(rig.window.handleEscape())
        #expect(rig.chat.input == "a draft", "typed text stays")
        #expect(rig.chat.isQuickAIPresented)
        #expect(!rig.chat.conversationMessages.isEmpty)
    }

    // MARK: - Keys

    /// ⌘P (Recent Chats), ⌘J (Open in AI Chat), ⌘\ (the chat list), ⌘F
    /// and ⌘G (find) were checked against every key table: the answer
    /// actions, the overlay's own keys, the ⌘K row actions of every kind,
    /// and the default global hotkeys.
    @Test func theNewKeysAreFreeEverywhere() {
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
        // A chat row's Open in AI Chat is `⌘J` itself: the same move on
        // that row's chat, so it is left out of the rows checked.
        var rowKeys = results.flatMap {
            ItemActionCatalog.actions(for: $0, pasteTarget: nil)
                .filter { $0.kind != .openInAIChat }
                .compactMap(\.shortcut)
        }
        rowKeys += ItemActionCatalog.actions(for: .application(app), pasteTarget: nil, isRunning: true).compactMap(\.shortcut)
        let overlayKeys: [KeyShortcut] = [
            QuickViewModel.transformChooserShortcut,
            QuickViewModel.transcriptCollapseShortcut,
        ]
        let recent = QuickViewModel.recentChatsShortcut
        let continueKey = ResultAction.continueInAIChat.shortcut
        #expect(recent == .command("p"))
        #expect(continueKey == .command("j"))
        let windowKeys = [
            AIChatWindowModel.chatListShortcut, AIChatWindowModel.findShortcut,
            AIChatWindowModel.findNextShortcut, AIChatWindowModel.findPreviousShortcut,
        ]
        for key in [recent, continueKey] + windowKeys {
            // Recent Chats is `⌘P` itself, in `⌘K`.
            let others = ResultAction.allCases.filter { $0 != .continueInAIChat && $0 != .recentChats }.map(\.shortcut)
            #expect(!others.contains(key), "\(key.keyCaps.joined()) is an answer action")
            #expect(!overlayKeys.contains(key))
            #expect(!rowKeys.contains(key), "\(key.keyCaps.joined()) is a row action")
        }
        #expect(Set(([recent, continueKey] + windowKeys).map(\.keyCaps)).count == 6, "no two alike")

        // Global hotkeys are key codes: P 35, J 38, F 3, G 5, \ 42; ⌘ is 1_048_576.
        let settings = QuickSettings()
        var globals = [settings.clipboardHistoryHotkey, settings.translatorHotkey, settings.typeToClickHotkey]
        globals += settings.savedPrompts.compactMap(\.hotkey)
        globals += settings.launcherItemConfigurations.compactMap(\.hotkey)
        for code: UInt16 in [35, 38, 3, 5, 42] {
            #expect(!globals.contains(ActionHotkey(keyCode: code, modifiers: 1_048_576)))
        }
    }

    @Test func theEmptySurfaceAndHeaderNameTheNewKeys() {
        let vm = QuickViewModel(service: MockQuickService())
        vm.openQuickAI()
        #expect(vm.quickAIEmptyStateHints[1] == "⌘P opens recent chats")
        #expect(ResultAction.continueInAIChat.title == "Open in AI Chat")
    }
}
