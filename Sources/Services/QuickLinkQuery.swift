import Foundation

/// The `{query}` slot inside a Quicklink's address: the one place a stored
/// link asks for words before it opens.
///
/// Three spellings name the same slot, so a link works however it arrived:
/// `{query}` (what the edit form teaches), `{{input}}` (Tuna's Smart Links),
/// and `{argument name="…"}` (how Raycast writes it, so a link pasted from
/// there works as it is). A link with several Raycast arguments gets the
/// same text in each.
///
/// A link without a slot never goes through here; it opens exactly as it
/// always did.
enum QuickLinkQuery {
    static let placeholder = "{query}"

    /// Characters left alone inside a query value. `&`, `=`, `+`, `#`, and
    /// `?` are encoded so a query with an ampersand cannot split into two
    /// parameters or drag a fragment along.
    static let allowed = CharacterSet.urlQueryAllowed.subtracting(
        CharacterSet(charactersIn: "&=+#?")
    )

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// The Tuna spelling of the slot.
    static let legacyPlaceholder = "{{input}}"

    /// The Raycast spelling: `{argument}` with any attributes.
    private static let argumentPattern = #"\{argument(\s[^{}]*)?\}"#

    static func contains(_ template: String) -> Bool {
        template.contains(placeholder)
            || template.contains(legacyPlaceholder)
            || template.range(of: argumentPattern, options: .regularExpression) != nil
    }

    /// The template with every slot filled by a plain word, for checking that
    /// what surrounds the slots is a web address. A Raycast slot holds a
    /// space, which no address may.
    static func validationSample(_ template: String) -> String {
        render(template, query: "x", clipboard: "x")
    }

    /// The address to open: every slot filled and percent-encoded. Pure, so
    /// the encoding is testable without a browser.
    static func render(_ template: String, query: String, clipboard: String) -> String {
        template
            .replacingOccurrences(of: placeholder, with: encode(query))
            // The two Smart Link spellings Tuna's own config uses.
            .replacingOccurrences(of: legacyPlaceholder, with: encode(query))
            .replacingOccurrences(
                of: argumentPattern,
                // A template, so a `$` or `\` in the encoded text stays literal.
                with: NSRegularExpression.escapedTemplate(for: encode(query)),
                options: .regularExpression
            )
            .replacingOccurrences(of: "{{clipboard}}", with: encode(clipboard))
    }
}
