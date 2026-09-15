protocol WebSearchServicing: Sendable {
    func search(_ query: String) async throws -> String
    func search(_ query: String, provider: WebSearchProvider) async throws -> String
}

extension WebSearchServicing {
    /// Existing injected search backends retain their default behavior.
    func search(_ query: String, provider: WebSearchProvider) async throws -> String {
        try await search(query)
    }
}
