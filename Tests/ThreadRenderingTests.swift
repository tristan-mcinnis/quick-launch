// ThreadRenderingTests — the Quick AI thread draws messages through the one
// answer stack: prose runs, code blocks with their chrome, and no second
// scroll view nested in the thread's own.
//
// The scroll-view counts here are the executable form of "nesting does not
// double-scroll": SwiftUI backs a `ScrollView` with an `NSScrollView`, so the
// hosted tree can be asked what it contains.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Thread rendering", .serialized)
@MainActor
struct ThreadRenderingTests {
    private let codeMessage = """
    Here is the fix:

    ```swift
    let x = 42
    print(x)
    ```

    That should do it.
    """

    private let plainMessage = "Here is the fix:\n\nThat should do it."

    private static let proofDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    // MARK: - The message body

    @Test func aMessageWithAFenceSplitsIntoProseCodeProse() {
        let segments = MarkdownRenderer.segments(codeMessage)
        #expect(segments.count == 3)
        for segment in segments {
            guard case .prose(let source) = segment.content else { continue }
            #expect(!source.contains("```"), "the fence must not reach the prose")
            #expect(!source.contains("let x = 42"), "the code must not reach the prose")
        }
        guard case .code(let block) = segments[1].content else {
            Issue.record("the message's fence must be a code segment, got \(segments.map(\.content))")
            return
        }
        #expect(block.language == "swift")
        #expect(block.copyPayload == "let x = 42\nprint(x)")
    }

    @Test func theNonScrollingStackIsContentSizedAndNestsNoVerticalScroll() {
        let width = House.Layout.answerMaxWidth
        let host = NSHostingView(
            rootView: MarkdownTextView(markdown: codeMessage, isStreaming: false, scrolls: false)
                .frame(width: width)
        )
        host.layoutSubtreeIfNeeded()

        #expect(
            Self.scrollViews(in: host).filter(\.hasVerticalScroller).isEmpty,
            "a stack hosted by the thread must not bring its own vertical scroll view"
        )
        let horizontal = Self.scrollViews(in: host).filter(\.hasHorizontalScroller)
        #expect(horizontal.count == 1, "the code body still scrolls sideways while wrap is off")

        let measured = MarkdownRenderer.measuredHeight(markdown: codeMessage, width: width)
        #expect(
            abs(host.fittingSize.height - measured) <= 8,
            "the non-scrolling stack must be content sized: drawn \(host.fittingSize.height), measured \(measured)"
        )
    }

    @Test func theSelfScrollingFormOwnsTheOneVerticalScrollView() {
        let host = NSHostingView(
            rootView: MarkdownTextView(markdown: codeMessage, isStreaming: false)
                .frame(width: House.Layout.answerMaxWidth)
        )
        host.layoutSubtreeIfNeeded()
        #expect(
            Self.scrollViews(in: host).filter(\.hasVerticalScroller).count == 1,
            "the overlay's answer body still scrolls itself"
        )
    }

    // MARK: - The thread

    @Test func theThreadRendersACodeBlockWithoutASecondScrollView() {
        let withCode = hostedThread(message: codeMessage)
        let plain = hostedThread(message: plainMessage)

        #expect(
            withCode.vertical == plain.vertical,
            "drawing a code block must not add a vertical scroll view: \(withCode.vertical) vs \(plain.vertical)"
        )
        #expect(withCode.vertical == 1, "the thread keeps exactly one vertical scroll view")
        #expect(
            withCode.horizontal == plain.horizontal + 1,
            "the message's code block brings the one sideways scroller its body needs"
        )
        #expect(withCode.horizontal == 1)
    }

    @Test func theThreadDrawsOffscreenForReview() throws {
        // Pinned appearance, like the overlay's other proofs: an unpinned
        // host draws dark tokens on a light ground and reads washed out,
        // which is a harness artifact and not what the app shows.
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let image = try renderThreadProof(appearance: appearance)
            let name = appearance == .darkAqua
                ? "thread-code-block-dark.png"
                : "thread-code-block-light.png"
            try Self.write(image, name: name)
            #expect(image.size.width == PanelSizing.panelWidth)
            #expect(image.size.height == PanelSizing.quickAIHeight)
        }
    }

    // MARK: - Identifiers

    @Test func codeBlockControlsCarryPerInstanceIdentifiers() {
        let first = CodeBlockView.accessibilityIdentifier(.copy, instance: "message-A-0")
        let second = CodeBlockView.accessibilityIdentifier(.copy, instance: "message-B-0")
        #expect(first != second, "two messages with the same code must not share a control")
        #expect(first == "code-block-message-A-0-copy")
        #expect(
            CodeBlockView.accessibilityIdentifier(.wrap, instance: "message-A-0") != first,
            "each control of one block needs its own identifier"
        )
        #expect(
            CodeBlockView.accessibilityIdentifier(.block, instance: "answer-0")
                == "code-block-answer-0-block"
        )
    }

    // MARK: - Helpers

    private func hostedThread(message: String) -> (vertical: Int, horizontal: Int) {
        let scrollViews = Self.scrollViews(in: hostedThreadHost(message: message))
        return (
            scrollViews.filter(\.hasVerticalScroller).count,
            scrollViews.filter(\.hasHorizontalScroller).count
        )
    }

    private func hostedThreadHost(message: String) -> NSHostingView<AnyView> {
        let vm = threadViewModel(message: message)
        let host = NSHostingView(rootView: AnyView(QuickAIView(viewModel: vm)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(
            x: 0,
            y: 0,
            width: PanelSizing.panelWidth,
            height: PanelSizing.quickAIHeight
        )
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The thread as it is actually seen: inside the overlay panel that hosts
    /// it and gives it its appearance.
    private func renderThreadProof(appearance: NSAppearance.Name) throws -> NSImage {
        let vm = threadViewModel(message: codeMessage)
        let width = vm.currentPanelWidth
        let host = NSHostingView(rootView: OverlayView(viewModel: vm).frame(width: width))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: vm.estimatedWindowHeight
        )
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ProofError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func write(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(
            at: proofDir,
            withIntermediateDirectories: true
        )
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            throw ProofError.noBitmap
        }
        try png.write(to: proofDir.appendingPathComponent(name))
    }

    private enum ProofError: Error {
        case noBitmap
    }

    private func threadViewModel(message: String) -> QuickViewModel {
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: MockQuickService())
        vm.currentConversation = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "thread-rendering-test",
            messages: [
                QuickMessage(role: .user, content: "Fix the parser."),
                QuickMessage(role: .assistant, content: message),
            ]
        )
        vm.openQuickAI()
        return vm
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for subview in view.subviews {
            found.append(contentsOf: scrollViews(in: subview))
        }
        return found
    }
}
