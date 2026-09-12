import Foundation

/// The `{query}` slot inside a Quicklink's address: the one place a stored
/// link asks for words before it opens. Raycast spells it the same way.
///
/// A link without `{query}` never goes through here; it opens exactly as it
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

    static func contains(_ template: String) -> Bool {
        template.contains(placeholder)
    }

    /// The address to open: every slot filled and percent-encoded. Pure, so
    /// the encoding is testable without a browser.
    static func render(_ template: String, query: String, clipboard: String) -> String {
        template
            .replacingOccurrences(of: placeholder, with: encode(query))
            // The two Smart Link spellings Tuna's own config uses.
            .replacingOccurrences(of: "{{input}}", with: encode(query))
            .replacingOccurrences(of: "{{clipboard}}", with: encode(clipboard))
    }
}
