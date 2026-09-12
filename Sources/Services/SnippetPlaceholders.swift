import Foundation

/// What one expansion produced: the text to insert and, when the template
/// asked for it, where the caret belongs inside that text.
struct SnippetExpansion: Equatable, Sendable {
    var text: String
    /// Character offset of `{cursor}` inside `text`, or nil when the
    /// template never placed one.
    var cursorOffset: Int?

    static let empty = SnippetExpansion(text: "", cursorOffset: nil)
}

/// One `{argument}` the user fills before the snippet is inserted, in the
/// order the template mentions it first.
struct SnippetArgument: Equatable, Sendable, Identifiable {
    /// The slot's label: the template's `name="…"`, or "Argument 1".
    let name: String
    /// Position in the prompt order, from zero.
    let index: Int
    /// Text used when the user leaves the slot empty.
    let defaultValue: String

    var id: Int { index }
}

/// Raycast-style dynamic placeholders inside a snippet's own text, expanded
/// at insert time. Nothing here touches the clipboard, the clock, or any
/// store: every input arrives as a parameter, so the whole engine is a pure
/// function over (template, clipboard, now, arguments).
///
/// Grammar
/// -------
///     {cursor}
///     {clipboard}            {clipboard | raw}
///     {date}                 {date format="yyyy-MM-dd" offset="+3M -5d"}
///     {time}                 {time format="HH:mm" offset="-90m"}
///     {argument}             {argument name="Client" default="Acme"}
///
/// A placeholder may carry `key="value"` attributes and any number of
/// trailing `| modifier` pipes (`uppercase`, `lowercase`, `raw`). A name the
/// engine does not know passes through unchanged, braces and all, so a
/// snippet about `{json}` still reads as itself. `\{` types a literal brace.
enum SnippetPlaceholders {
    // MARK: - Public API

    /// Every `{argument}` slot in prompt order. Two slots with the same
    /// `name=` are one slot, asked once.
    static func arguments(in template: String) -> [SnippetArgument] {
        var slots: [SnippetArgument] = []
        var seen: [String: Int] = [:]
        for token in tokenize(template) {
            guard case .placeholder(let placeholder) = token, placeholder.kind == .argument else { continue }
            let label = placeholder.attributes["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
            let key = label.isEmpty ? "\u{0}position-\(slots.count)" : label.lowercased()
            if seen[key] != nil { continue }
            seen[key] = slots.count
            slots.append(SnippetArgument(
                name: label.isEmpty ? "Argument \(slots.count + 1)" : label,
                index: slots.count,
                defaultValue: placeholder.attributes["default"] ?? ""
            ))
        }
        return slots
    }

    /// True when the template holds at least one placeholder the engine
    /// would expand. An unknown placeholder does not count: it is literal text.
    static func containsPlaceholders(_ template: String) -> Bool {
        tokenize(template).contains { token in
            if case .placeholder = token { return true }
            return false
        }
    }

    /// Expands `template`. `clipboard` nil means the clipboard held no text;
    /// `arguments` are positional, matching `arguments(in:)`, and a missing
    /// one falls back to its `default=` and then to empty.
    static func expand(
        _ template: String,
        clipboard: String? = nil,
        now: Date = Date(),
        arguments: [String] = [],
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> SnippetExpansion {
        // Slots are numbered here exactly as `arguments(in:)` numbers them,
        // so the values the user typed line up with the prompts they saw.
        var slotIndex: [String: Int] = [:]
        var nextSlot = 0

        var output = ""
        var cursorOffset: Int?

        for token in tokenize(template) {
            switch token {
            case .literal(let text):
                output += text
            case .placeholder(let placeholder):
                switch placeholder.kind {
                case .cursor:
                    // The first {cursor} wins; later ones simply disappear,
                    // as one caret is all an insertion has.
                    if cursorOffset == nil { cursorOffset = output.count }
                case .clipboard:
                    output += apply(placeholder.modifiers, to: clipboard ?? "")
                case .date, .time:
                    output += apply(
                        placeholder.modifiers,
                        to: formatted(
                            placeholder,
                            now: now,
                            timeZone: timeZone,
                            locale: locale
                        )
                    )
                case .argument:
                    let label = placeholder.attributes["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
                    let key = label.isEmpty ? "\u{0}position-\(nextSlot)" : label.lowercased()
                    let index: Int
                    if let known = slotIndex[key] {
                        index = known
                    } else {
                        index = nextSlot
                        slotIndex[key] = nextSlot
                        nextSlot += 1
                    }
                    var value = arguments.indices.contains(index) ? arguments[index] : ""
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        value = placeholder.attributes["default"] ?? value
                    }
                    output += apply(placeholder.modifiers, to: value)
                }
            }
        }
        return SnippetExpansion(text: output, cursorOffset: cursorOffset)
    }

    // MARK: - Modifiers

    /// `raw` inserts the value exactly as it arrived; without it a value is
    /// trimmed of surrounding whitespace and newlines, which is the one
    /// piece of "formatting" the engine does. `uppercase` and `lowercase`
    /// apply after that, in the order written.
    private static func apply(_ modifiers: [Modifier], to value: String) -> String {
        var text = modifiers.contains(.raw)
            ? value
            : value.trimmingCharacters(in: .whitespacesAndNewlines)
        for modifier in modifiers {
            switch modifier {
            case .raw: break
            case .uppercase: text = text.uppercased()
            case .lowercase: text = text.lowercased()
            }
        }
        return text
    }

    // MARK: - Dates

    private static let defaultDateFormat = "yyyy-MM-dd"
    private static let defaultTimeFormat = "HH:mm"

    private static func formatted(
        _ placeholder: Placeholder,
        now: Date,
        timeZone: TimeZone,
        locale: Locale
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        let date = offsetDate(
            now,
            offset: placeholder.attributes["offset"] ?? "",
            calendar: calendar
        )
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.dateFormat = placeholder.attributes["format"]
            ?? (placeholder.kind == .time ? defaultTimeFormat : defaultDateFormat)
        return formatter.string(from: date)
    }

    /// `+3M -5d`, `-90m`, `+1y`: signed amounts with a unit each, applied in
    /// order. `M` is months and `m` is minutes, as in a date format string.
    /// An unreadable term is skipped rather than failing the whole insertion.
    static func offsetDate(_ date: Date, offset: String, calendar: Calendar) -> Date {
        var result = date
        for term in offset.split(whereSeparator: { $0 == " " || $0 == "," }) {
            guard let (amount, unit) = parseOffsetTerm(String(term)) else { continue }
            result = calendar.date(byAdding: unit, value: amount, to: result) ?? result
        }
        return result
    }

    private static func parseOffsetTerm(_ term: String) -> (Int, Calendar.Component)? {
        guard let unitCharacter = term.last else { return nil }
        let component: Calendar.Component
        switch unitCharacter {
        case "y", "Y": component = .year
        case "M": component = .month
        case "w", "W": component = .weekOfYear
        case "d", "D": component = .day
        case "h", "H": component = .hour
        case "m": component = .minute
        case "s", "S": component = .second
        default: return nil
        }
        var digits = String(term.dropLast())
        var sign = 1
        if digits.hasPrefix("+") {
            digits.removeFirst()
        } else if digits.hasPrefix("-") {
            sign = -1
            digits.removeFirst()
        }
        guard let value = Int(digits) else { return nil }
        return (sign * value, component)
    }

    // MARK: - Tokenizer

    enum Kind: String, Sendable {
        case cursor, clipboard, date, time, argument
    }

    enum Modifier: String, Sendable {
        case uppercase, lowercase, raw
    }

    struct Placeholder: Sendable {
        let kind: Kind
        let attributes: [String: String]
        let modifiers: [Modifier]
    }

    private enum Token {
        case literal(String)
        case placeholder(Placeholder)
    }

    /// Splits the template into literal runs and recognised placeholders.
    /// Anything unrecognised — an unknown name, a malformed body, an
    /// unclosed brace — stays a literal, so nothing is ever eaten.
    private static func tokenize(_ template: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        var index = template.startIndex

        func flush() {
            guard !literal.isEmpty else { return }
            tokens.append(.literal(literal))
            literal = ""
        }

        while index < template.endIndex {
            let character = template[index]
            if character == "\\" {
                let next = template.index(after: index)
                // A backslash escapes a brace or another backslash; anywhere
                // else it is just a backslash, as in a Windows path.
                if next < template.endIndex, "{}\\".contains(template[next]) {
                    literal.append(template[next])
                    index = template.index(after: next)
                } else {
                    literal.append(character)
                    index = next
                }
                continue
            }
            guard character == "{",
                  let close = template[index...].firstIndex(of: "}")
            else {
                literal.append(character)
                index = template.index(after: index)
                continue
            }
            let body = String(template[template.index(after: index)..<close])
            guard let placeholder = parse(body) else {
                // Not a placeholder after all. Keep the brace as text and
                // carry on from the very next character, so a real
                // placeholder further in (code braces wrapped around a
                // `{clipboard}`) is still found instead of swallowed.
                literal.append(character)
                index = template.index(after: index)
                continue
            }
            flush()
            tokens.append(.placeholder(placeholder))
            index = template.index(after: close)
        }
        flush()
        return tokens
    }

    /// One placeholder body, without its braces. Returns nil when the name
    /// is unknown or the body does not parse, which keeps it literal.
    private static func parse(_ body: String) -> Placeholder? {
        let segments = splitOnPipes(body)
        guard let head = segments.first else { return nil }
        var fields = head.trimmingCharacters(in: .whitespaces)
        guard !fields.isEmpty else { return nil }

        // The name runs to the first space; the rest are key="value" pairs.
        var name = fields
        var rest = ""
        if let space = fields.firstIndex(where: \.isWhitespace) {
            name = String(fields[fields.startIndex..<space])
            rest = String(fields[space...])
        }
        fields = rest
        guard let kind = Kind(rawValue: name.lowercased()) else { return nil }
        guard let attributes = parseAttributes(fields) else { return nil }

        var modifiers: [Modifier] = []
        for segment in segments.dropFirst() {
            let word = segment.trimmingCharacters(in: .whitespaces).lowercased()
            guard let modifier = Modifier(rawValue: word) else { return nil }
            modifiers.append(modifier)
        }
        return Placeholder(kind: kind, attributes: attributes, modifiers: modifiers)
    }

    /// Splits on `|` that sit outside a quoted value, so a format string may
    /// contain a pipe.
    private static func splitOnPipes(_ body: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        for character in body {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == "|", !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)
        return segments
    }

    /// `key="value" key2="value2"`. Returns nil on anything else, so a body
    /// the engine cannot read stays literal instead of losing its text.
    private static func parseAttributes(_ source: String) -> [String: String]? {
        var attributes: [String: String] = [:]
        var index = source.startIndex
        while index < source.endIndex {
            guard !source[index].isWhitespace else {
                index = source.index(after: index)
                continue
            }
            guard let equals = source[index...].firstIndex(of: "=") else { return nil }
            let key = String(source[index..<equals]).trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
            let afterEquals = source.index(after: equals)
            guard afterEquals < source.endIndex, source[afterEquals] == "\"" else { return nil }
            let valueStart = source.index(after: afterEquals)
            guard let valueEnd = source[valueStart...].firstIndex(of: "\"") else { return nil }
            attributes[key] = String(source[valueStart..<valueEnd])
            index = source.index(after: valueEnd)
        }
        return attributes
    }
}
