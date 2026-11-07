import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

/// A chat of several questions in a hosted Quick AI surface: after each
/// answer the view shows the newest turn (its end, or its question at the
/// top), whatever the answer's length, and never stays on older turns.
/// Each wait is on the work itself (the stream ending, the view coming to
/// rest), with a deadline only to fail instead of hanging.
@MainActor
@Suite("Thread follows the newest answer", .serialized)
struct ThreadFollowTests {
    private func scrollView(in window: NSWindow) -> NSScrollView? {
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, let document = scroll.documentView, document.frame.height > 100 { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    /// How far the view's bottom is above the content's, once the view has
    /// held still for a few polls.
    /// The deadline only stops a hang: a CI runner took more than 15 s to
    /// lay out six long answers, so a view still moving fails with its last
    /// readings rather than a bare timeout.
    private func settledDistanceFromBottom(in window: NSWindow) async throws -> CGFloat {
        let deadline = ContinuousClock.now + .seconds(30)
        var last: CGFloat?
        var steady = 0
        var recent: [String] = []
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            guard let scroll = scrollView(in: window), let document = scroll.documentView else {
                recent = Array((recent + ["no scroll view"]).suffix(8))
                continue
            }
            let bounds = scroll.contentView.bounds
            let distance = document.frame.height - bounds.maxY
            recent = Array((recent + ["\(Int(distance)) of \(Int(document.frame.height))"]).suffix(8))
            if let previous = last, abs(distance - previous) < 0.5 { steady += 1 } else { steady = 0 }
            last = distance
            if steady >= 8 { return distance }
        }
        Issue.record("the thread did not come to rest; last readings (distance of document): \(recent)")
        return last ?? .greatestFiniteMagnitude
    }

    private func streamEnded(_ vm: QuickViewModel) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while vm.isStreaming, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!vm.isStreaming, "the answer never finished")
    }

    private func answer(_ index: Int, paragraphs: Int) -> [StreamDelta] {
        var deltas = (1...paragraphs).map {
            StreamDelta(text: "Answer \(index), paragraph \($0), with enough words to wrap a little.\n\n", finishReason: nil)
        }
        deltas.append(StreamDelta(text: "", finishReason: "stop"))
        return deltas
    }

    /// Short answers fit under their question, medium ones just outgrow
    /// the view, long ones outgrow it many times over.
    @Test(.timeLimit(.minutes(2)), arguments: [3, 12, 40])
    func everyAnswerEndsInView(paragraphs: Int) async throws {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let mock = MockQuickService()
        await mock.setDelay(.milliseconds(15))
        let vm = QuickViewModel(settings: settings, service: mock, pasteboard: FakePasteboard())
        vm.openQuickAI()
        let host = NSHostingView(rootView: OverlayView(viewModel: vm))
        host.frame = NSRect(x: 0, y: 0, width: PanelSizing.panelWidth, height: PanelSizing.quickAIHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }

        for index in 1...6 {
            await mock.setResponses(answer(index, paragraphs: paragraphs))
            vm.input = "question \(index)"
            await vm.submit()
            try await streamEnded(vm)
            let distance = try await settledDistanceFromBottom(in: window)
            // Where the view ends: at the newest text, or (an answer that
            // finished before it outgrew the room under its question) with
            // that question at the top of the view. Never on older turns.
            let newest = vm.conversationMessages.last { $0.role == .user }?.id
            let anchor = vm.currentConversation.flatMap { vm.threadAnchors.anchor(for: $0.id) }
            let questionAtTop = anchor.map { $0.messageID == newest && abs($0.offset) <= QuickViewModel.threadFollowThreshold } ?? false
            // A short answer can rest a few points above the end of the room
            // reserved under it, with the whole turn still in view.
            let atTheEnd = distance <= 2 * QuickViewModel.threadFollowThreshold
            #expect(atTheEnd || questionAtTop,
                    "question \(index) of \(paragraphs)-paragraph answers ended \(Int(distance)) pt above the newest text, not at its question")
            #expect(vm.isThreadFollowingBottom)
        }
    }
}
