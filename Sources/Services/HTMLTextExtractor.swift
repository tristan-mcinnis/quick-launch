import Foundation

/// Converts fetched HTML into readable plain text for model context.
///
/// Deliberately dependency-free and deterministic: drops non-content
/// elements, prefers the article/main body, converts block tags to line
/// breaks, and decodes the common entities. Not a full HTML engine — good
/// enough for answer context, which is all it is used for.
enum HTMLTextExtractor {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        regex(pattern).stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    /// Extracts the document title, entities decoded, or nil when absent.
    static func title(from html: String) -> String? {
        let pattern = regex("<title[^>]*>(.*?)</title\\s*>")
        guard let match = pattern.firstMatch(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        ), let range = Range(match.range(at: 1), in: html)
        else { return nil }
        let decoded = decodingEntities(String(html[range]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    /// Extracts readable plain text from an HTML document.
    static func text(from html: String) -> String {
        var working = html

        // Comments and elements that never carry readable content.
        working = replace("<!--.*?-->", in: working, with: " ")
        for tag in ["script", "style", "noscript", "template", "svg", "head", "nav"] {
            working = replace("<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", in: working, with: " ")
        }

        // Prefer the main content block when the page has one.
        for container in ["article", "main"] {
            let pattern = regex("<\(container)\\b[^>]*>(.*?)</\(container)\\s*>")
            if let match = pattern.firstMatch(
                in: working,
                range: NSRange(working.startIndex..., in: working)
            ), let range = Range(match.range(at: 1), in: working) {
                working = String(working[range])
                break
            }
        }

        // Line breaks where reading flow needs them.
        working = replace("<br\\s*/?>", in: working, with: "\n")
        working = replace("<li\\b[^>]*>", in: working, with: "\n- ")
        for closer in [
            "p", "div", "section", "article", "header", "main", "figure",
            "figcaption", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr",
            "blockquote", "pre", "table", "ul", "ol",
        ] {
            working = replace("</\(closer)\\s*>", in: working, with: "\n")
        }
        working = replace("<[^>]+>", in: working, with: " ")

        var decoded = decodingEntities(working)
        decoded = decoded
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let lines = decoded
            .components(separatedBy: .newlines)
            .map { line in
                regex(" {2,}").stringByReplacingMatches(
                    in: line,
                    range: NSRange(line.startIndex..., in: line),
                    withTemplate: " "
                )
                .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "hellip": "\u{2026}", "rsquo": "\u{2019}", "lsquo": "\u{2018}",
        "rdquo": "\u{201D}", "ldquo": "\u{201C}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "deg": "\u{00B0}",
        "eacute": "\u{00E9}", "egrave": "\u{00E8}", "agrave": "\u{00E0}",
        "ccedil": "\u{00E7}", "uuml": "\u{00FC}", "ouml": "\u{00F6}",
        "auml": "\u{00E4}", "szlig": "\u{00DF}",
    ]

    /// Decodes named, decimal, and hexadecimal character references.
    static func decodingEntities(_ text: String) -> String {
        let pattern = regex("&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);")
        var result = ""
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let fullRange = Range(match.range, in: text) else { continue }
            result += text[cursor..<fullRange.lowerBound]
            let body = String(text[fullRange].dropFirst().dropLast())
            result += decodedEntity(body) ?? String(text[fullRange])
            cursor = fullRange.upperBound
        }
        result += text[cursor...]
        return result
    }

    private static func decodedEntity(_ body: String) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            guard let value = UInt32(body.dropFirst(2), radix: 16),
                  let scalar = Unicode.Scalar(value)
            else { return nil }
            return String(Character(scalar))
        }
        if body.hasPrefix("#") {
            guard let value = UInt32(body.dropFirst()),
                  let scalar = Unicode.Scalar(value)
            else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[body.lowercased()]
    }
}
