import Foundation

/// Where a web search is answered. The user picks a `WebSearchProvider`; the
/// router reads this to decide which service runs the query.
enum WebSearchBackend: String, Sendable {
    /// Tavily when a key is stored, then the self-hosted SearXNG, then Brave
    /// when a key is stored.
    case chain
    /// The self-hosted SearXNG on vault-vps, restricted to one engine or
    /// category.
    case searxng
    /// The Tavily search API, called directly with a Keychain key.
    case tavily
    /// The Brave Search API, called directly with a Keychain key.
    case brave
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
    /// Tavily first when a key exists, then SearXNG, then Brave.
    case automatic
    case google
    case bing
    case duckduckgo
    case news
    case tavily
    case brave

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
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Tavily when a key is set, then the self-hosted SearXNG, then Brave."
        case .google: "Google via the self-hosted SearXNG."
        case .bing: "Bing via the self-hosted SearXNG."
        case .duckduckgo: "DuckDuckGo via the self-hosted SearXNG."
        case .news: "Recent news via the self-hosted SearXNG."
        case .tavily: "Tavily API. Needs a Tavily key."
        case .brave: "Brave Search API. Needs a Brave key."
        }
    }

    var backend: WebSearchBackend {
        switch self {
        case .automatic: .chain
        case .google, .bing, .duckduckgo, .news: .searxng
        case .tavily: .tavily
        case .brave: .brave
        }
    }

    /// The self-hosted SearXNG request for this provider. `automatic` uses
    /// the general category as its chain step; `tavily` and `brave` never run
    /// through SearXNG and return `nil`.
    var searxngSelection: SearXNGSelection? {
        switch self {
        case .automatic: .category("general")
        case .google: .engine("google cse")
        case .bing: .engine("bing")
        case .duckduckgo: .engine("duckduckgo")
        case .news: .category("news")
        case .tavily, .brave: nil
        }
    }

    /// Whether choosing this provider directly needs a stored API key.
    var requiresAPIKey: Bool {
        switch self {
        case .tavily, .brave: true
        case .automatic, .google, .bing, .duckduckgo, .news: false
        }
    }
}
