import Foundation

/// A change to something that already exists, proposed by the model:
/// reschedule or finish a Todoist task, or move a solo work-calendar event.
/// Nothing changes until the user presses Return on it (the footer reads its
/// `actionLabel`); ⌘Z on an empty field then undoes it with `inverse`.
/// The model never names an id: the toolbox looks the item up and proposes
/// only when exactly one matches, so the change lands on the item shown.
struct ChangeProposal: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable {
        case reschedule
        case complete
        /// The undo of `complete`.
        case reopen
        case moveEvent
    }

    var id: UUID
    var kind: Kind
    /// The Todoist task id or the Outlook event id.
    var targetID: String
    /// The task's text or the event's subject.
    var title: String
    /// Where it is now: a Todoist due date (`yyyy-MM-dd` or with a time),
    /// or an event start (`yyyy-MM-dd HH:mm`). Empty for a task with no date.
    var from: String
    /// Where it goes: Todoist due words, a due date, or an event start.
    var to: String

    init(id: UUID = UUID(), kind: Kind, targetID: String, title: String, from: String = "", to: String = "") {
        self.id = id
        self.kind = kind
        self.targetID = targetID
        self.title = title
        self.from = from
        self.to = to
    }

    /// "Run club · 2026-11-17 07:30 → today 18:00"
    var line: String {
        switch kind {
        case .reschedule, .moveEvent:
            "\(title) · \(Self.shown(from)) → \(Self.shown(to))"
        case .complete: "Done: \(title)"
        case .reopen: "Reopen: \(title)"
        }
    }

    /// What Return does, in the footer and on the row's button.
    var actionLabel: String {
        switch kind {
        case .reschedule: "Reschedule"
        case .complete: "Mark Done"
        case .reopen: "Reopen"
        case .moveEvent: "Move Event"
        }
    }

    /// The line left under the answer once it is done.
    var doneLine: String {
        switch kind {
        case .reschedule: "Rescheduled: \(title) to \(Self.shown(to))"
        case .complete: "Done: \(title)"
        case .reopen: "Reopened: \(title)"
        case .moveEvent: "Moved: \(title) to \(Self.shown(to))"
        }
    }

    /// The change that puts it back.
    var inverse: ChangeProposal {
        switch kind {
        case .reschedule: ChangeProposal(kind: .reschedule, targetID: targetID, title: title, from: to, to: from)
        case .complete: ChangeProposal(kind: .reopen, targetID: targetID, title: title)
        case .reopen: ChangeProposal(kind: .complete, targetID: targetID, title: title)
        case .moveEvent: ChangeProposal(kind: .moveEvent, targetID: targetID, title: title, from: to, to: from)
        }
    }

    private static func shown(_ value: String) -> String {
        if value.isEmpty { return "no date" }
        return value.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: ":00 ", with: " ")
    }
}

/// One open Todoist task `todoist-change.py find` returned.
struct TaskMatch: Sendable, Equatable {
    var id: String
    var content: String
    /// `yyyy-MM-dd`, or with a time (`yyyy-MM-ddTHH:mm:ss`); empty for none.
    var dueDate: String
    var recurring: Bool
}

/// One work-calendar event `calendar-ops.py search --json` returned.
struct EventMatch: Sendable, Equatable {
    var id: String
    var subject: String
    /// `yyyy-MM-dd HH:mm`, local (CST).
    var start: String
    var attendees: Int
    var isAllDay: Bool
}
