import AppKit
import Foundation

/// Turns a rendered markdown answer into the three representations a
/// formatted paste publishes.
///
/// The answer is rendered once through the same `MarkdownRenderer` the
/// overlay draws, so what is pasted is what was on screen. The attributed
/// string is sanitized first (unsafe links removed), then AppKit exports its
/// HTML and RTF, and the HTML passes `FormattedPasteSanitizer` as a second
/// layer. Nothing here shells out: the conversion is AppKit's own.
@MainActor
enum FormattedPasteBuilder {

    /// The public entry point: a markdown answer in, its representations out.
    static func representation(fromMarkdown markdown: String) -> FormattedPasteRepresentation {
        representation(fromAttributed: MarkdownRenderer.render(markdown))
    }

    /// The testable core: an already-rendered answer in, its representations
    /// out. Exposed so a test can drive the export without rendering markdown.
    static func representation(fromAttributed source: NSAttributedString) -> FormattedPasteRepresentation {
        let clean = FormattedPasteSanitizer.presentationNeutral(
            FormattedPasteSanitizer.sanitizeLinks(source)
        )
        let plain = clean.string
        guard clean.length > 0 else {
            return FormattedPasteRepresentation(plainText: plain, html: "", rtf: Data())
        }
        return FormattedPasteRepresentation(
            plainText: plain,
            html: FormattedPasteSanitizer.sanitizeHTML(htmlString(from: clean)),
            rtf: rtfData(from: clean) ?? Data(),
            carriesFormatting: FormattedPasteSanitizer.carriesFormatting(clean)
        )
    }

    private static func htmlString(from attributed: NSAttributedString) -> String {
        export(attributed, as: .html).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func rtfData(from attributed: NSAttributedString) -> Data? {
        export(attributed, as: .rtf)
    }

    private static func export(
        _ attributed: NSAttributedString,
        as type: NSAttributedString.DocumentType
    ) -> Data? {
        let whole = NSRange(location: 0, length: attributed.length)
        return try? attributed.data(
            from: whole,
            documentAttributes: [.documentType: type]
        )
    }
}
