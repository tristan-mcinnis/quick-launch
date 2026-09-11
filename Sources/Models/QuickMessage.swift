import Foundation

struct QuickMessage: Codable, Sendable, Equatable, Hashable, Identifiable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        /// Instructions for the model. Never a turn of a saved chat: the
        /// view model puts an assistant's system message in front of the
        /// turns of one request, and each service folds it into its own
        /// system prompt.
        case system
    }

    let id: UUID
    var role: Role
    var content: String
    /// Set on the assistant turn that asked a multiple-choice question. The
    /// card stays in the transcript as the record of what was asked and what
    /// was picked.
    var askUserQuestion: AskUserQuestion?
    /// Set on an answer: the tool lines drawn above it and the sources under
    /// it, in the order the calls ran. Nil on questions, and on answers that
    /// used no tool (and on every answer saved before v1.5.0).
    var toolRecords: [ChatToolRecord]?

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        askUserQuestion: AskUserQuestion? = nil,
        toolRecords: [ChatToolRecord]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.askUserQuestion = askUserQuestion
        self.toolRecords = toolRecords
    }

    /// The tool lines, empty when there are none.
    var tools: [ChatToolRecord] { toolRecords ?? [] }

    /// Every source the answer's tools found, first seen first, without
    /// repeats.
    var sources: [ChatSource] {
        var seen = Set<String>()
        return tools.flatMap(\.sources).filter { seen.insert($0.id).inserted }
    }
}
