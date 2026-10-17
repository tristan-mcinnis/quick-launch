// The AI Chat composer floats over the thread: a draft growing from one line
// to the eight-line cap changes only the bottom inset, never the thread's own
// frame, so no message re-lays out while typing.

import AppKit
import SwiftUI
import Testing
@testable import QuickLaunch
import HouseDesign

@Suite("AI Chat floating composer", .serialized)
@MainActor
struct AIChatComposerFloatTests {
    private func window(draft: String) -> AIChatWindowModel {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let chat = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
        let suite = "AIChatComposerFloatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        chat.input = draft
        return AIChatWindowModel(chat: chat, defaults: defaults)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
    }

    /// The thread's scroll view (the tallest one): its frame in the host's
    /// coordinates, and the bottom inset the composer takes from it. Waits
    /// for the composer's inset to land, as the layout runs on the main loop.
    private func layout(draft: String) async throws -> (thread: CGRect, bottomInset: CGFloat) {
        let size = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
        let host = NSHostingView(rootView: AIChatWindowView(model: window(draft: draft)).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let nsWindow = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        nsWindow.isReleasedWhenClosed = false
        nsWindow.contentView = host
        defer { nsWindow.contentView = nil }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(0.1))
            host.layoutSubtreeIfNeeded()
            if let thread = scrollViews(in: host).max(by: { $0.frame.height < $1.frame.height }),
               thread.contentInsets.bottom > 0 {
                try await Task.sleep(for: .seconds(0.3))
                host.layoutSubtreeIfNeeded()
                return (host.convert(thread.bounds, from: thread), thread.contentInsets.bottom)
            }
        }
        throw CancellationError()
    }

    @Test func growingTheDraftLeavesTheThreadFrameAlone() async throws {
        let one = try await layout(draft: "One line")
        let eight = try await layout(draft: (1...8).map { "Line \($0)" }.joined(separator: "\n"))
        #expect(eight.bottomInset > one.bottomInset + House.Control.pill, "The field really grew")
        #expect(eight.thread == one.thread, "Draft growth must change only the bottom inset")
    }
}
