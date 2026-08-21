import Foundation

struct QuickMessage: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    var role: Role
    var content: String

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}
