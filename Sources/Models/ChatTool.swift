/// The tools a chat can let the model call. One list shared by Quick AI,
/// assistants (`SavedPrompt.enabledTools`), and AI Chat, so a chat's tool
/// toggles, an assistant's tool set, and the request builder all speak the
/// same keys.
enum ChatToolKind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    /// `recall_memory` and `recall_today`, over `~/memory`.
    case memory
    /// `search_vault`, the SSH lane Vault Search already uses.
    case vault
    /// `read_skill`, the canonical `~/.claude/skills` folder.
    case skills
    /// `search_web`.
    case web

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .memory: "Memory"
        case .vault: "Vault"
        case .skills: "Skills"
        case .web: "Web search"
        }
    }
}
