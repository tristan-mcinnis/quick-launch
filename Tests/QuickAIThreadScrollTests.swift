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
        return (vm, window)
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
}
