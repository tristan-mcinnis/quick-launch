import Foundation

struct QuickMessage: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    var role: Role
    var content: String
    /// Set on the assistant turn that asked a multiple-choice question. The
    /// card stays in the transcript as the record of what was asked and what
    /// was picked.
    var askUserQuestion: AskUserQuestion?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        askUserQuestion: AskUserQuestion? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.askUserQuestion = askUserQuestion
    }
}
