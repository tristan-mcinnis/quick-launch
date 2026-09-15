/// Search sources supported by the existing search service. Automatic keeps
/// its mixed-source default; explicit choices restrict every request.
enum WebSearchProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case google
    case bing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .google: "Google"
        case .bing: "Bing"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Combine available search sources."
        case .google: "Search with Google."
        case .bing: "Search with Bing."
        }
    }
}
