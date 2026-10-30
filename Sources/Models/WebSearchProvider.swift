import Foundation

/// Where a web search is answered. The user picks a `WebSearchProvider`; the
/// router reads this to decide which service runs the query.
enum WebSearchBackend: String, Sendable {
    /// DeepSeek first, then Bocha for a Chinese query, then Tavily and Brave,
    /// each only when its key is stored.
    case chain
    /// DeepSeek's search API, called with the DeepSeek provider key.
    case deepseek
    /// The Tavily search API, called directly with a Keychain key.
    case tavily
    /// The Brave Search API, called directly with a Keychain key.
    case brave
    /// The Bocha Chinese-web search API, called directly with a Keychain key.
    case bocha
    /// The Exa semantic search API, called directly with a Keychain key.
    case exa
}

/// Search sources offered by the shared web-search setting. Every AI surface
/// (Quick AI, AI Chat, the Translator) reads the same choice.
enum WebSearchProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    /// DeepSeek when its key exists, then Bocha for a Chinese query, then
    /// Tavily, then Brave.
    case automatic
    case deepseek
    case tavily
    case brave
    case bocha
    case exa

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .deepseek: "DeepSeek"
        case .tavily: "Tavily"
        case .brave: "Brave"
        case .bocha: "Bocha"
        case .exa: "Exa"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "DeepSeek, then Bocha for Chinese, then Tavily and Brave."
        case .deepseek: "DeepSeek search API. Uses the DeepSeek API key."
        case .tavily: "Tavily API. Needs a Tavily key."
        case .brave: "Brave Search API. Needs a Brave key."
        case .bocha: "Bocha Chinese-web API. Needs a Bocha key."
        case .exa: "Exa semantic search API. Needs an Exa key."
        }
    }

    var backend: WebSearchBackend {
        switch self {
        case .automatic: .chain
        case .deepseek: .deepseek
        case .tavily: .tavily
        case .brave: .brave
        case .bocha: .bocha
        case .exa: .exa
        }
    }

    /// Whether choosing this provider directly needs a stored API key.
    var requiresAPIKey: Bool {
        switch self {
        case .deepseek, .tavily, .brave, .bocha, .exa: true
        case .automatic: false
        }
    }
}

/// Query-shape helpers used by the Automatic chain.
enum WebSearchQuery {
    /// True when the text contains CJK ideographs, which is the signal to
    /// prefer the Chinese-web lane. Kana and Hangul alone do not count, so a
    /// Japanese or Korean query keeps the English order.
    static func containsCJK(_ query: String) -> Bool {
        query.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
                true
            default:
                false
            }
        }
    }
}
