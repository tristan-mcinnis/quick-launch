import Foundation
import HouseChatCore

/// One numbered action inside a Chief of Staff proposal, as the brain wrote
/// it and as the Edit fields change it. Ported from the retired
/// ChiefOfStaff.app. Every field on the wire is kept as it came, strings,
/// numbers, lists and objects alike, so a field this build does not edit (a
/// task close's `task_id` and `evidence`, a list of rules) goes back to
/// `cos edit` unchanged. Edit changes only the one text field (and a task's
/// due date).
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
    /// Every field besides `type`, as it came.
    var raw: [String: JSONValue]

    init(type: String, raw: [String: JSONValue]) {
        self.type = type
        self.raw = raw
    }

    init(type: String, fields: [String: String] = [:]) {
        self.init(type: type, raw: fields.mapValues(JSONValue.string))
    }

    /// The string fields: `note`, `title`, `due`, `body`, `task_id`,
    /// `what`, `evidence`, `brief`.
    var fields: [String: String] { raw.compactMapValues(\.stringValue) }

    var kind: Kind { Kind(rawValue: type) ?? .other }

    /// The field a card shows and Edit changes for this kind.
    var textKey: String {
        switch kind {
        case .statusNote: "note"
        case .taskAdd: "title"
        case .draftReply: "body"
        case .taskClose: "what"
        case .prepare: "brief"
        case .other: ["note", "title", "body", "what", "brief"].first { raw[$0]?.stringValue != nil } ?? "note"
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

    var text: String { raw[textKey]?.stringValue ?? "" }
    var due: String? { raw["due"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }

    /// The fields Edit writes; every other field is sent back as it came.
    private var editedKeys: Set<String> { kind == .taskAdd ? [textKey, "due"] : [textKey] }

    /// Read from one element of a proposal's `actions` array.
    init?(json: JSONValue) {
        guard let object = json.objectValue, let type = object["type"]?.stringValue else { return nil }
        self.init(type: type, raw: object.filter { $0.key != "type" })
    }

    /// This action with its text and due date replaced (the Edit fields).
    func editing(text: String, due: String) -> ProposalAction {
        var copy = self
        copy.raw[textKey] = .string(text)
        if kind == .taskAdd { copy.raw["due"] = .string(due) }
        return copy
    }

    /// The object `cos edit --actions-json` expects: every field as it
    /// came, and the edited ones trimmed, an emptied one left out.
    var editObject: [String: JSONValue] {
        var object = raw
        for key in editedKeys {
            guard let value = raw[key]?.stringValue else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            object[key] = trimmed.isEmpty ? nil : .string(trimmed)
        }
        object["type"] = .string(type)
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
