protocol VaultSearchServicing: Sendable {
    func search(mode: VaultSearchMode, query: String) async throws -> String
    /// The same one search, with the rows it rendered: how many there were
    /// and the sources a thread can list under an answer. The model's
    /// `search_vault` tool uses this; Vault Search itself uses `search`.
    func searchWithSources(mode: VaultSearchMode, query: String) async throws -> VaultSearchOutcome
}

extension VaultSearchServicing {
    /// A backend that only renders text reports no rows and no sources.
    func searchWithSources(mode: VaultSearchMode, query: String) async throws -> VaultSearchOutcome {
        VaultSearchOutcome(text: try await search(mode: mode, query: query), resultCount: 0, sources: [])
    }
}

/// One vault search: the rendered answer, the number of rows behind it,
/// and the rows that name a source.
struct VaultSearchOutcome: Sendable, Equatable {
    var text: String
    var resultCount: Int
    var sources: [ChatSource]
    /// The search matched several projects and needs one named.
    var needsScope = false
}
