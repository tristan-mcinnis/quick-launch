import Foundation

/// "<text> in <language>" (or "into") typed in root search, as Raycast's
/// inline translate reads it: the last " in " splits the text, the language
/// word needs three letters and must start a language name. An exact name
/// wins, then the shortest name, then the alphabetical first, so "chinese"
/// is Chinese (Simplified).
struct InlineTranslationQuery: Equatable, Hashable, Sendable {
    let phrase: String
    let target: TranslationTarget
    /// The word is the whole name ("japanese"), not a prefix ("japan").
    let namesLanguageExactly: Bool

    static func parse(_ text: String) -> InlineTranslationQuery? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.wholeMatch(of: /(?i)(.+)\s+(?:in|into)\s+(\S+)/) else { return nil }
        let phrase = String(match.1)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            .trimmingCharacters(in: .whitespaces)
        let word = normalized(String(match.2))
        guard !phrase.isEmpty, word.count >= 3 else { return nil }
        let best = TranslationTarget.all
            .map { (language: $0, name: normalized($0.title)) }
            .filter { $0.name.hasPrefix(word) }
            .min { lhs, rhs in
                if (lhs.name == word) != (rhs.name == word) { return lhs.name == word }
                if lhs.name.count != rhs.name.count { return lhs.name.count < rhs.name.count }
                return lhs.name < rhs.name
            }
        guard let best else { return nil }
        return InlineTranslationQuery(phrase: phrase, target: best.language, namesLanguageExactly: best.name == word)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isASCII && $0.isLetter }
    }
}

/// The launcher's live translation for one query. `text` fills in as the
/// model streams; the row copies it only once `status` is `.ready`.
struct InlineTranslation: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case translating
        case ready
        case failed
    }

    let query: InlineTranslationQuery
    var text = ""
    var status: Status = .translating
}
