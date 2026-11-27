import Foundation

/// What a text copy looks like, read from its words at query time:
/// `kind:link`, `kind:email` and `kind:color` narrow the clipboard list by
/// it. Nothing is stored, so old entries are covered too.
enum ClipboardTextKind: String, Sendable, CaseIterable {
    case link
    case email
    case color

    /// The one kind a copy is, or nil. Only a copy that is a single link,
    /// address or colour counts; a sentence holding one does not.
    static func classify(_ text: String) -> ClipboardTextKind? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 2_048,
              !trimmed.contains(where: { $0.isNewline }) else { return nil }
        if ClipboardColor(trimmed) != nil { return .color }
        if isEmail(trimmed) { return .email }
        if isLink(trimmed) { return .link }
        return nil
    }

    static func isLink(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        let lower = text.lowercased()
        if lower.hasPrefix("www."), text.count > 5 { return true }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host() != nil else { return false }
        return true
    }

    static func isEmail(_ text: String) -> Bool {
        let address = text.lowercased().hasPrefix("mailto:") ? String(text.dropFirst(7)) : text
        return address.wholeMatch(of: /[^\s@<>]+@[^\s@<>]+\.[A-Za-z]{2,}/) != nil
    }
}

/// A colour written as `#RGB`, `#RRGGBB`, `#RRGGBBAA` or `rgb()`/`rgba()`,
/// with components from 0 to 1. Drawn as a swatch on the clipboard row.
struct ClipboardColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = Self.hex(trimmed) {
            self = hex
        } else if let rgb = Self.rgb(trimmed) {
            self = rgb
        } else {
            return nil
        }
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    private static func hex(_ text: String) -> ClipboardColor? {
        guard text.hasPrefix("#") else { return nil }
        var digits = String(text.dropFirst())
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        return ClipboardColor(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }

    private static func rgb(_ text: String) -> ClipboardColor? {
        guard let match = text.lowercased().wholeMatch(
            of: /rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*(\d*\.?\d+)\s*)?\)/
        ) else { return nil }
        let parts = [match.1, match.2, match.3].compactMap { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let alpha = match.4.flatMap { Double($0) } ?? 1
        guard (0...1).contains(alpha) else { return nil }
        return ClipboardColor(
            red: Double(parts[0]) / 255,
            green: Double(parts[1]) / 255,
            blue: Double(parts[2]) / 255,
            alpha: alpha
        )
    }
}
