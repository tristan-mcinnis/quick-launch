import SwiftUI
import AppKit

/// The assistant answer body. The answer is a vertical stack of segments:
/// markdown runs draw as prose, and each fenced code block draws as its own
/// block with a header strip, so code never reads as part of the prose.
///
/// The same stack serves every answer in the Quick AI and AI Chat thread
/// and a local answer in root search. `scrolls` says whether the view owns
/// its scrolling, so a surface that already owns a scroll view never nests
/// a second one.
struct MarkdownTextView: View {
    let markdown: String
    let isStreaming: Bool
    /// True when this view owns its scrolling (an answer shown on its own).
    /// False when an outer scroll view hosts it (the thread, root search).
    var scrolls = true
    /// Scopes every control inside the answer, so two answers' Copy buttons
    /// are never the same accessibility element.
    var instanceID = "answer"
    /// Find in Chat: each segment's hits (by segment id), drawn in the
    /// hover fill. Empty everywhere else.
    var findRanges: [Int: [TextRange]] = [:]
    /// The current hit, drawn in the selection fill.
    var findCurrent: SegmentFindHit? = nil
    /// The coordinate space the current hit is measured in (its message's),
    /// and where the measure goes.
    var findSpace: String? = nil
    var onFindCurrentOffset: ((CGFloat) -> Void)? = nil

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
        // Streaming text is transient: it must not evict the finished
        // answers above it (`MarkdownCache`).
        let segments = MarkdownRenderer.cachedSegments(markdown, transient: isStreaming)
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
        let current = findCurrent?.segment == segment.id ? findCurrent?.range : nil
        switch segment.content {
        case .prose(let source):
            // Only the final run carries the streaming caret.
            ProseSegmentView(
                markdown: source,
                showsCaret: isStreaming && isLast,
                highlights: findRanges[segment.id] ?? [],
                current: current
            )
            .overlay(alignment: .topLeading) {
                if let current, let findSpace, let onFindCurrentOffset {
                    GeometryReader { proxy in
                        FindHitMarker(
                            rect: FindHitGeometry.proseRect(markdown: source, range: current, width: proxy.size.width),
                            space: findSpace,
                            onOffset: onFindCurrentOffset
                        )
                    }
                }
            }
        case .code(let content):
            CodeBlockView(
                content: content,
                instanceID: "\(instanceID)-\(segment.id)",
                findRanges: findRanges[segment.id] ?? [],
                findCurrent: current
            )
            .overlay(alignment: .topLeading) {
                if let current, let findSpace, let onFindCurrentOffset {
                    FindHitMarker(
                        rect: FindHitGeometry.codeRect(code: content.code, range: current),
                        space: findSpace,
                        onOffset: onFindCurrentOffset
                    )
                }
            }
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
    /// Find in Chat's hits in this run, and the current one.
    var highlights: [TextRange] = []
    var current: TextRange? = nil

    final class Coordinator {
        var shownMarkdown: String?
        var shownCaret = false
        var shownHighlights: [TextRange] = []
        var shownCurrent: TextRange?
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
        if coordinator.shownMarkdown != markdown || coordinator.shownCaret != showsCaret
            || coordinator.shownHighlights != highlights || coordinator.shownCurrent != current {
            coordinator.shownMarkdown = markdown
            coordinator.shownCaret = showsCaret
            coordinator.shownHighlights = highlights
            coordinator.shownCurrent = current
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
        // The run carrying the caret is the one still growing.
        let rendered = MarkdownRenderer.cachedRender(markdown, transient: showsCaret)
        guard showsCaret || !highlights.isEmpty || current != nil else { return rendered }
        let text = NSMutableAttributedString(attributedString: rendered)
        // Find in Chat: every hit in the hover fill, the current one in the
        // selection fill. Ink, never colour.
        FindHitGeometry.addHighlights(highlights, current: current, to: text)
        if showsCaret {
            // The streaming caret is house ink at the prose size.
            text.append(NSAttributedString(string: "\u{258B}", attributes: [
                .font: NSFont.systemFont(ofSize: House.TypeToken.Size.body),
                .foregroundColor: House.NSColorToken.textPrimary,
            ]))
        }
        return text
    }

    /// The text view draws the same string `measuredHeight` measures, plus
    /// the caret's own line while streaming so it is never clipped.
    private static func height(markdown: String, width: CGFloat, showsCaret: Bool) -> CGFloat {
        // `sizeThatFits` runs on every body pass, so this is the hot path:
        // the growing run is measured into the live slot, never over the
        // finished answers' measurements.
        let measured = MarkdownRenderer.proseHeight(
            markdown: markdown,
            width: width,
            transient: showsCaret
        )
        guard showsCaret else { return measured }
        let caretFont = NSFont.systemFont(ofSize: House.TypeToken.Size.body)
        let caretLine = (caretFont.ascender - caretFont.descender + caretFont.leading)
            .rounded(.up)
        return measured + caretLine
    }
}

// MARK: - Find in Chat

/// The current find hit inside an answer: which segment, which range.
struct SegmentFindHit: Equatable {
    let segment: Int
    let range: TextRange
}

/// Where find hits sit in drawn text, and how they are painted.
enum FindHitGeometry {
    /// Paints the hits on `text`: the hover fill on each, the selection
    /// fill on the current one. Ranges past the end are dropped.
    static func addHighlights(_ ranges: [TextRange], current: TextRange?, to text: NSMutableAttributedString) {
        let length = text.length
        for range in ranges {
            guard let range = range.clamped(toLength: length) else { continue }
            text.addAttribute(.backgroundColor, value: House.NSColorToken.hoverFill, range: range.nsRange)
        }
        if let current = current?.clamped(toLength: length) {
            text.addAttribute(.backgroundColor, value: House.NSColorToken.selectionFill, range: current.nsRange)
        }
    }

    /// Plain text (a code block, a question pill) with the hits painted the
    /// same way, for a SwiftUI `Text`. Plain text when there are none.
    static func highlighted(_ string: String, ranges: [TextRange], current: TextRange?) -> AttributedString {
        var text = AttributedString(string)
        guard !ranges.isEmpty || current != nil else { return text }
        let length = (string as NSString).length
        for range in ranges {
            guard let clamped = range.clamped(toLength: length),
                  let span = Range(clamped.nsRange, in: text) else { continue }
            text[span].backgroundColor = AQDesign.ColorToken.hoverFill
        }
        if let clamped = current?.clamped(toLength: length), let span = Range(clamped.nsRange, in: text) {
            text[span].backgroundColor = AQDesign.ColorToken.selectionFill
        }
        return text
    }

    /// The hit's rectangle in a prose run laid out `width` wide, from the
    /// layout manager, as the text view lays it out.
    @MainActor static func proseRect(markdown: String, range: TextRange, width: CGFloat) -> CGRect {
        rect(of: range, in: MarkdownRenderer.cachedRender(markdown), width: width)
    }

    /// The hit's rectangle in plain text set in `font`, `width` wide (a
    /// question pill).
    static func plainRect(text: String, font: NSFont, range: TextRange, width: CGFloat) -> CGRect {
        rect(of: range, in: NSAttributedString(string: text, attributes: [.font: font]), width: width)
    }

    /// The hit's rectangle in a code block: its line, under the header.
    /// Long lines scroll sideways, so only the line counts.
    static func codeRect(code: String, range: TextRange) -> CGRect {
        let prefix = (code as NSString).substring(to: min(range.location, (code as NSString).length))
        let line = prefix.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return CGRect(
            x: CodeBlockMetrics.bodyHorizontalPadding,
            y: CodeBlockMetrics.chromeHeight + CodeBlockMetrics.bodyVerticalPadding
                + CGFloat(line) * CodeBlockMetrics.lineHeight,
            width: AQDesign.hairline,
            height: CodeBlockMetrics.lineHeight
        )
    }

    private static func rect(of range: TextRange, in text: NSAttributedString, width: CGFloat) -> CGRect {
        guard width > 0, let range = range.clamped(toLength: text.length) else { return .zero }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let glyphs = layout.glyphRange(forCharacterRange: range.nsRange, actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container)
    }
}

/// An invisible mark where the current find hit sits. It reports how far
/// the hit is below the origin of `space` (its message), so the thread can
/// scroll the hit, not the message's head, into view.
struct FindHitMarker: View {
    let rect: CGRect
    let space: String
    let onOffset: (CGFloat) -> Void

    var body: some View {
        Color.clear
            .frame(width: max(rect.width, AQDesign.hairline), height: max(rect.height, AQDesign.hairline))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(space)).minY
            } action: { offset in
                onOffset(offset)
            }
            .padding(.leading, max(0, rect.minX))
            .padding(.top, max(0, rect.minY))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
