import Foundation

enum WebSearchError: LocalizedError {
    case failed(String)
    case empty
    case timedOut

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            "Web search failed: \(message)"
        case .empty:
            "Web search returned no results."
        case .timedOut:
            "Web search took too long. Please try again."
        }
    }
}
