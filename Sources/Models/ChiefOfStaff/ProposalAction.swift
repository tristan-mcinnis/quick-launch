import Foundation
import HouseChatCore

/// One numbered action inside a Chief of Staff proposal, as the brain wrote
/// it and as the Edit fields change it. Ported from the retired
/// ChiefOfStaff.app. Every string field on the wire is kept, so a field this
/// build does not edit (a task close's `task_id` and `evidence`) goes back
/// to `cos edit` unchanged.
struct ProposalAction: Sendable, Equatable, Hashable {
    enum Kind: String, Sendable {
        case statusNote = "status_note"
        case taskAdd = "task_add"
        case draftReply = "draft_reply"
        case taskClose = "task_close"
        /// Pi drafts a file into the artifacts; never auto.
        case prepare
        case other
    }

    /// The wire value, kept verbatim so an unknown kind survives an edit.
    var type: String
    /// Every string field besides `type`: `note`, `title`, `due`, `body`,
    /// `task_id`, `what`, `evidence`.
    var fields: [String: String]

    init(type: String, fields: [String: String] = [:]) {
        self.type = type
        self.fields = fields
    }

    var kind: Kind { Kind(rawValue: type) ?? .other }

    /// The field a card shows and Edit changes for this kind.
    var textKey: String {
        switch kind {
        case .statusNote: "note"
        case .taskAdd: "title"
        case .draftReply: "body"
        case .taskClose: "what"
        case .prepare: "brief"
        case .other: ["note", "title", "body", "what", "brief"].first { fields[$0] != nil } ?? "note"
        }
    }

    /// The label a card shows before the text.
    var typeLabel: String {
        switch kind {
        case .statusNote: "Status note"
        case .taskAdd: "Task"
        case .draftReply: "Draft reply"
        case .taskClose: "Close task"
        case .prepare: "Prepare"
        case .other: type
        }
    }

    var text: String { fields[textKey] ?? "" }
    var due: String? { fields["due"].flatMap { $0.isEmpty ? nil : $0 } }

    /// Read from one element of a proposal's `actions` array.
    init?(json: JSONValue) {
        guard let object = json.objectValue, let type = object["type"]?.stringValue else { return nil }
        var fields: [String: String] = [:]
        for (key, value) in object where key != "type" {
            if let string = value.stringValue { fields[key] = string }
        }
        self.init(type: type, fields: fields)
    }

    /// This action with its text and due date replaced (the Edit fields).
    func editing(text: String, due: String) -> ProposalAction {
        var copy = self
        copy.fields[textKey] = text
        if kind == .taskAdd { copy.fields["due"] = due }
        return copy
    }

    /// The object `cos edit --actions-json` expects: every field, trimmed,
    /// with no empty value.
    var editObject: [String: String] {
        var object = ["type": type]
        for (key, value) in fields {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { object[key] = trimmed }
        }
        return object
    }

    /// The `--actions-json` argument for a list of edited actions.
    static func actionsJSON(_ actions: [ProposalAction]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(actions.map(\.editObject)), as: UTF8.self)
    }
}

/// One action while the Edit fields are open: the kind stays fixed, the
/// text and the due date are plain strings a field binds to.
struct ActionDraft: Sendable, Equatable, Identifiable {
    let id: Int
    let original: ProposalAction
    var text: String
    var due: String

    init(id: Int, action: ProposalAction) {
        self.id = id
        original = action
        text = action.text
        due = action.due ?? ""
    }

    var kind: ProposalAction.Kind { original.kind }

    /// The action `cos edit` will run.
    var action: ProposalAction { original.editing(text: text, due: due) }

    static func drafts(for proposal: Proposal) -> [ActionDraft] {
        proposal.actions.enumerated().map { ActionDraft(id: $0.offset, action: $0.element) }
    }
}
