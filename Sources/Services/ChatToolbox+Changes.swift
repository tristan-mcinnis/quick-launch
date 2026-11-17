import Foundation

/// `propose_task_change` and `propose_event_move`: the model names an item in
/// words, the toolbox finds it, and only exactly one match becomes a
/// proposal. Nothing is written here; the user's Return makes the change.
extension ChatToolbox {
    /// Today in the calendar's own time zone, `yyyy-MM-dd`.
    static func calendarToday(_ now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func proposeTaskChange(_ harness: any HarnessScripting, arguments: String) async -> ChatToolOutcome {
        let words = (Self.stringArgument("task", in: arguments) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let action = Self.stringArgument("action", in: arguments) ?? ""
        let due = (Self.stringArgument("due", in: arguments) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func refuse(_ content: String, _ summary: String) -> ChatToolOutcome {
            ChatToolOutcome(content: content, record: ChatToolRecord(kind: .changeProposal, summary: summary), status: .refused)
        }
        guard !words.isEmpty else { return refuse("propose_task_change needs task: words from the task's title.", "Task change: no task named") }
        guard action == "reschedule" || action == "complete" else {
            return refuse("propose_task_change action is reschedule or complete.", "Task change: no action")
        }
        if action == "reschedule", due.isEmpty {
            return refuse("propose_task_change reschedule needs due, such as \"friday\".", "Task change: no new date")
        }
        let matches: [TaskMatch]
        do {
            matches = try await harness.findTasks(words)
        } catch is CancellationError {
            return Self.outOfTime(Name.proposeTaskChange)
        } catch {
            return ChatToolOutcome(
                content: "Finding the task failed: \(error.localizedDescription). Say so; change nothing.",
                record: ChatToolRecord(kind: .changeProposal, summary: "Task search failed", failed: true),
                status: .failed
            )
        }
        let open = matches.filter { !$0.recurring }
        guard open.count == 1, let task = open.first else {
            if open.isEmpty, let repeating = matches.first {
                return refuse("\"\(repeating.content)\" repeats. A repeating task is changed in Todoist itself, not here; tell the user.", "Task change: \(repeating.content) repeats")
            }
            if open.isEmpty {
                return refuse("No open Todoist task has all of these words: \(words). Ask the user for words from its title.", "Task change: no task matches")
            }
            let list = open.map { "- \($0.content)" + ($0.dueDate.isEmpty ? "" : " (due \($0.dueDate))") }.joined(separator: "\n")
            return ChatToolOutcome(
                content: "Several open tasks match; nothing is proposed. Ask the user which one, by number:\n\(list)",
                record: ChatToolRecord(kind: .changeProposal, summary: "Task change: \(open.count) tasks match"),
                status: .succeeded
            )
        }
        let change = ChangeProposal(
            kind: action == "complete" ? .complete : .reschedule,
            targetID: task.id,
            title: task.content,
            from: task.dueDate,
            to: action == "complete" ? "" : String(due.prefix(80))
        )
        return ChatToolOutcome(
            content: "Proposed, not changed: \(change.line). The user confirms with Return. Say in one line what will change; do not say it changed.",
            record: ChatToolRecord(kind: .changeProposal, summary: "\(change.actionLabel): \(change.line)", change: change),
            status: .succeeded
        )
    }

    func proposeEventMove(_ harness: any HarnessScripting, arguments: String, today: String = ChatToolbox.calendarToday()) async -> ChatToolOutcome {
        let words = (Self.stringArgument("event", in: arguments) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let onDate = Self.stringArgument("on_date", in: arguments) ?? ""
        let newStart = (Self.stringArgument("new_start", in: arguments) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func refuse(_ content: String, _ summary: String) -> ChatToolOutcome {
            ChatToolOutcome(content: content, record: ChatToolRecord(kind: .changeProposal, summary: summary), status: .refused)
        }
        guard !words.isEmpty else { return refuse("propose_event_move needs event: words from its title.", "Event move: no event named") }
        guard newStart.wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/) != nil else {
            return refuse("propose_event_move needs new_start as yyyy-MM-dd HH:mm.", "Event move: no new time")
        }
        let events: [EventMatch]
        do {
            events = try await harness.findEvents(words)
        } catch is CancellationError {
            return Self.outOfTime(Name.proposeEventMove)
        } catch {
            return ChatToolOutcome(
                content: "Finding the event failed: \(error.localizedDescription). Say so; change nothing.",
                record: ChatToolRecord(kind: .changeProposal, summary: "Event search failed", failed: true),
                status: .failed
            )
        }
        var candidates = events.filter { !$0.isAllDay && String($0.start.prefix(10)) >= today }
        if onDate.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil {
            candidates = candidates.filter { $0.start.hasPrefix(onDate) }
        } else {
            // A repeating event ("Run club" every few days): the one on the
            // day it is moving within, when there is exactly one.
            let sameDay = candidates.filter { $0.start.hasPrefix(String(newStart.prefix(10))) }
            if sameDay.count == 1 { candidates = sameDay }
        }
        guard candidates.count == 1, let event = candidates[safe: 0] else {
            if candidates.isEmpty {
                return refuse("No upcoming event on the work calendar matches \(words). Tell the user.", "Event move: no event matches")
            }
            let list = candidates.map { "- \($0.subject), \($0.start)" }.joined(separator: "\n")
            return ChatToolOutcome(
                content: "Several events match; nothing is proposed. Ask the user which one, by number:\n\(list)",
                record: ChatToolRecord(kind: .changeProposal, summary: "Event move: \(candidates.count) events match"),
                status: .succeeded
            )
        }
        guard event.attendees == 0 else {
            return refuse(
                "\"\(event.subject)\" has \(event.attendees) attendee(s); moving it would email them, so it is moved in Outlook, not here. Tell the user.",
                "Event move: \(event.subject) has attendees"
            )
        }
        guard event.start != newStart else {
            return refuse("\"\(event.subject)\" already starts at \(newStart).", "Event move: already at \(newStart)")
        }
        let change = ChangeProposal(kind: .moveEvent, targetID: event.id, title: event.subject, from: event.start, to: newStart)
        return ChatToolOutcome(
            content: "Proposed, not moved: \(change.line). The user confirms with Return. Say in one line what will change; do not say it moved.",
            record: ChatToolRecord(kind: .changeProposal, summary: "\(change.actionLabel): \(change.line)", change: change),
            status: .succeeded
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
