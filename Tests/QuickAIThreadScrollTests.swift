// QuickAIThreadScrollTests — the thread's scrolling, driven through the real
// view (v1.5.0, plan Phase A2 items 4 and 5).
//
// The render proofs snapshot a view once, so a scroll never gets to run in
// them. Here the real OverlayView sits in a window that is never shown (no
// order-front, no key status, no events), and the test sleeps while the main
// run loop lays it out, until the scroll the view model asked for has landed.
// What is asserted is what
// the view reported back: how far its view sits from the bottom of the
// thread, and whether the thread follows the newest text.

import AppKit
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Quick AI thread scrolling", .serialized)
@MainActor
struct QuickAIThreadScrollTests {

    private static let longAnswer = (1...40).map { "\($0). Step \($0) of the plan." }.joined(separator: "\n")

    /// A long answered thread in the real view, in a window nobody sees,
    /// settled at the bottom.
    private func hosted() async throws -> (QuickViewModel, NSWindow) {
        let (vm, window, _) = try await hostedWithService()
        return (vm, window)
    }

    private func hostedWithService() async throws -> (QuickViewModel, NSWindow, MockQuickService) {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: Self.longAnswer, finishReason: "stop")])
        let vm = QuickViewModel(settings: settings, service: mock, pasteboard: FakePasteboard())
        vm.openQuickAI()
        vm.input = "walk me through the plan"
        await vm.submit()
        let host = NSHostingView(rootView: OverlayView(viewModel: vm))
        host.frame = NSRect(x: 0, y: 0, width: PanelSizing.panelWidth, height: PanelSizing.quickAIHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        try await settle { (vm.lastThreadDistanceFromBottom ?? .infinity) <= QuickViewModel.threadFollowThreshold }
        return (vm, window, mock)
    }

    /// The thread's scroll view and how far its view has scrolled.
    private func scrollOffset(in window: NSWindow) -> CGFloat? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView != nil, scroll.documentView!.frame.height > 100 { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let root = window.contentView, let scroll = find(root) else { return nil }
        return scroll.contentView.bounds.origin.y
    }

    /// Waits until `condition` holds and the view has been still for a
    /// moment, or fails after a few seconds.
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try await spin(0.05)
            if condition() {
                try await spin(0.2)
                if condition() { return }
            }
        }
        Issue.record("the thread did not settle")
    }

    /// Waits until `condition` holds and the view's offset has stopped
    /// changing for several looks in a row, so a reading is taken at rest and
    /// never inside the 0.2 s scroll animation. Returns that offset.
    private func settleStill(in window: NSWindow, _ condition: @MainActor (CGFloat) -> Bool) async throws -> CGFloat {
        let deadline = Date().addingTimeInterval(15)
        var last: CGFloat?
        var steady = 0
        while Date() < deadline {
            try await spin(0.05)
            let offset = scrollOffset(in: window) ?? -1
            if let previous = last, abs(offset - previous) < 0.01, condition(offset) { steady += 1 } else { steady = 0 }
            last = offset
            if steady >= 8 { return offset }
        }
        Issue.record("the thread did not come to rest")
        return last ?? -1
    }

    private func distance(_ vm: QuickViewModel) -> CGFloat { vm.lastThreadDistanceFromBottom ?? -1 }

    /// Lets the main run loop lay the view out for a while.
    private func spin(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    @Test func theScrollKeysMoveTheThreadsView() async throws {
        let (vm, window) = try await hosted()
        defer { window.contentView = nil }
        let atBottom = distance(vm)
        #expect(atBottom <= QuickViewModel.threadFollowThreshold, "the answered thread opens on its newest text")

        // ⌘↑: the top. The whole thread is above the view's bottom edge.
        vm.handleThreadKey(.up, command: true, option: false)
        try await settle { distance(vm) > PanelSizing.quickAIHeight }
        let fromTop = distance(vm)
        #expect(!vm.isThreadFollowingBottom)
        #expect(vm.showsJumpToLatest, "scrolled up, the Latest chip shows")

        // PageDown: one page down from the top, less than the whole way.
        vm.handleThreadKey(.pageDown, command: false, option: false)
        try await settle { distance(vm) < fromTop - QuickViewModel.threadFollowThreshold }
        let onePageDown = distance(vm)
        #expect(onePageDown > QuickViewModel.threadFollowThreshold, "a page, not the bottom")

        // ⌥↑: a page back up, to where it started.
        vm.handleThreadKey(.up, command: false, option: true)
        // Settle on the position being asserted, not merely on having moved
        // past a threshold: a page scroll crosses that threshold before it
        // lands, so the older predicate could measure mid-animation and read
        // a few points short of the top.
        try await settle { abs(distance(vm) - fromTop) <= 1 }
        #expect(abs(distance(vm) - fromTop) <= 1)

        // ⌘↓ (or the chip): the bottom, following again.
        vm.handleThreadKey(.down, command: true, option: false)
        try await settle { distance(vm) <= QuickViewModel.threadFollowThreshold }
        #expect(vm.isThreadFollowingBottom)
        #expect(!vm.showsJumpToLatest)
    }

    @Test func showMoreBringsTheMessageHeadToTheTop() async throws {
        let (vm, window) = try await hosted()
        defer { window.contentView = nil }
        let question = try #require(vm.conversationMessages.first)
        vm.scrollThread(.messageTop(question.id))
        try await settle { distance(vm) > PanelSizing.quickAIHeight }
        #expect(!vm.isThreadFollowingBottom)
    }

    @Test func streamingTextFollowsOnlyAReaderAtTheBottom() async throws {
        let (vm, window) = try await hosted()
        defer { window.contentView = nil }

        // Scrolled up, new text lands below without moving the view.
        vm.handleThreadKey(.up, command: true, option: false)
        try await settle { distance(vm) > PanelSizing.quickAIHeight }
        let readingAt = distance(vm)
        vm.isStreaming = true
        vm.output = "A new answer that grows.\n" + Self.longAnswer
        try await spin(0.5)
        vm.output += "\nMore text lands while the reader is up."
        try await spin(0.5)
        #expect(!vm.isThreadFollowingBottom, "the reader stays where they are")
        #expect(distance(vm) > readingAt, "the text grew below a view that did not move")

        // Back at the bottom, it follows the stream.
        vm.scrollThread(.bottom)
        try await settle { distance(vm) <= QuickViewModel.threadFollowThreshold }
        vm.output += (1...8).map { "\nNew line \($0) of the stream." }.joined()
        try await settle { distance(vm) <= QuickViewModel.threadFollowThreshold }
        #expect(vm.isThreadFollowingBottom)
        #expect(distance(vm) <= QuickViewModel.threadFollowThreshold, "the newest line stays in view")
        vm.isStreaming = false
    }

    @Test func aNewQuestionGoesToTheTopAndAShortAnswerLeavesTheViewStill() async throws {
        let (vm, window, mock) = try await hostedWithService()
        defer { window.contentView = nil }
        let before = try #require(scrollOffset(in: window))

        await mock.setResponses([StreamDelta(text: "Short answer.", finishReason: "stop")])
        vm.input = "and in one line?"
        await vm.submit()
        // The new question is brought to the top once: the view moves down
        // by about the thread it just left behind, and rests there while the
        // short answer fits under the question.
        let landed = try await settleStill(in: window) { $0 > before + PanelSizing.quickAIHeight / 2 }
        try await spin(0.05)
        #expect(abs((scrollOffset(in: window) ?? 0) - landed) <= 1, "the view does not move again")
        #expect(distance(vm) <= 1, "the reserved room leaves nothing to scroll")
        #expect(!vm.showsJumpToLatest)
    }

    @Test func aStreamingAnswerFollowsTheEndOnlyOnceItOutgrowsTheView() async throws {
        let (vm, window, mock) = try await hostedWithService()
        defer { window.contentView = nil }
        await mock.setResponses([StreamDelta(text: "", finishReason: "stop")])
        vm.input = "the whole plan again"
        await vm.submit()
        let atQuestion = try await settleStill(in: window) { $0 > PanelSizing.quickAIHeight }

        // A few lines fit under the question: the view does not move.
        vm.isStreaming = true
        vm.output = (1...3).map { "Line \($0) of the answer." }.joined(separator: "\n")
        let afterShort = try await settleStill(in: window) { _ in true }
        #expect(abs(afterShort - atQuestion) <= 1, "an answer that fits moves nothing")

        // Grown past the view, the thread follows its newest line.
        for step in 1...12 {
            vm.output += "\n" + (1...10).map { "Step \(step).\($0) of the plan." }.joined(separator: "\n")
            try await spin(0.05)
        }
        // Lazy layout only estimates the height of what was just appended, so
        // a scroll to the end lands short until the next flush corrects it.
        for line in 1...6 {
            vm.output += "\nLast line \(line)."
            try await spin(0.05)
        }
        // Judged while the stream is still running: once it ends the fake
        // answer is dropped and the content shrinks back under the question.
        try await settle { distance(vm) <= QuickViewModel.threadFollowThreshold && (scrollOffset(in: window) ?? 0) > atQuestion }
        #expect(vm.isThreadFollowingBottom)
        #expect((scrollOffset(in: window) ?? 0) > atQuestion, "the view followed the end")
        #expect(!vm.showsJumpToLatest)
        vm.isStreaming = false
    }
}
