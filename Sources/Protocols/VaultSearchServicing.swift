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

/// The normalized state of one vault search, so a caller can tell "the search
/// answered and found nothing" apart from "the search never ran". Quick
/// Launch's SSH lane and RTI's hybrid-then-local retrieval report the same
/// four states; each app defines its own shape rather than sharing a package.
enum VaultSearchStatus: Sendable, Equatable {
    /// The backend answered with rows.
    case available
    /// The backend answered and has nothing for the query.
    case noMatch
    /// The backend answered only in part — the search needs a project named.
    case degraded(reason: String)
    /// The backend could not answer at all; the reason is one diagnostic line.
    case unavailable(reason: String)

    /// Why the answer is partial or missing; nil when it is not.
    var reason: String? {
        switch self {
        case .available, .noMatch: nil
        case .degraded(let reason), .unavailable(let reason): reason
        }
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
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
    /// Which of the four states this answer is in.
    var status: VaultSearchStatus = .available
}
