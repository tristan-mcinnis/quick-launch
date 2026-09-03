import Foundation
import AppKit
import Markdown

/// Converts a markdown string to an NSAttributedString using swift-markdown's AST.
enum MarkdownRenderer {

    /// The overlay re-evaluates its body for every state change, not only
    /// when the answer text changes; one entry is enough to make a repeat
    /// render free.
    @MainActor private static var cache: (source: String, rendered: NSAttributedString)?

    @MainActor static func cachedRender(_ markdown: String) -> NSAttributedString {
        if let cache, cache.source == markdown { return cache.rendered }
        let rendered = render(markdown)
        cache = (markdown, rendered)
        return rendered
    }

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
    private static func applyProseLineHeight(_ text: NSAttributedString) -> NSAttributedString {
        guard text.length > 0 else { return text }
        let leading = House.TypeToken.Size.body * (House.TypeToken.LineHeight.body - 1)
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

    @MainActor private static var heightCache: (source: String, width: CGFloat, height: CGFloat)?

    /// Height the rendered markdown needs at `width`, for window sizing.
    /// Replaces the old character-count guess, which under-estimated headed
    /// or code-heavy answers and left the last lines clipped.
    @MainActor static func measuredHeight(markdown: String, width: CGFloat) -> CGFloat {
        guard !markdown.isEmpty, width > 0 else { return 0 }
        if let heightCache, heightCache.source == markdown, heightCache.width == width {
            return heightCache.height
        }
        let rect = cachedRender(markdown).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // A little slack: NSTextView's layout rounds line fragments up.
        let height = rect.height.rounded(.up) + 4
        heightCache = (markdown, width, height)
        return height
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
