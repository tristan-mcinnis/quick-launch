import Foundation

struct QuickConversation: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var providerID: UUID
    var model: String
    var messages: [QuickMessage]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerID: UUID,
        model: String,
        messages: [QuickMessage] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerID = providerID
        self.model = model
        self.messages = messages
    }

    var title: String {
        messages.first(where: { $0.role == .user })?.content
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0.prefix(60)) }
            ?? "New quick action"
    }
}
