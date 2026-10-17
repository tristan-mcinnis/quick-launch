// ChatSwitchingTests — opening another chat is fast and flash-free: the
// markdown caches hold a long chat, the anchor maths is exact, and a chat
// opens where the reader left it. The end-to-end test drives the real thread
// in a window nobody sees, as QuickAIThreadScrollTests does.

import AppKit
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Chat switching", .serialized)
@MainActor
struct ChatSwitchingTests {

    // MARK: - Cache

    @Test func theMarkdownCachesHoldALongChat() {
        var cache = MarkdownCache<String, Int>(limit: MarkdownRenderer.cacheLimit)
        // 60 answers of five prose runs each, a segment, a render and a height apiece.
        for index in 0..<300 { cache.insert(index, for: "run \(index)", transient: false) }
        #expect(MarkdownRenderer.cacheLimit >= 512)
        #expect(cache.settledCount == 300, "a 60-answer chat fits whole")
        for index in 0..<300 { #expect(cache.value(for: "run \(index)") == index) }
    }

    @Test func theOldestEntryLeavesFirstPastTheLimit() {
        var cache = MarkdownCache<String, Int>(limit: MarkdownRenderer.cacheLimit)
        for index in 0...MarkdownRenderer.cacheLimit { cache.insert(index, for: "run \(index)", transient: false) }
        #expect(cache.settledCount == MarkdownRenderer.cacheLimit)
        #expect(cache.value(for: "run 0") == nil)
        #expect(cache.value(for: "run 1") == 1)
    }

    @Test func aHeightIsKeyedByItsTextAndWidth() {
        let narrow = MarkdownRenderer.MeasuredRun(source: "same", width: 300)
        let wide = MarkdownRenderer.MeasuredRun(source: "same", width: 600)
        var cache = MarkdownCache<MarkdownRenderer.MeasuredRun, CGFloat>(limit: MarkdownRenderer.cacheLimit)
        cache.insert(40, for: narrow, transient: false)
        #expect(cache.value(for: wide) == nil, "a resize misses")
        #expect(cache.value(for: narrow) == 40)
    }

    // MARK: - Anchor

    @Test func theAnchorIsTheLastMessageAtOrAboveTheViewTop() throws {
        let ids = (0..<4).map { _ in UUID() }
        let tops: [UUID: CGFloat] = [ids[0]: 0, ids[1]: 300, ids[2]: 700, ids[3]: 1_100]
        let anchor = try #require(ThreadScrollAnchor.make(viewTop: 820, order: ids, tops: tops))
        #expect(anchor.messageID == ids[2])
        #expect(anchor.offset == 120)
        // Heights above re-estimated: the same message and offset land elsewhere.
        #expect(anchor.scrollTop(messageTop: 900, maximumTop: 5_000) == 1_020)
        #expect(anchor.scrollTop(messageTop: 900, maximumTop: 950) == 950, "clamped to the scroll range")
    }

    @Test func noLaidOutMessageMeansNoAnchor() {
        let id = UUID()
        #expect(ThreadScrollAnchor.make(viewTop: 500, order: [id], tops: [:]) == nil)
        #expect(ThreadScrollAnchor.make(viewTop: 10, order: [id], tops: [id: 40]) == nil)
    }

    @Test func theStoreKeepsAnAnchorUntilTheChatIsLeftAtTheBottom() {
        var store = ThreadScrollAnchorStore()
        let chat = UUID()
        let anchor = ThreadScrollAnchor(messageID: UUID(), offset: 12)
        store.record(anchor, for: chat)
        #expect(store.anchor(for: chat) == anchor)
        store.record(nil, for: chat)
        #expect(store.anchor(for: chat) == nil)
    }

    @Test func theStoreDropsTheOldestChatPastItsCapacity() {
        var store = ThreadScrollAnchorStore()
        let chats = (0...ThreadScrollAnchorStore.capacity).map { _ in UUID() }
        for chat in chats { store.record(ThreadScrollAnchor(messageID: UUID(), offset: 1), for: chat) }
        #expect(store.anchor(for: chats[0]) == nil)
        #expect(store.anchor(for: chats[1]) != nil)
    }

    // MARK: - Opening a chat

    private func conversation(_ label: String, provider: UUID, turns: Int = 12) -> QuickConversation {
        var messages: [QuickMessage] = []
        for index in 0..<turns {
            messages.append(QuickMessage(role: .user, content: "\(label) question \(index)"))
            let body = (1...10).map { "\(label) \(index).\($0) a line of the answer." }.joined(separator: "\n")
            messages.append(QuickMessage(role: .assistant, content: body))
        }
        return QuickConversation(providerID: provider, model: "model", messages: messages)
    }

    private func scrollOffset(in window: NSWindow) -> CGFloat? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView != nil, scroll.documentView!.frame.height > 100 { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let root = window.contentView, let scroll = find(root) else { return nil }
        return scroll.contentView.bounds.origin.y
    }

    private func settled(_ window: NSWindow, _ condition: @MainActor (CGFloat) -> Bool) async throws -> CGFloat {
        let deadline = Date().addingTimeInterval(15)
        var last: CGFloat?
        var steady = 0
        while Date() < deadline {
            try await Task.sleep(for: .seconds(0.05))
            let offset = scrollOffset(in: window) ?? -1
            if let previous = last, abs(offset - previous) < 0.01, condition(offset) { steady += 1 } else { steady = 0 }
            last = offset
            if steady >= 8 { return offset }
        }
        Issue.record("the thread did not come to rest")
        return last ?? -1
    }

    @Test func aChatOpensWhereTheReaderLeftIt() async throws {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
        let provider = settings.providers[0].id
        let first = conversation("Alpha", provider: provider)
        let second = conversation("Beta", provider: provider)

        vm.openQuickAI()
        let host = NSHostingView(rootView: OverlayView(viewModel: vm))
        host.frame = NSRect(x: 0, y: 0, width: PanelSizing.panelWidth, height: PanelSizing.quickAIHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .seconds(0.3))
        vm.loadConversation(first)

        let bottom = try await settled(window) { $0 > 100 }
        // Read part-way up: to the top, then two pages down.
        vm.handleThreadKey(.up, command: true, option: false)
        _ = try await settled(window) { $0 < 1 }
        vm.handleThreadKey(.pageDown, command: false, option: false)
        let page = try await settled(window) { $0 > 100 }
        vm.handleThreadKey(.pageDown, command: false, option: false)
        let left = try await settled(window) { $0 > page + 100 }
        #expect(left < bottom)
        #expect(vm.threadAnchors.anchor(for: first.id) != nil, "scrolling up leaves an anchor")

        // Another chat opens at its newest turn.
        vm.loadConversation(second)
        let secondBottom = try await settled(window) { $0 > 100 }
        #expect(vm.isThreadFollowingBottom)

        // Back to the first: where it was left, not the bottom and not the top.
        vm.loadConversation(first)
        let reopened = try await settled(window) { $0 > 100 }
        #expect(abs(reopened - left) <= 24, "reopened at \(reopened), left at \(left), bottom \(secondBottom)")
        #expect(!vm.isThreadFollowingBottom)
    }

    @Test func aChatLeftAtTheBottomOpensAtTheBottom() async throws {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
        let provider = settings.providers[0].id
        let first = conversation("Alpha", provider: provider)
        let second = conversation("Beta", provider: provider)

        vm.openQuickAI()
        let host = NSHostingView(rootView: OverlayView(viewModel: vm))
        host.frame = NSRect(x: 0, y: 0, width: PanelSizing.panelWidth, height: PanelSizing.quickAIHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .seconds(0.3))
        vm.loadConversation(first)

        let bottom = try await settled(window) { $0 > 100 }
        vm.loadConversation(second)
        _ = try await settled(window) { $0 > 100 }
        vm.loadConversation(first)
        let reopened = try await settled(window) { $0 > 100 }
        #expect(abs(reopened - bottom) <= 24)
        #expect(vm.isThreadFollowingBottom)
        #expect(vm.threadAnchors.anchor(for: first.id) == nil)
    }

    // MARK: - Hold and reveal

    @Test func onlyAnotherChatWithAFewTurnsIsHeld() {
        let chat = UUID(), other = UUID()
        #expect(!ThreadReveal.isHolding(current: nil, revealed: nil, messageCount: 10), "no chat, nothing to hold")
        #expect(!ThreadReveal.isHolding(current: chat, revealed: nil, messageCount: 2), "a short chat is never held")
        #expect(ThreadReveal.isHolding(current: chat, revealed: other, messageCount: 3))
        #expect(!ThreadReveal.isHolding(current: chat, revealed: chat, messageCount: 30), "a shown chat stays shown")
    }

    @Test func aNewChatIsNotHeldWhenItsSecondQuestionArrives() async throws {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "First answer.", finishReason: "stop")])
        let vm = QuickViewModel(settings: settings, service: mock, pasteboard: FakePasteboard())
        vm.openQuickAI()
        // The thread is mounted before any conversation exists.
        let host = NSHostingView(rootView: OverlayView(viewModel: vm))
        host.frame = NSRect(x: 0, y: 0, width: PanelSizing.panelWidth, height: PanelSizing.quickAIHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        try await Task.sleep(for: .seconds(0.3))
        #expect(vm.currentConversation == nil)

        vm.input = "first question"
        await vm.submit()
        try await Task.sleep(for: .seconds(0.3))
        let chat = try #require(vm.currentConversation?.id)
        #expect(vm.conversationMessages.count < 3)

        await mock.setResponses([StreamDelta(text: "Second answer.", finishReason: "stop")])
        vm.input = "second question"
        await vm.submit()
        #expect(vm.conversationMessages.count >= 3)
        // The view recorded the chat as shown while it was short, so the
        // growing chat is not held (and not hidden) at three messages.
        try await Task.sleep(for: .seconds(0.5))
        #expect(vm.currentConversation?.id == chat)
        #expect(!ThreadReveal.isHolding(current: chat, revealed: chat, messageCount: vm.conversationMessages.count))
    }
}
