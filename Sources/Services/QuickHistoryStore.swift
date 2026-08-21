import Foundation

enum QuickHistoryStore {
    static let defaultsKey = "QuickConversationHistory"

    static func load(from defaults: UserDefaults = .standard) -> [QuickConversation] {
        guard let data = defaults.data(forKey: defaultsKey),
              let conversations = try? JSONDecoder().decode([QuickConversation].self, from: data)
        else { return [] }
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func save(
        _ conversations: [QuickConversation],
        limit: Int,
        to defaults: UserDefaults = .standard
    ) {
        let bounded = Array(conversations.sorted { $0.updatedAt > $1.updatedAt }.prefix(max(1, limit)))
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
        return Array(result.sorted { $0.updatedAt > $1.updatedAt }.prefix(max(1, limit)))
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
