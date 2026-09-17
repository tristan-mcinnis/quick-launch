import Foundation

/// Chat history: one JSON file in Application Support.
///
/// Earlier builds kept the same array as a JSON blob under a UserDefaults
/// key. The first load that finds no file copies that blob into the file
/// and removes the key.
/// How a legacy history file loaded.
///
/// `corrupt` is distinct from `missing` on purpose: a damaged legacy file is
/// rollback evidence, and it must never be treated as an empty store (which a
/// later save would overwrite). The archive is the authority; this file is
/// only the UI cache.
enum QuickHistoryLoad: Sendable, Equatable {
    case loaded([QuickConversation])
    case missing
    case corrupt
}

enum QuickHistoryStore {
    static let defaultsKey = "QuickConversationHistory"
    static let fileName = "chat-history.json"
    /// The pre-archive copy kept beside the cache, for rolling the cutover
    /// back. The archive never deletes it.
    static let rollbackFileName = "chat-history.pre-archive.json"
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
        switch loadResult(from: fileURL, migratingFrom: defaults) {
        case .loaded(let conversations): return ordered(conversations)
        case .missing, .corrupt: return []
        }
    }

    /// Loads the legacy cache and says which of the three cases it was. A
    /// corrupt file is reported, never silently read as empty.
    static func loadResult(
        from fileURL: URL = defaultFileURL(),
        migratingFrom defaults: UserDefaults? = .standard
    ) -> QuickHistoryLoad {
        let store = store(for: fileURL)
        if let conversations = store.load() {
            return .loaded(ordered(conversations))
        }
        guard !store.exists else {
            AppLog.persistence.error(
                "Chat history at \(fileName, privacy: .public) is damaged; keeping it as rollback data."
            )
            return .corrupt
        }
        guard let defaults, let migrated = migrate(from: defaults, into: store) else {
            return .missing
        }
        return .loaded(ordered(migrated))
    }

    /// Copies the legacy file aside once, before the archive becomes the
    /// authority. Returns the backup URL when it made one, nil when there was
    /// nothing to back up or the copy already exists. The legacy file itself
    /// is left untouched: it is the rollback path until the cutover is
    /// verified.
    @discardableResult
    static func backupForRollback(from fileURL: URL = defaultFileURL()) throws -> URL? {
        let backup = fileURL.deletingLastPathComponent().appendingPathComponent(rollbackFileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard !FileManager.default.fileExists(atPath: backup.path) else { return backup }
        try FileManager.default.copyItem(at: fileURL, to: backup)
        return backup
    }

    /// Writes the archive's projection back into the legacy file as a cache.
    /// The `limit` bounds only this UI cache; the canonical archive is never
    /// capped, and the full history reads from the archive, not here.
    static func rebuildCache(
        _ conversations: [QuickConversation],
        limit: Int = defaultLimit,
        to fileURL: URL = defaultFileURL()
    ) {
        save(conversations, limit: limit, to: fileURL)
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
        QuickHistoryOrdering.ordered(conversations)
    }

    /// The one chat search every chat list uses (the Chats catalog, Recent
    /// Chats, the AI Chat rail), through `ChatSearch`. An empty query keeps
    /// every chat in `ordered` order (pinned first, then newest). A query
    /// keeps the chats where every term matches the title, an attachment
    /// name, a question, or an answer (case, accents, and width folded; CJK
    /// as a substring), ranked: title hits first, recent chats above old
    /// ones, pinned chats only a little higher. `index` keeps the folded
    /// text between calls; without one the text is folded for this call.
    @MainActor static func matching(
        _ conversations: [QuickConversation],
        query: String,
        title: (QuickConversation) -> String,
        index: ChatSearchIndex? = nil,
        now: Date = Date()
    ) -> [QuickConversation] {
        let parsed = ChatSearchQuery(query)
        guard !parsed.isEmpty else { return ordered(conversations) }
        let index = index ?? ChatSearchIndex(backgroundThreshold: nil)
        index.update(conversations, title: title)
        return ChatSearch.rank(
            conversations,
            query: parsed,
            document: { conversation in
                index.document(id: conversation.id)
                    ?? index.document(for: ChatSearchSource(
                        conversation,
                        title: title(conversation),
                        attachments: ChatSearchSource.attachments(in: conversation)
                    ))
            },
            now: now
        )
        .map(\.conversation)
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
