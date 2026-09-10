import SwiftUI
import AppKit

/// The assistant answer body. The answer is a vertical stack of segments:
/// markdown runs draw as prose, and each fenced code block draws as its own
/// block with a header strip, so code never reads as part of the prose.
///
/// The same stack serves the overlay answer body and every message in the
/// `⌘J` thread. `scrolls` says which of the two it is, so a surface that
/// already owns a scroll view never nests a second one.
struct MarkdownTextView: View {
    let markdown: String
    let isStreaming: Bool
    /// True when this view owns its scrolling (the overlay answer body).
    /// False when an outer scroll view hosts it (the thread).
    var scrolls = true
    /// Scopes every control inside the answer, so the thread's Copy button
    /// and the overlay's are not the same accessibility element.
    var instanceID = "answer"

    /// Scroll target that keeps the newest streamed text at the bottom edge.
    private static let bottomAnchor = "answer-bottom-anchor"

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    segmentStack
                }
                .onAppear { followStream(proxy) }
                .onChange(of: markdown) { _, _ in followStream(proxy) }
            }
        } else {
            segmentStack
        }
    }

    private var segmentStack: some View {
        let segments = MarkdownRenderer.cachedSegments(markdown)
        return VStack(alignment: .leading, spacing: MarkdownRenderer.segmentSpacing) {
            ForEach(segments) { segment in
                segmentView(segment, isLast: segment.id == segments.last?.id)
            }
            if isStreaming, !endsInProse(segments) {
                StreamingCaret()
            }
            if scrolls {
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func segmentView(_ segment: AnswerSegment, isLast: Bool) -> some View {
        switch segment.content {
        case .prose(let source):
            // Only the final run carries the streaming caret.
            ProseSegmentView(markdown: source, showsCaret: isStreaming && isLast)
        case .code(let content):
            CodeBlockView(content: content, instanceID: "\(instanceID)-\(segment.id)")
        }
    }

    private func endsInProse(_ segments: [AnswerSegment]) -> Bool {
        guard case .prose = segments.last?.content else { return false }
        return true
    }

    /// Follows the stream: new text appears at the bottom edge, not below it.
    private func followStream(_ proxy: ScrollViewProxy) {
        guard isStreaming else { return }
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }
}

/// The caret shown while an answer streams, when it lands after a code block
/// rather than inside prose.
private struct StreamingCaret: View {
    var body: some View {
        Text("\u{258B}")
            .font(AQDesign.TypeToken.prose)
            .foregroundStyle(AQDesign.ColorToken.textPrimary)
            .accessibilityHidden(true)
    }
}

/// One markdown run: the rendered attributed string in a non-editable,
/// selectable text view that reports the height it needs at the answer width.
private struct ProseSegmentView: NSViewRepresentable {
    let markdown: String
    let showsCaret: Bool

    final class Coordinator {
        var shownMarkdown: String?
        var shownCaret = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.shownMarkdown != markdown || coordinator.shownCaret != showsCaret {
            coordinator.shownMarkdown = markdown
            coordinator.shownCaret = showsCaret
            textView.textStorage?.setAttributedString(renderedText())
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? House.Layout.answerMaxWidth
        let height = Self.height(markdown: markdown, width: width, showsCaret: showsCaret)
        nsView.textContainer?.containerSize = NSSize(
            width: width,
            height: .greatestFiniteMagnitude
        )
        nsView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return CGSize(width: width, height: height)
    }

    private func renderedText() -> NSAttributedString {
        let rendered = MarkdownRenderer.cachedRender(markdown)
        guard showsCaret else { return rendered }
        let text = NSMutableAttributedString(attributedString: rendered)
        // The streaming caret is house ink at the prose size.
        text.append(NSAttributedString(string: "\u{258B}", attributes: [
            .font: NSFont.systemFont(ofSize: House.TypeToken.Size.body),
            .foregroundColor: House.NSColorToken.textPrimary,
        ]))
        return text
    }

    /// The text view draws the same string `measuredHeight` measures, plus
    /// the caret's own line while streaming so it is never clipped.
    private static func height(markdown: String, width: CGFloat, showsCaret: Bool) -> CGFloat {
        let measured = MarkdownRenderer.proseHeight(markdown: markdown, width: width)
        guard showsCaret else { return measured }
        let caretFont = NSFont.systemFont(ofSize: House.TypeToken.Size.body)
        let caretLine = (caretFont.ascender - caretFont.descender + caretFont.leading)
            .rounded(.up)
        return measured + caretLine
    }
}
