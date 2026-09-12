import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Quick AI: chats catalog, browsing, attachments", .serialized)
@MainActor
struct QuickAITests {
    private static let png = QuickImageAttachment(data: Data([0x89, 0x50, 0x4E, 0x47, 1]), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1)
    private static let png2 = QuickImageAttachment(data: Data([0x89, 0x50, 0x4E, 0x47, 2]), mimeType: "image/png", pixelWidth: 2, pixelHeight: 2)

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, reply: String) async {
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    @Test func severalScreenshotsTravelWithOneQuestionAndBackspaceDropsTheNewest() async {
        let mock = MockQuickService()
        let vm = QuickViewModel(service: mock)
        vm.settings.autoCopy = false
        vm.pendingImage = Self.png
        vm.pendingImage = Self.png2
        vm.pendingImage = Self.png2   // duplicates are ignored
        #expect(vm.pendingImages.count == 2)
        #expect(vm.attachmentTitle == "2 screenshots attached")
        #expect(vm.popLayerForEmptyBackspace())
        #expect(vm.pendingImages == [Self.png])
        vm.pendingImage = Self.png2
        await ask(vm, mock, "compare these", reply: "Two images.")
        #expect(await mock.lastImages.count == 2)
        #expect(vm.pendingImages.isEmpty)
        await ask(vm, mock, "and the second?", reply: "Still two.")
        #expect(await mock.lastImages.count == 2, "follow-ups keep the thread's images")
        vm.clearAttachments()
        #expect(!vm.hasPendingAttachment)
    }

    @Test func returnOnAnAnswerRunsThePrimaryActionAndCommandReturnPastesItBack() async {
        let mock = MockQuickService()
        let selection = PasteRecorder()
        let vm = QuickViewModel(service: mock, selectedTextService: selection)
        vm.settings.autoCopy = false
        vm.rememberSelectionTarget(SelectionTarget(processIdentifier: 1, applicationName: "Notes"))
        await ask(vm, mock, "hello", reply: "Bonjour")
        vm.input = ""
        // Return with an empty composer runs the Quick AI primary action,
        // which is Paste to active app by default.
        await vm.submitResolvingFuzzyAlias()
        #expect(selection.pasted == "Bonjour")
        #expect(await mock.sendCallCount == 1)
        selection.clear()
        // ⌘↩ is the explicit paste-back, the same as every result action.
        #expect(vm.performShortcut(characters: nil, keyCode: VirtualKey.return.rawValue, modifiers: [.command]))
        await eventually("the explicit paste-back") { selection.pasted == "Bonjour" }
        #expect(selection.pasted == "Bonjour")
    }

    @Test func chatsCatalogListsPinsRenamesDeletesAndContinues() async {
        let mock = MockQuickService()
        let vm = QuickViewModel(service: mock)
        vm.settings.autoCopy = false
        vm.settings.newChatInterval = .oneHour
        await ask(vm, mock, "first question", reply: "First answer")
        vm.startNewConversation()
        await ask(vm, mock, "second question", reply: "Second answer")
        vm.startNewConversation()
        #expect(vm.history.count == 2)
        // Back to root search: the catalogs live there, not on the surface.
        vm.closeQuickAI()

        vm.input = "chats"
        #expect(vm.launcherMatches.contains(.catalog(.chats, count: 2)))
        vm.enterCatalog(.chats)
        #expect(vm.catalogItems.map(\.title) == ["Second question", "First question"])
        #expect(vm.catalogItems.first?.value == "Second answer")
        let first = vm.catalogItems[1]
        #expect(ItemActionCatalog.actions(for: .item(first), pasteTarget: nil).map(\.title)
            == ["Continue Chat", "Open in AI Chat", "Copy Last Answer", "Rename Chat", "Pin to Top", "Delete Chat"])

        await vm.perform(ItemActionCatalog.actions(for: .item(first), pasteTarget: nil)[4], on: .item(first))
        #expect(vm.catalogItems.first?.title == "First question")
        #expect(vm.catalogItems.first?.isPinned == true)

        let pinned = vm.catalogItems[0]
        await vm.perform(ItemActionCatalog.actions(for: .item(pinned), pasteTarget: nil)[3], on: .item(pinned))
        #expect(vm.inputMode == .renameChat(UUID(uuidString: pinned.itemID)!))
        #expect(vm.input == "First question", "Rename starts from the title")
        vm.input = "Budget thread"
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.catalogScope == .chats)
        #expect(vm.catalogItems.first?.title == "Budget thread")

        let budget = vm.catalogItems[0]
        await vm.perform(ItemActionCatalog.actions(for: .item(budget), pasteTarget: nil)[0], on: .item(budget))
        #expect(vm.isAnswerActive)
        #expect(vm.isQuickAIPresented, "Return on a Chats row continues the chat in Quick AI")
        #expect(vm.catalogScope == nil)
        #expect(vm.output == "First answer")
        #expect(vm.currentConversation?.title == "Budget thread")
        #expect(vm.lastQuestion == "first question")

        vm.browseConversations(1)
        #expect(vm.output == "Second answer")
        vm.browseConversations(1)
        #expect(vm.output == "First answer", "wraps around, pinned first")
        #expect(vm.resultActions.contains(.previousChat))

        #expect(vm.performShortcut(characters: "]", keyCode: 30, modifiers: [.command]))
        await eventually("the next chat to open") { vm.output == "Second answer" }
        #expect(vm.output == "Second answer")

        await vm.performResultAction(.deleteChat)
        #expect(vm.history.count == 1)
        #expect(vm.output.isEmpty, "the deleted chat leaves the surface empty")
        #expect(vm.currentConversation == nil)
        #expect(vm.isQuickAIPresented, "deleting a chat does not leave Quick AI")
    }

    @Test func chatArrowsStepBackwardsThroughRecency() async {
        let mock = MockQuickService()
        let vm = QuickViewModel(service: mock)
        vm.settings.autoCopy = false
        vm.settings.newChatInterval = .oneHour
        await ask(vm, mock, "older question", reply: "Older answer")
        vm.startNewConversation()
        await ask(vm, mock, "newer question", reply: "Newer answer")
        #expect(vm.currentConversation?.title == "Newer question")

        // Previous Chat (⌘[) goes back in time from the newest chat...
        await vm.performResultAction(.previousChat)
        #expect(vm.output == "Older answer")
        // ...and Next Chat (⌘]) comes forward again.
        await vm.performResultAction(.nextChat)
        #expect(vm.output == "Newer answer")
    }

    @Test func pinnedChatsSurviveTheHistoryLimitAndTitlesRoundTrip() throws {
        var pinned = QuickConversation(providerID: UUID(), model: "m", customTitle: "Keep", isPinned: true)
        pinned.updatedAt = Date(timeIntervalSince1970: 1)
        var conversations = [pinned]
        for index in 0..<5 {
            var conversation = QuickConversation(providerID: UUID(), model: "m", messages: [QuickMessage(role: .user, content: "q\(index)")])
            conversation.updatedAt = Date(timeIntervalSince1970: Double(10 + index))
            conversations.append(conversation)
        }
        let bounded = QuickHistoryStore.bounded(conversations, limit: 2)
        #expect(bounded.map(\.title) == ["Keep", "Q4", "Q3"])
        let data = try JSONEncoder().encode(bounded)
        let back = try JSONDecoder().decode([QuickConversation].self, from: data)
        #expect(back.first?.isPinned == true && back.first?.title == "Keep")
        let legacy = #"""
        [{"id":"00000000-0000-0000-0000-000000000001","createdAt":0,"updatedAt":0,"providerID":"00000000-0000-0000-0000-000000000002","model":"m","messages":[]}]
        """#
        let old = try JSONDecoder().decode([QuickConversation].self, from: Data(legacy.utf8))
        #expect(old.first?.isPinned == false && old.first?.customTitle == nil)
    }

    @Test func regenerateResendsTheLastQuestion() async {
        let mock = MockQuickService()
        let vm = QuickViewModel(service: mock)
        vm.settings.autoCopy = false
        await ask(vm, mock, "capital of france", reply: "Paris")
        await mock.setResponses([StreamDelta(text: "Paris, France", finishReason: "stop")])
        await vm.performResultAction(.regenerate)
        #expect(vm.output == "Paris, France")
        #expect(await mock.sendCallCount == 2)
        #expect(vm.currentConversation?.messages.count == 2)
        #expect(await mock.lastPrompt == "capital of france")
    }
}

@MainActor
private final class PasteRecorder: SelectedTextServicing {
    private(set) var pasted: String?
    var isAccessibilityTrusted: Bool { true }
    func currentExternalTarget() -> SelectionTarget? { nil }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? { nil }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { pasted = text; return true }
    func openAccessibilitySettings() {}
    func clear() { pasted = nil }
}

/// Polls `condition` instead of sleeping a fixed time, and records the
/// timeout itself rather than leaving the next assertion to report it.
@MainActor
private func eventually(
    _ description: String,
    timeout: Duration = .seconds(15),
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if condition() { return }
    Issue.record("timed out waiting for \(description)")
}
