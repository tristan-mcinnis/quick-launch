import Foundation

/// Which way ⇧↩ translates. Chinese (or Japanese/Korean) text goes to
/// English; anything else goes to Chinese.
enum TranslationDirection: Equatable, Sendable {
    case toEnglish
    case toChinese

    /// Saved-prompt alias that performs this direction.
    var alias: String {
        switch self {
        case .toEnglish: "translate"
        case .toChinese: "zh"
        }
    }

    var title: String {
        switch self {
        case .toEnglish: "Translate to English"
        case .toChinese: "Translate to Chinese"
        }
    }

    static func detect(_ text: String) -> TranslationDirection {
        var cjk = 0
        var letters = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F,
                 0x3040...0x30FF, 0xAC00...0xD7AF:
                cjk += 1
                letters += 1
            default:
                if scalar.properties.isAlphabetic { letters += 1 }
            }
        }
        guard letters > 0 else { return .toChinese }
        return Double(cjk) / Double(letters) >= 0.3 ? .toEnglish : .toChinese
    }
}
