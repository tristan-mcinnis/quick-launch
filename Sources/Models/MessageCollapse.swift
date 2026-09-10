import Foundation

/// How long a message has to be before the transcript collapses it.
///
/// Raycast's Quick AI collapses a message over ten lines and offers Show
/// more; anything shorter is always shown in full. A single paragraph that
/// would wrap past ten lines counts as long too, which the character budget
/// below models without asking for a text layout.
enum MessageCollapsePolicy {
    /// Lines at or below this count are always shown in full.
    static let collapsedLineCount = 10

    /// Lines the collapsed preview keeps before the Show more control.
    static let previewLineCount = 6

    /// Characters one rendered line holds at the transcript's width in the
    /// detail type token. Ten of these is "a comparably long single
    /// paragraph".
    static let charactersPerLine = 60

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
}

/// The collapsed or expanded state of one message. The view reads only this,
/// so the threshold and both controls are testable without a text layout.
struct MessageCollapseState: Equatable, Sendable {
    let text: String
    private(set) var isExpanded: Bool

    init(text: String, isExpanded: Bool = false) {
        self.text = text
        self.isExpanded = isExpanded
    }

    /// Only a long message ever grows a control; a short one shows in full.
    var isCollapsible: Bool { MessageCollapsePolicy.shouldCollapse(text) }

    var isCollapsed: Bool { isCollapsible && !isExpanded }

    /// What the transcript draws right now.
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
