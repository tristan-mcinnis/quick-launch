protocol WebSearchServicing: Sendable {
    func search(_ query: String) async throws -> String
}
