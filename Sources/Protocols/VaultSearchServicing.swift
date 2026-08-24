protocol VaultSearchServicing: Sendable {
    func search(mode: VaultSearchMode, query: String) async throws -> String
}
