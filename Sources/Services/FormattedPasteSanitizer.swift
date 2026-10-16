import AppKit
import Foundation

/// A defence-in-depth filter over a rendered answer's rich representations.
///
/// The answer is rendered by `MarkdownRenderer` and its rich forms are
/// exported by AppKit, so the HTML is machine-generated and the RTF carries no
/// scripts. That does not make this a general-purpose HTML sanitizer, and it is
/// not advertised as one: it strips the risks that matter for this boundary —
/// script, plugin and resource-fetch elements, event-handler attributes, CSS
/// that fetches or executes, and links whose scheme is not a plain web or mail
/// link (including one written with character-entity escapes). Attribute URLs
/// are entity-decoded and whitespace-stripped before the scheme check, so
/// `java&#115;cript:` and `java\tscript:` are both refused.
enum FormattedPasteSanitizer {

    /// The only schemes a rendered answer's link may keep. Everything else
    /// (`javascript:`, `data:`, `file:`, `vbscript:`, a custom app scheme) is
    /// dropped from the attributed string, so it never reaches the RTF or HTML.
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    // MARK: - Attributed string

    /// A copy of `attributed` with every unsafe link removed. The link text
    /// stays; only the destination goes, so the answer still reads correctly.
    static func sanitizeLinks(_ attributed: NSAttributedString) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        let output = NSMutableAttributedString(attributedString: attributed)
        let whole = NSRange(location: 0, length: output.length)
        output.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard let value, let destination = url(from: value), !isSafeLink(destination) else { return }
            output.removeAttribute(.link, range: range)
        }
        return output
    }

    /// Whether a link may be kept. A URL with no scheme is a relative
    /// reference the destination resolves itself and cannot be a script.
    static func isSafeLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return true }
        return allowedLinkSchemes.contains(scheme)
    }

    private static func url(from value: Any) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    // MARK: - Presentation neutrality

    /// The colour attributes that carry the app's theme rather than the
    /// answer's meaning.
    private static let presentationColorKeys: [NSAttributedString.Key] = [
        .foregroundColor, .backgroundColor, .underlineColor,
        .strikethroughColor, .strokeColor,
    ]

    /// A copy of `attributed` with the presentation-only colours removed, so
    /// the exported HTML and RTF carry no theme ink. The dark theme's warm
    /// near-white text and its tinted code background would otherwise be baked
    /// into a paste bound for a white document. The semantic attributes — the
    /// font (headings, bold, italic, monospace code), the link, and the
    /// paragraph style (lists, spacing) — are untouched.
    static func presentationNeutral(_ attributed: NSAttributedString) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }
        let output = NSMutableAttributedString(attributedString: attributed)
        let whole = NSRange(location: 0, length: output.length)
        for key in presentationColorKeys {
            output.removeAttribute(key, range: whole)
        }
        return output
    }

    // MARK: - HTML

    /// Elements dropped with their content.
    private static let droppedBlocks = [
        "script", "iframe", "object", "applet", "noscript", "template",
        "svg", "math", "form", "select", "textarea", "button", "frameset",
        "frame", "video", "audio", "picture", "canvas", "map", "portal",
    ]

    /// Void elements dropped on sight, the resource-fetch ones included: the
    /// answer's images are alt text, never a remote load, so an `img` here can
    /// only be injected markup.
    private static let droppedVoid = [
        "embed", "input", "link", "meta", "base", "img", "source", "track",
        "area", "param", "col",
    ]

    /// Returns `html` with script, plugin, resource-fetch, event-handler,
    /// URL-fetching and unsafe-scheme content removed. A `<style>` block is
    /// kept only when it is closed and its CSS cannot fetch or execute
    /// anything, so AppKit's own font rules survive a formatted paste while
    /// injected CSS does not.
    static func sanitizeHTML(_ html: String) -> String {
        guard !html.isEmpty else { return html }
        var output = html
        output = replacing(output, #"(?is)<!--.*?-->"#) { _ in "" }

        // Blocks removed with everything between them, including an
        // unterminated one (a truncated `<script>` must not leak its body).
        for name in droppedBlocks {
            let paired = "(?is)<\(name)\\b[^>]*>.*?</\(name)\\s*>"
            output = replacing(output, paired) { _ in "" }
            let open = "(?is)<\(name)\\b[^>]*>"
            output = replacing(output, open) { _ in "" }
        }
        for name in droppedVoid {
            output = replacing(output, "(?is)<\(name)\\b[^>]*/?>") { _ in "" }
        }

        output = sanitizeStyleBlocks(output)
        output = replacing(output, "(?is)\\son\\w+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)") { _ in "" }
        output = sanitizeURLAttributes(output)
        output = sanitizeStyleAttributes(output)
        return output
    }

    /// Keeps only closed `<style>` blocks whose CSS is inert. An unclosed
    /// `<style>` drops the block and everything after it, so its CSS can never
    /// leak as text into the document.
    static func sanitizeStyleBlocks(_ html: String) -> String {
        var output = ""
        var remainder = Substring(html)
        while let open = remainder.range(of: "<style", options: [.caseInsensitive]) {
            output.append(contentsOf: remainder[remainder.startIndex..<open.lowerBound])
            let after = remainder[open.lowerBound...]
            guard let tagEnd = after.firstIndex(of: ">") else {
                // No end of the opening tag: drop the rest.
                return output
            }
            let opener = after[after.startIndex...tagEnd]
            let body = after[after.index(after: tagEnd)...]
            guard let close = body.range(of: "</style", options: [.caseInsensitive]),
                  let closeEnd = body[close.lowerBound...].firstIndex(of: ">") else {
                // Unclosed: drop the opener and everything after it.
                return output
            }
            let css = String(body[body.startIndex..<close.lowerBound])
            if isSafeStyle(css) {
                output.append(contentsOf: opener)
                output.append(contentsOf: body[body.startIndex...closeEnd])
            }
            remainder = body[body.index(after: closeEnd)...]
        }
        output.append(contentsOf: remainder)
        return output
    }

    /// CSS that can fetch a resource or run code is refused whole. The list is
    /// deliberately broad: a formatted paste has no CSS to preserve beyond
    /// AppKit's own font and margin rules.
    static func isSafeStyle(_ css: String) -> Bool {
        let lowered = css.lowercased()
        let forbidden = [
            "url(", "@import", "@font-face", "image-set(", "image(",
            "expression(", "javascript:", "vbscript:", "data:",
            "behavior:", "-moz-binding",
        ]
        return !forbidden.contains { lowered.contains($0) }
    }

    /// Rewrites `href`/`src`/`action` values with an unsafe scheme to `#`, so
    /// the link is inert instead of executable.
    private static func sanitizeURLAttributes(_ html: String) -> String {
        let pattern = #"(?is)\b(href|src|xlink:href|action|formaction|poster)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#
        return replacing(html, pattern) { match in
            guard let name = attributeName(of: match) else { return match }
            let value = attributeValue(of: match)
            return isSafeAttributeURL(value) ? match : "\(name)=\"#\""
        }
    }

    /// Drops a `style` attribute whose declarations fetch or execute.
    private static func sanitizeStyleAttributes(_ html: String) -> String {
        let pattern = #"(?is)\bstyle\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#
        return replacing(html, pattern) { match in
            isSafeStyle(attributeValue(of: match)) ? match : ""
        }
    }

    private static func attributeName(of match: String) -> String? {
        guard let equals = match.firstIndex(of: "=") else { return nil }
        return String(match[match.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
    }

    private static func attributeValue(of match: String) -> String {
        guard let equals = match.firstIndex(of: "=") else { return match }
        var value = String(match[match.index(after: equals)...])
            .trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Whether an attribute URL may be kept: no scheme (relative or anchor) or
    /// one of the allowed schemes. The value is entity-decoded and stripped of
    /// whitespace and control characters first, so an encoded or padded
    /// `javascript:` cannot pass as a relative path.
    static func isSafeAttributeURL(_ value: String) -> Bool {
        var scalars = String.UnicodeScalarView()
        for scalar in decodeEntities(value).unicodeScalars
        where !CharacterSet.whitespacesAndNewlines.contains(scalar)
            && !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar)
        }
        let normalized = String(scalars)
        guard !normalized.isEmpty else { return true }
        guard let colon = normalized.firstIndex(of: ":") else { return true }
        // A colon after a slash is part of a path, not a scheme.
        if let slash = normalized.firstIndex(of: "/"), slash < colon { return true }
        let scheme = String(normalized[normalized.startIndex..<colon]).lowercased()
        return allowedLinkSchemes.contains(scheme)
    }

    /// Expands the character references a browser would, so a scheme cannot be
    /// hidden behind `&#106;avascript:` or `java&Tab;script:`.
    static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var output = ""
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            guard character == "&" else {
                output.append(character)
                index = value.index(after: index)
                continue
            }
            guard let semicolon = value[index...].firstIndex(of: ";") else {
                output.append(character)
                index = value.index(after: index)
                continue
            }
            let name = String(value[value.index(after: index)..<semicolon])
            if let decoded = decodeEntity(name) {
                output.append(decoded)
                index = value.index(after: semicolon)
            } else {
                output.append(character)
                index = value.index(after: index)
            }
        }
        return output
    }

    private static func decodeEntity(_ name: String) -> Character? {
        switch name.lowercased() {
        case "colon": return ":"
        case "tab": return "\t"
        case "newline", "nl": return "\n"
        case "sol": return "/"
        case "lpar": return "("
        case "rpar": return ")"
        default: break
        }
        let lower = name.lowercased()
        if lower.hasPrefix("#x"),
           let value = UInt32(lower.dropFirst(2), radix: 16),
           let scalar = Unicode.Scalar(value) {
            return Character(scalar)
        }
        if lower.hasPrefix("#"),
           let value = UInt32(lower.dropFirst(), radix: 10),
           let scalar = Unicode.Scalar(value) {
            return Character(scalar)
        }
        return nil
    }

    // MARK: - Formatting detection

    /// Whether the rendered string holds structure a plain string cannot
    /// express. Body prose is the 14 pt system font with no traits; anything
    /// else (a heading size, bold, italic, fixed-pitch, a link, a code
    /// background, or a list indent) counts.
    static func carriesFormatting(_ attributed: NSAttributedString) -> Bool {
        guard attributed.length > 0 else { return false }
        var found = false
        let whole = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: whole) { attributes, _, stop in
            if Self.attributesCarryFormatting(attributes) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private static func attributesCarryFormatting(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
        if attributes[.link] != nil { return true }
        if attributes[.backgroundColor] != nil { return true }
        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) || traits.contains(.italic) { return true }
            if font.isFixedPitch { return true }
            if font.pointSize != 14 { return true }
        }
        if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
            if style.headIndent > 0 || style.firstLineHeadIndent > 0 { return true }
            if !style.textLists.isEmpty { return true }
        }
        return false
    }

    // MARK: - Regex helper

    /// Replaces every match of `pattern` with the result of `transform`. The
    /// regex is case-insensitive and dot-matches-newlines by default so the
    /// sanitizer reads the same way it writes.
    private static func replacing(
        _ text: String,
        _ pattern: String,
        transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let string = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: string.length))
        guard !matches.isEmpty else { return text }
        var output = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            guard range.location >= cursor else { continue }
            output += string.substring(with: NSRange(location: cursor, length: range.location - cursor))
            output += transform(string.substring(with: range))
            cursor = range.location + range.length
        }
        output += string.substring(from: cursor)
        return output
    }
}
