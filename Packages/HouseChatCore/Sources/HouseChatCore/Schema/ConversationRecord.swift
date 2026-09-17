import Foundation

/// One chat history: a QL chat window, an RTI meeting session, or anything
/// else that keeps turns. The ID is the app's own stable string (a UUID for
/// QL, a session identifier for RTI).
public struct ConversationRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var schemaVersion: Int
    public var surface: ChatSurface?
    public var title: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var sessionLinks: [SessionLink]
    public var turns: [TurnRecord]
    /// The app build that wrote it, for diagnosing a decode.
    public var appVersion: String?
    /// Fields only this app models (QL's titleSource and the rest).
    public var appPayload: AppPayload?
    public var extra: ExtraFields

    public init(
        id: String,
        schemaVersion: Int = HouseChatCoding.schemaVersion,
        surface: ChatSurface? = nil,
        title: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        sessionLinks: [SessionLink] = [],
        turns: [TurnRecord] = [],
        appVersion: String? = nil,
        appPayload: AppPayload? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.surface = surface
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sessionLinks = sessionLinks
        self.turns = turns
        self.appVersion = appVersion
        self.appPayload = appPayload
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "id", "schemaVersion", "surface", "title", "createdAt", "updatedAt",
        "sessionLinks", "turns", "appVersion", "appPayload",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        // The ID is identity: a stored record without one is damaged.
        self.id = try c.decodeNonEmptyString(forKey: AnyCodingKey("id"))
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("schemaVersion")) ?? HouseChatCoding.schemaVersion
        self.surface = try c.decodeIfPresent(ChatSurface.self, forKey: AnyCodingKey("surface"))
        self.title = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("title"))
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("createdAt"))
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("updatedAt"))
        self.sessionLinks = try c.decodeIfPresent([SessionLink].self, forKey: AnyCodingKey("sessionLinks")) ?? []
        self.turns = try c.decodeIfPresent([TurnRecord].self, forKey: AnyCodingKey("turns")) ?? []
        self.appVersion = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("appVersion"))
        self.appPayload = try c.decodeIfPresent(AppPayload.self, forKey: AnyCodingKey("appPayload"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(id, forKey: AnyCodingKey("id"))
        try c.encode(schemaVersion, forKey: AnyCodingKey("schemaVersion"))
        try c.encodeIfPresent(surface, forKey: AnyCodingKey("surface"))
        try c.encodeIfPresent(title, forKey: AnyCodingKey("title"))
        try c.encodeIfPresent(createdAt, forKey: AnyCodingKey("createdAt"))
        try c.encodeIfPresent(updatedAt, forKey: AnyCodingKey("updatedAt"))
        try c.encode(sessionLinks, forKey: AnyCodingKey("sessionLinks"))
        try c.encode(turns, forKey: AnyCodingKey("turns"))
        try c.encodeIfPresent(appVersion, forKey: AnyCodingKey("appVersion"))
        try c.encodeIfPresent(appPayload, forKey: AnyCodingKey("appPayload"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }

    /// Every attachment in the conversation, in turn order.
    public var attachments: [AttachmentRecord] {
        turns.flatMap(\.attachments)
    }

    /// Every distinct content hash in the conversation, for an archive audit.
    public var contentHashes: Set<String> {
        Set(attachments.compactMap(\.contentHash))
    }
}
