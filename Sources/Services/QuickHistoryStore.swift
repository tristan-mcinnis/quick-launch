import Foundation

enum QuickHistoryStore {
    static let defaultsKey = "QuickConversationHistory"

    static func load(from defaults: UserDefaults = .standard) -> [QuickConversation] {
        guard let data = defaults.data(forKey: defaultsKey),
              let conversations = try? JSONDecoder().decode([QuickConversation].self, from: data)
        else { return [] }
        return ordered(conversations)
    }

    static func save(
        _ conversations: [QuickConversation],
        limit: Int,
        to defaults: UserDefaults = .standard
    ) {
        let bounded = bounded(conversations, limit: limit)
        if let data = try? JSONEncoder().encode(bounded) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    static func upserting(
        _ conversation: QuickConversation,
        into conversations: [QuickConversation],
        limit: Int
    ) -> [QuickConversation] {
        var result = conversations.filter { $0.id != conversation.id }
        result.append(conversation)
        return bounded(result, limit: limit)
    }

    /// Pinned chats first, then newest first.
    static func ordered(_ conversations: [QuickConversation]) -> [QuickConversation] {
        conversations.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Keeps every pinned chat and the newest `limit` unpinned ones.
    static func bounded(_ conversations: [QuickConversation], limit: Int) -> [QuickConversation] {
        let cap = max(1, limit)
        var kept: [QuickConversation] = []
        var unpinned = 0
        for conversation in ordered(conversations) {
            if conversation.isPinned {
                kept.append(conversation)
            } else if unpinned < cap {
                kept.append(conversation)
                unpinned += 1
            }
        }
        return kept
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
