import Foundation
import AppKit
import Markdown

/// One slice of an assistant answer: a run of markdown, or a fenced code
/// block lifted out of the prose stream so it can draw as its own block.
struct AnswerSegment: Identifiable, Equatable {
    enum Content: Equatable {
        /// A run of markdown between code blocks.
        case prose(String)
        /// A fenced code block, with the language and code its fence carried.
        case code(CodeBlockContent)
    }

    /// Position in the answer. Stable while text streams onto the end.
    let id: Int
    let content: Content
}

/// A bounded cache of parsed, rendered or measured answer text, with one
/// extra slot for the answer still arriving.
///
/// The answer in flight produces a new string on every stream flush, about
/// thirty times a second. Those strings are never asked for twice. Held in
/// the same store as the finished answers they would fill it within a
/// second, evicting every answer above them, and the thread would then
/// re-parse and re-measure all of them on the next body pass. So a value
/// marked `transient` goes to its own slot and never displaces a settled
/// one. A lookup still reads both, so nothing is ever recomputed needlessly.
@MainActor
struct MarkdownCache<Key: Hashable, Value> {
    /// Finished answers, keyed by their own text. `order` is insertion
    /// order, so the oldest entry is the one evicted.
    private var settled: [Key: Value] = [:]
    private var order: [Key] = []
    /// The answer still streaming. One slot, replaced on every flush.
    private var live: (key: Key, value: Value)?
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func value(for key: Key) -> Value? {
        if let settledValue = settled[key] { return settledValue }
        if let live, live.key == key { return live.value }
        return nil
    }

    mutating func insert(_ value: Value, for key: Key, transient: Bool) {
        guard !transient else {
            live = (key, value)
            return
        }
        if settled.updateValue(value, forKey: key) == nil {
            order.append(key)
            while order.count > limit {
                settled.removeValue(forKey: order.removeFirst())
            }
        }
    }

    /// Entries held, for tests. The live slot is not one of them.
    var settledCount: Int { settled.count }
}

/// Converts a markdown string to an NSAttributedString using swift-markdown's AST.
enum MarkdownRenderer {

    /// The vertical gap between two segments in the answer stack. The view
    /// reads this and so does `measuredHeight`, so the drawn stack and the
    /// measured window cannot drift.
    static let segmentSpacing: CGFloat = House.Spacing.xs

    // MARK: - Segments

    @MainActor private static var segmentsCache = MarkdownCache<String, [AnswerSegment]>(limit: 64)

    /// The answer split at its fenced code blocks, cached for the view and
    /// for `measuredHeight`.
    ///
    /// Pass `transient: true` for the answer still streaming, so its
    /// per-flush strings never evict the answers above it.
    @MainActor static func cachedSegments(
        _ markdown: String,
        transient: Bool = false
    ) -> [AnswerSegment] {
        if let hit = segmentsCache.value(for: markdown) { return hit }
        let segments = segments(markdown)
        segmentsCache.insert(segments, for: markdown, transient: transient)
        return segments
    }

    /// The answer split at its fenced code blocks: prose, code, prose, in
    /// document order. A document with no fenced code block is one prose
    /// segment, so a code-free answer renders exactly as it always did.
    static func segments(_ markdown: String) -> [AnswerSegment] {
        guard !markdown.isEmpty else { return [] }
        let bytes = Array(markdown.utf8)
        let lineStarts = utf8LineStarts(bytes)
        let spans = codeSpans(
            in: Document(parsing: markdown),
            bytes: bytes,
            lineStarts: lineStarts
        )
        guard !spans.isEmpty else {
            return [AnswerSegment(id: 0, content: .prose(markdown))]
        }

        var segments: [AnswerSegment] = []
        var cursor = 0
        for span in spans {
            // A code block inside a block already taken is part of the outer
            // block's code text, not a segment of its own.
            guard span.range.lowerBound >= cursor else { continue }
            appendProse(
                markdown,
                bytes: bytes,
                range: cursor..<span.range.lowerBound,
                into: &segments
            )
            segments.append(AnswerSegment(id: segments.count, content: .code(span.content)))
            cursor = span.range.upperBound
        }
        appendProse(markdown, bytes: bytes, range: cursor..<bytes.count, into: &segments)
        return segments
    }

    /// A fenced code block's byte range in the source, and what it carries.
    private struct CodeSpan {
        let range: Range<Int>
        let content: CodeBlockContent
    }

    private static func codeSpans(
        in document: Markup,
        bytes: [UInt8],
        lineStarts: [Int]
    ) -> [CodeSpan] {
        var blocks: [CodeBlock] = []
        collectCodeBlocks(document, into: &blocks)
        return blocks.compactMap { block in
            guard let source = block.range,
                  let lower = utf8Offset(of: source.lowerBound, lineStarts: lineStarts),
                  let upper = utf8Offset(of: source.upperBound, lineStarts: lineStarts),
                  lower < upper, upper <= bytes.count
            else { return nil }
            return CodeSpan(
                range: lower..<upper,
                content: CodeBlockContent(infoString: block.language, code: codeText(block))
            )
        }
        .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func collectCodeBlocks(_ markup: Markup, into blocks: inout [CodeBlock]) {
        if let block = markup as? CodeBlock {
            blocks.append(block)
            return
        }
        for child in markup.children {
            collectCodeBlocks(child, into: &blocks)
        }
    }

    /// The code a fenced block wraps, without the fence's trailing newline.
    private static func codeText(_ block: CodeBlock) -> String {
        block.code.hasSuffix("\n") ? String(block.code.dropLast()) : block.code
    }

    /// The parser reports a line and a UTF-8 byte column, so turning a source
    /// location into a byte offset needs the offset each line starts at.
    private static func utf8LineStarts(_ bytes: [UInt8]) -> [Int] {
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            starts.append(offset + 1)
        }
        return starts
    }

    private static func utf8Offset(of location: SourceLocation, lineStarts: [Int]) -> Int? {
        guard location.line >= 1, location.line <= lineStarts.count else { return nil }
        return lineStarts[location.line - 1] + max(0, location.column - 1)
    }

    private static func appendProse(
        _ markdown: String,
        bytes: [UInt8],
        range: Range<Int>,
        into segments: inout [AnswerSegment]
    ) {
        guard !range.isEmpty else { return }
        let source = String(decoding: bytes[range], as: UTF8.self)
        // The blank lines around a fence are not a segment of their own.
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        segments.append(AnswerSegment(id: segments.count, content: .prose(source)))
    }

    // MARK: - Rendering

    /// The overlay re-evaluates its body for every state change, not only
    /// when the answer text changes; a small cache makes a repeat render
    /// free. Keyed by source: an answer is several prose runs around its code
    /// blocks, and while streaming only the last one changes.
    @MainActor private static var renderCache = MarkdownCache<String, NSAttributedString>(limit: 64)

    /// Pass `transient: true` for the run still streaming, so its per-flush
    /// strings never evict the finished answers above it.
    @MainActor static func cachedRender(
        _ markdown: String,
        transient: Bool = false
    ) -> NSAttributedString {
        if let hit = renderCache.value(for: markdown) { return hit }
        let rendered = render(markdown)
        renderCache.insert(rendered, for: markdown, transient: transient)
        return rendered
    }

    /// Renders a whole markdown document into one attributed string. The
    /// answer body draws each prose segment from `segments(_:)` instead, so
    /// fenced code gets its own block; this stays the document renderer.
    static func render(_ markdown: String) -> NSAttributedString {
        guard !markdown.isEmpty else { return NSAttributedString() }
        let document = Document(parsing: markdown)
        var walker = AttributedStringWalker()
        walker.visit(document)
        return applyProseLineHeight(walker.result)
    }

    /// The house answer line height (1.55) as leading, added in one pass at
    /// the end so list hanging indents and paragraph spacing survive.
    /// `measuredHeight` reads the same string, so the window cannot drift.
    /// The leading is the target minus SF's own line height
    /// (`AQDesign.TypeToken.proseLineSpacing`), about 5 pt for 14 pt text.
    private static func applyProseLineHeight(_ text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0 else { return text }
        let leading = AQDesign.TypeToken.proseLineSpacing
        let output = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            style.lineSpacing = leading
            output.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return output
    }

    /// A measured run is one text at one width; the width changes when the
    /// window resizes, so it belongs in the key.
    struct MeasuredRun: Hashable {
        let source: String
        let width: CGFloat
    }

    @MainActor private static var heightCache = MarkdownCache<MeasuredRun, CGFloat>(limit: 64)

    /// Height one prose run needs at `width`. Reads the same string the text
    /// view draws, so the measurement cannot drift from the render.
    ///
    /// Pass `transient: true` for the run still streaming: text layout is the
    /// most expensive thing here, and a live answer would otherwise evict
    /// every finished measurement in under a second.
    @MainActor static func proseHeight(
        markdown: String,
        width: CGFloat,
        transient: Bool = false
    ) -> CGFloat {
        guard !markdown.isEmpty, width > 0 else { return 0 }
        let key = MeasuredRun(source: markdown, width: width)
        if let hit = heightCache.value(for: key) { return hit }
        let rect = cachedRender(markdown, transient: transient).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = rect.height.rounded(.up)
        heightCache.insert(height, for: key, transient: transient)
        return height
    }

    /// Height the answer needs at `width`, for window sizing: prose measured
    /// from the string it renders, code blocks from their own chrome and
    /// lines. Replaces the old character-count guess, which under-estimated
    /// headed or code-heavy answers and left the last lines clipped.
    @MainActor static func measuredHeight(markdown: String, width: CGFloat) -> CGFloat {
        guard !markdown.isEmpty, width > 0 else { return 0 }
        let segments = cachedSegments(markdown)
        guard !segments.isEmpty else { return 0 }
        var height: CGFloat = 0
        for (index, segment) in segments.enumerated() {
            if index > 0 { height += segmentSpacing }
            switch segment.content {
            case .prose(let source):
                height += proseHeight(markdown: source, width: width)
            case .code(let content):
                height += CodeBlockMetrics.height(of: content, width: width)
            }
        }
        // A little slack: NSTextView's layout rounds line fragments up.
        return height.rounded(.up) + 4
    }
}

// MARK: - AST Walker

private struct AttributedStringWalker: MarkupWalker {
    private let output = NSMutableAttributedString()
    private var fontTraits: NSFontDescriptor.SymbolicTraits = []
    private var isMonospace = false
    private var linkURL: URL?
    private var headingLevel: Int = 0
    private var listDepth: Int = 0
    private var orderedIndex: Int? = nil
    private var blockQuoteDepth: Int = 0
    private var isStrikethrough = false
    private var isTableHeader = false
    /// Set after a list-item marker or a blockquote break so the block that
    /// follows continues the same line instead of opening a new paragraph.
    /// Without it every bullet rendered as "•", a blank line, then its text.
    private var suppressBlockBreak = false

    var result: NSAttributedString { output }

    // MARK: - Block elements

    /// The blank line between blocks, unless the current block belongs to
    /// the marker that was just drawn.
    private mutating func blockBreak(_ count: Int) {
        if suppressBlockBreak {
            suppressBlockBreak = false
            return
        }
        if output.length > 0 { appendNewlines(count) }
    }

    mutating func visitHeading(_ heading: Heading) {
        blockBreak(2)
        headingLevel = heading.level
        descendInto(heading)
        headingLevel = 0
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        // Inside a list a paragraph stays close to its item; only top-level
        // prose gets the full blank line.
        blockBreak(listDepth > 0 ? 1 : 2)
        descendInto(paragraph)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        blockBreak(2)
        let code = codeBlock.code.hasSuffix("\n")
            ? String(codeBlock.code.dropLast())
            : codeBlock.code
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: House.NSColorToken.surfaceTint,
        ]
        output.append(NSAttributedString(string: code, attributes: attrs))
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        listDepth += 1
        descendInto(list)
        listDepth -= 1
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        listDepth += 1
        orderedIndex = 1
        descendInto(list)
        orderedIndex = nil
        listDepth -= 1
    }

    mutating func visitListItem(_ item: ListItem) {
        if output.length > 0 { appendNewlines(1) }
        let start = output.length
        let indent = String(repeating: "  ", count: max(0, listDepth - 1))
        if let checkbox = item.checkbox {
            let marker = checkbox == .checked ? "\u{2611} " : "\u{2610} "
            appendText("\(indent)\(marker)")
        } else if let idx = orderedIndex {
            appendText("\(indent)\(idx). ")
            orderedIndex = idx + 1
        } else {
            appendText("\(indent)\u{2022} ")
        }
        suppressBlockBreak = true
        descendInto(item)
        // Hanging indent: wrapped lines align under the text, not under the
        // bullet, with a little air between items. Nested items styled their
        // own ranges already, so only fill where no style exists yet.
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = CGFloat(listDepth) * 18
        style.paragraphSpacingBefore = 3
        let range = NSRange(location: start, length: output.length - start)
        output.enumerateAttribute(.paragraphStyle, in: range) { value, subRange, _ in
            if value == nil {
                output.addAttribute(.paragraphStyle, value: style, range: subRange)
            }
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        blockQuoteDepth += 1
        if output.length > 0 { appendNewlines(1) }
        suppressBlockBreak = true
        descendInto(blockQuote)
        blockQuoteDepth -= 1
    }

    mutating func visitTable(_ table: Table) {
        blockBreak(2)
        descendInto(table)
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        isTableHeader = true
        // Render header row as tab-separated bold cells
        var first = true
        for cell in tableHead.cells {
            if !first { appendText("\t") }
            first = false
            visit(cell)
        }
        isTableHeader = false
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        descendInto(tableBody)
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        if output.length > 0 { appendNewlines(1) }
        var first = true
        for cell in tableRow.cells {
            if !first { appendText("\t") }
            first = false
            visit(cell)
        }
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        descendInto(tableCell)
    }

    // MARK: - Inline elements

    mutating func visitText(_ text: Markdown.Text) {
        appendText(text.string)
    }

    mutating func visitStrong(_ strong: Strong) {
        fontTraits.insert(.bold)
        descendInto(strong)
        fontTraits.remove(.bold)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        fontTraits.insert(.italic)
        descendInto(emphasis)
        fontTraits.remove(.italic)
    }

    mutating func visitInlineCode(_ code: InlineCode) {
        let prev = isMonospace
        isMonospace = true
        appendText(code.code)
        isMonospace = prev
    }

    mutating func visitLink(_ link: Markdown.Link) {
        if let dest = link.destination, let url = URL(string: dest) {
            linkURL = url
        }
        descendInto(link)
        linkURL = nil
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        isStrikethrough = true
        descendInto(strikethrough)
        isStrikethrough = false
    }

    mutating func visitImage(_ image: Markdown.Image) {
        // Show alt text (the inline children of the image node)
        appendText("\u{1F5BC} ")
        descendInto(image)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        appendText(" ")
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        appendNewlines(1)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        if output.length > 0 { appendNewlines(1) }
        appendText("---")
        appendNewlines(1)
    }

    // MARK: - Helpers

    private func appendText(_ text: String) {
        // Default to the adaptive system label color so output stays visible
        // in both light and dark mode (issues #20, #23). Blockquote / link
        // branches below override this when they need a different color.
        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
        ]

        // Determine effective bold state (explicit bold OR table header)
        let effectiveBold = fontTraits.contains(.bold) || isTableHeader

        if isMonospace {
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            attrs[.backgroundColor] = House.NSColorToken.surfaceTint
        } else if headingLevel > 0 {
            let size: CGFloat = headingLevel == 1 ? 20 : headingLevel == 2 ? 17 : 15
            var descriptor = NSFont.systemFont(ofSize: size, weight: .bold).fontDescriptor
            if fontTraits.contains(.italic) {
                descriptor = descriptor.withSymbolicTraits(
                    descriptor.symbolicTraits.union(.italic))
            }
            attrs[.font] = NSFont(descriptor: descriptor, size: size)
        } else {
            let weight: NSFont.Weight = effectiveBold ? .bold : .regular
            let base = NSFont.systemFont(ofSize: 14, weight: weight)
            if fontTraits.contains(.italic) {
                let descriptor = base.fontDescriptor.withSymbolicTraits(
                    base.fontDescriptor.symbolicTraits.union(.italic))
                attrs[.font] = NSFont(descriptor: descriptor, size: 14)
            } else {
                attrs[.font] = base
            }
        }

        if let url = linkURL {
            attrs[.link] = url
            attrs[.foregroundColor] = NSColor.linkColor
        }

        // Blockquote styling: supporting ink, not a second grey.
        if blockQuoteDepth > 0 {
            attrs[.foregroundColor] = House.NSColorToken.textSecondary
        }

        // Strikethrough
        if isStrikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        output.append(NSAttributedString(string: text, attributes: attrs))
    }

    private func appendNewlines(_ count: Int) {
        let nl = String(repeating: "\n", count: count)
        output.append(NSAttributedString(string: nl, attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
        ]))
    }
}
