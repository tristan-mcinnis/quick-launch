import Foundation

/// Where a web search is answered. The user picks a `WebSearchProvider`; the
/// router reads this to decide which service runs the query.
enum WebSearchBackend: String, Sendable {
    /// Bocha for a Chinese query when its key is stored, then Tavily, the
    /// self-hosted SearXNG, and Brave.
    case chain
    /// The self-hosted SearXNG on the House server, restricted to one engine or
    /// category.
    case searxng
    /// The Tavily search API, called directly with a Keychain key.
    case tavily
    /// The Brave Search API, called directly with a Keychain key.
    case brave
    /// The Bocha Chinese-web search API, called directly with a Keychain key.
    case bocha
    /// The Exa semantic search API, called directly with a Keychain key.
    case exa
}

/// The SearXNG request shape for one provider: an exact engine, or a
/// category. Never both, so a selected engine stays exact.
enum SearXNGSelection: Equatable, Sendable {
    case engine(String)
    case category(String)
}

/// Search sources offered by the shared web-search setting. Every AI surface
/// (Quick AI, AI Chat, the Translator) reads the same choice.
enum WebSearchProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A Chinese query prefers Bocha when that key exists; otherwise Tavily,
    /// then SearXNG, then Brave.
    case automatic
    case google
    case bing
    case duckduckgo
    case news
    case tavily
    case brave
    case bocha
    case exa

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .google: "Google"
        case .bing: "Bing"
        case .duckduckgo: "DuckDuckGo"
        case .news: "News"
        case .tavily: "Tavily"
        case .brave: "Brave"
        case .bocha: "Bocha"
        case .exa: "Exa"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Bocha for Chinese, then Tavily, the self-hosted SearXNG, and Brave."
        case .google: "Google via the self-hosted SearXNG."
        case .bing: "Bing via the self-hosted SearXNG."
        case .duckduckgo: "DuckDuckGo via the self-hosted SearXNG."
        case .news: "Recent news via the self-hosted SearXNG."
        case .tavily: "Tavily API. Needs a Tavily key."
        case .brave: "Brave Search API. Needs a Brave key."
        case .bocha: "Bocha Chinese-web API. Needs a Bocha key."
        case .exa: "Exa semantic search API. Needs an Exa key."
        }
    }

    var backend: WebSearchBackend {
        switch self {
        case .automatic: .chain
        case .google, .bing, .duckduckgo, .news: .searxng
        case .tavily: .tavily
        case .brave: .brave
        case .bocha: .bocha
        case .exa: .exa
        }
    }

    /// The self-hosted SearXNG request for this provider. `automatic` uses
    /// the general category as its chain step; the direct API backends never
    /// run through SearXNG and return `nil`.
    var searxngSelection: SearXNGSelection? {
        switch self {
        case .automatic: .category("general")
        case .google: .engine("google cse")
        case .bing: .engine("bing")
        case .duckduckgo: .engine("duckduckgo")
        case .news: .category("news")
        case .tavily, .brave, .bocha, .exa: nil
        }
    }

    /// Whether choosing this provider directly needs a stored API key.
    var requiresAPIKey: Bool {
        switch self {
        case .tavily, .brave, .bocha, .exa: true
        case .automatic, .google, .bing, .duckduckgo, .news: false
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
