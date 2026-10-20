/// The tools a chat can let the model call. One list shared by Quick AI,
/// assistants (`SavedPrompt.enabledTools`), and AI Chat, so a chat's tool
/// toggles, an assistant's tool set, and the request builder all speak the
/// same keys.
enum ChatToolKind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    /// `recall_memory`, over the `recall` memory notes.
    case memory
    /// `recall_today` and `recall tasks`, over the canonical task backends.
    case tasks
    /// `read_skill`, the canonical `~/.claude/skills` folder.
    case skills
    /// `search_web`.
    case web

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .memory: "Memory"
        case .tasks: "Tasks"
        case .skills: "Skills"
        case .web: "Web search"
        }
    }
}

extension KeyedDecodingContainer {
    /// A stored tool set, minus any tool that no longer exists (`vault`, retired
    /// 2026-10-20), so an old chat or assistant still loads.
    func decodeToolKinds(forKey key: Key) throws -> Set<ChatToolKind>? {
        try decodeIfPresent([String].self, forKey: key).map {
            Set($0.compactMap(ChatToolKind.init(rawValue:)))
        }
    }
}
