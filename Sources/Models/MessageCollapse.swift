import AppKit

/// How long a message has to be before the thread collapses it.
///
/// Raycast's Quick AI collapses a message you send when it runs over ten
/// lines and offers Show more; anything shorter is always shown in full, and
/// answers are never collapsed. A single paragraph that would wrap past ten
/// lines counts as long too, which the character budget below models without
/// laying out every message.
enum MessageCollapsePolicy {
    /// Lines at or below this count are always shown in full.
    static let collapsedLineCount = 10

    /// Lines the collapsed preview keeps before the Show more control.
    static let previewLineCount = 6

    /// Characters one rendered line of a thread pill holds: the pill's text
    /// column (the answer width less the pill's side padding, 666 pt) at the
    /// pill's type size (13 pt), measured once with a real text layout.
    /// About 105; 690 pt of 14 pt prose holds about 102.
    static let charactersPerLine = measuredCharactersPerLine(
        width: House.Layout.quickAIAnswerMaxWidth - House.Spacing.sm * 2,
        fontSize: House.TypeToken.Size.bodySmall
    )

    /// A single paragraph at or above this is collapsed like ten lines.
    static var collapsedCharacterCount: Int { collapsedLineCount * charactersPerLine }

    /// Explicit lines plus the wrapped remainder of each one.
    static func estimatedLineCount(of text: String) -> Int {
        let lines = text.components(separatedBy: .newlines)
        let wrapped = lines.reduce(0) { total, line in
            total + max(0, (line.count - 1) / charactersPerLine)
        }
        return lines.count + wrapped
    }

    static func shouldCollapse(_ text: String) -> Bool {
        estimatedLineCount(of: text) > collapsedLineCount
    }

    /// The first part shown while collapsed: the first `previewLineCount`
    /// lines, or the same character budget of a single paragraph, cut at a
    /// word boundary so it never ends mid-word.
    static func preview(of text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        if lines.count > 1 {
            return lines.prefix(previewLineCount).joined(separator: "\n")
        }
        let limit = previewLineCount * charactersPerLine
        guard text.count > limit else { return text }
        let cut = text.index(text.startIndex, offsetBy: limit)
        let head = text[text.startIndex..<cut]
        guard let lastSpace = head.lastIndex(where: \.isWhitespace) else { return String(head) }
        return String(head[head.startIndex..<lastSpace])
    }

    /// Typical question prose, long enough to wrap many times at any width
    /// the thread uses. Word wrap is part of the measure: a line breaks
    /// before the word that does not fit, so it holds fewer characters than
    /// the width over the average glyph.
    private static let measureSample = String(
        repeating: "Could you explain why the sky looks blue during the day but turns red and orange at sunset, and whether the same thing happens on Mars? ",
        count: 12
    )

    /// Characters per wrapped line of `measureSample` set in the system font
    /// at `fontSize` in a column `width` wide. Only full lines count; the
    /// last, partial line would pull the average down.
    static func measuredCharactersPerLine(width: CGFloat, fontSize: CGFloat) -> Int {
        let storage = NSTextStorage(
            string: measureSample,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        )
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        var lines = 0
        var glyph = 0
        var lastLineStart = 0
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            lines += 1
            lastLineStart = range.location
            glyph = NSMaxRange(range)
        }
        guard lines > 1 else { return max(1, measureSample.count) }
        let charactersInFullLines = layout.characterIndexForGlyph(at: lastLineStart)
        return max(1, charactersInFullLines / (lines - 1))
    }
}

/// The collapsed or expanded state of one message. The view reads only this,
/// so the threshold and both controls are testable without a text layout.
struct MessageCollapseState: Equatable, Sendable {
    let text: String
    private(set) var isExpanded: Bool
    /// Whether this message may collapse at all. Only what the user sends
    /// does; an answer, and a question that is not a turn yet, always show
    /// in full.
    let collapses: Bool

    init(text: String, isExpanded: Bool = false, collapses: Bool = true) {
        self.text = text
        self.isExpanded = isExpanded
        self.collapses = collapses
    }

    /// Only a long message ever grows a control; a short one shows in full.
    var isCollapsible: Bool { collapses && MessageCollapsePolicy.shouldCollapse(text) }

    var isCollapsed: Bool { isCollapsible && !isExpanded }

    /// What the thread draws right now.
    var displayedText: String {
        isCollapsed ? MessageCollapsePolicy.preview(of: text) : text
    }

    /// The control under the message, or nil when the message is short.
    var controlTitle: String? {
        guard isCollapsible else { return nil }
        return isExpanded ? "Collapse" : "Show more"
    }

    /// The state the control announces, always from the reader's point of
    /// view: a collapsed message is "Collapsed" whether or not a control is
    /// drawn yet.
    var accessibilityState: String { isExpanded ? "Expanded" : "Collapsed" }

    mutating func setExpanded(_ expanded: Bool) { isExpanded = expanded }

    mutating func toggle() { isExpanded.toggle() }
}
