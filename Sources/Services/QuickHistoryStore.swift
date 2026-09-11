import Foundation

/// Chat history: one JSON file in Application Support.
///
/// Earlier builds kept the same array as a JSON blob under a UserDefaults
/// key. The first load that finds no file copies that blob into the file
/// and removes the key.
enum QuickHistoryStore {
    static let defaultsKey = "QuickConversationHistory"
    static let fileName = "chat-history.json"
    static let schemaVersion = 1
    /// Settings › History › "Chats to keep": how many unpinned chats stay.
    /// Pinned chats are never counted and never pruned.
    static let limitOptions = [20, 50, 100, 200]
    /// The limit a new install starts with. A stored limit is kept as it is.
    static let defaultLimit = 100

    static func defaultFileURL() -> URL {
        AppPaths.file(fileName)
    }

    /// One serial queue so every caller's writes to the history file stay ordered.
    private static let writeQueue = DispatchQueue(
        label: "com.tristanmcinnis.quick-launch.chat-history",
        qos: .utility
    )

    private static func store(for url: URL) -> JSONFileStore<[QuickConversation]> {
        JSONFileStore(fileURL: url, schemaVersion: schemaVersion, queue: writeQueue)
    }

    static func load(
        from fileURL: URL = defaultFileURL(),
        migratingFrom defaults: UserDefaults? = .standard
    ) -> [QuickConversation] {
        let store = store(for: fileURL)
        if let conversations = store.load() {
            return ordered(conversations)
        }
        guard !store.exists, let defaults, let migrated = migrate(from: defaults, into: store) else {
            return []
        }
        return ordered(migrated)
    }

    /// Moves the UserDefaults blob into the file. Returns what was moved.
    private static func migrate(
        from defaults: UserDefaults,
        into store: JSONFileStore<[QuickConversation]>
    ) -> [QuickConversation]? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        guard let conversations = try? JSONDecoder().decode([QuickConversation].self, from: data) else {
            AppLog.persistence.error("Chat history in UserDefaults could not be decoded; leaving it in place.")
            return nil
        }
        do {
            try store.saveNow(conversations)
        } catch {
            AppLog.persistence.error("Could not migrate chat history to \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return conversations
        }
        defaults.removeObject(forKey: defaultsKey)
        AppLog.persistence.info("Migrated chat history from UserDefaults to \(fileName, privacy: .public).")
        return conversations
    }

    static func save(
        _ conversations: [QuickConversation],
        limit: Int,
        to fileURL: URL = defaultFileURL()
    ) {
        store(for: fileURL).save(bounded(conversations, limit: limit))
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

    /// The one chat search every chat list uses (the Chats catalog, Recent
    /// Chats, the AI Chat rail): `ordered`, then kept when every typed word
    /// is in the title or in a message, case and accents folded. An empty
    /// query keeps every chat.
    static func matching(
        _ conversations: [QuickConversation],
        query: String,
        title: (QuickConversation) -> String
    ) -> [QuickConversation] {
        let terms = FuzzyMatcher.fold(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let sorted = ordered(conversations)
        guard !terms.isEmpty else { return sorted }
        return sorted.filter { conversation in
            let haystack = FuzzyMatcher.fold(
                ([title(conversation)] + conversation.messages.map(\.content))
                    .joined(separator: "\n")
            )
            return terms.allSatisfy { haystack.contains($0) }
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

    static func clear(
        from fileURL: URL = defaultFileURL(),
        defaults: UserDefaults? = .standard
    ) {
        store(for: fileURL).delete()
        defaults?.removeObject(forKey: defaultsKey)
    }

    /// Tests: block until queued writes are on disk.
    static func waitForPendingWrites() {
        writeQueue.sync {}
    }
}
