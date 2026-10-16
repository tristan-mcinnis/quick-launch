import Foundation

/// The representations of a rendered answer published together for one paste.
///
/// The plain text is the fallback every destination accepts; the HTML and RTF
/// are what keep the answer's headings, emphasis, lists, links and code in a
/// destination that reads them. `carriesFormatting` records whether the
/// rendered answer actually held any of that structure, so a plain-prose
/// answer can take the ordinary plain paste route instead of the rich one.
struct FormattedPasteRepresentation: Equatable, Sendable {
    /// The answer as text, with markdown syntax already resolved.
    let plainText: String
    /// The answer as a sanitized HTML fragment, empty when none was produced.
    let html: String
    /// The answer as RTF bytes, empty when none was produced.
    let rtf: Data
    /// Whether the rendered answer carried structure only the rich
    /// representations preserve (a heading, bold, italic, a list, a link, or
    /// code). A purely plain-prose answer is false.
    let carriesFormatting: Bool

    init(plainText: String, html: String, rtf: Data, carriesFormatting: Bool = false) {
        self.plainText = plainText
        self.html = html
        self.rtf = rtf
        self.carriesFormatting = carriesFormatting
    }

    /// Whether the rich representations are present at all.
    var hasRichRepresentation: Bool { !html.isEmpty || !rtf.isEmpty }

    /// The representations a paste should publish: rich only when the answer
    /// carries formatting and a rich form was produced.
    var prefersRichPaste: Bool { carriesFormatting && hasRichRepresentation }

    static let empty = FormattedPasteRepresentation(plainText: "", html: "", rtf: Data())
}
