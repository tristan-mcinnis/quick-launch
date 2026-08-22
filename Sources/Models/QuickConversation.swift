import Foundation

struct QuickConversation: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var providerID: UUID
    var model: String
    var messages: [QuickMessage]
    /// Set by Rename Chat; nil uses the first question.
    var customTitle: String?
    /// Pinned chats sort first and are never pruned by the history limit.
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerID: UUID,
        model: String,
        messages: [QuickMessage] = [],
        customTitle: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerID = providerID
        self.model = model
        self.messages = messages
        self.customTitle = customTitle
        self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, providerID, model, messages, customTitle, isPinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        providerID = try c.decode(UUID.self, forKey: .providerID)
        model = try c.decode(String.self, forKey: .model)
        messages = try c.decode([QuickMessage].self, forKey: .messages)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return messages.first(where: { $0.role == .user })?.content
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0.prefix(60)) }
            ?? "New quick action"
    }

    var lastAnswer: String? {
        messages.last(where: { $0.role == .assistant })?.content
    }
}
