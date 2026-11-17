import Foundation

/// The plate as a worklist (2026-11-17): every row the plate shows has a
/// number, and the number is the handle. "3" asks what can be done with row
/// 3; "3 done", "3 friday", "3 move to 18:00" say it; "3 open" opens its
/// link. The app turns the number into the row's own words before the model
/// sees it, so the model never guesses which row was meant, and the number
/// always means the row as it was shown, never a refreshed plate.
extension QuickViewModel {
    enum WorklistCommand: Equatable {
        /// Sent to the model in place of what was typed.
        case ask(String)
        /// Opened here, with no model call.
        case open(URL, PlateItem)
    }

    /// The longest instruction after a number that still reads as a
    /// command on a row. "3 people came to the group" is a sentence.
    static let worklistCommandMaxWords = 6
    /// Words that may come before the number ("open 8", "move 6 to 18:00").
    static let worklistLeadingVerbs: Set<String> = [
        "open", "done", "finish", "complete", "tick", "move", "push", "reschedule", "mark", "snooze", "postpone",
    ]
    /// What a bare number asks. Tested on deepseek-flash: without "no
    /// search first" it searched memory before answering.
    static let worklistFocusQuestion = "what can I do with it? Answer straight away from the plate, with no search first: two or three next steps as a numbered list, each one I can say back (such as open it, mark it done, move it to a time, or draft the reply)."

    /// The newest plate rows in this chat, and whether the newest answer is
    /// that plate.
    var currentWorklist: (items: [PlateItem], onNewestAnswer: Bool)? {
        guard let messages = currentConversation?.messages else { return nil }
        let newestAnswer = messages.last(where: { $0.role == .assistant })?.id
        for message in messages.reversed() where message.role == .assistant {
            if let items = message.tools.last(where: { $0.kind == .plate && $0.worklist?.isEmpty == false })?.worklist {
                return (items, message.id == newestAnswer)
            }
        }
        return nil
    }

    /// What a typed "3", "3 done" or "3 open" means against the plate on
    /// screen, or nil when it is not such a command.
    func worklistCommand(for typed: String) -> WorklistCommand? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let number: Int
        let rest: String
        if let match = text.wholeMatch(of: /(\d{1,2})[.)]?(?:\s+([\s\S]*))?/), let value = Int(match.output.1) {
            number = value
            rest = (match.output.2.map(String.init) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let match = text.wholeMatch(of: /([A-Za-z]+)\s+(\d{1,2})(?:\s+([\s\S]*))?/),
                  Self.worklistLeadingVerbs.contains(match.output.1.lowercased()),
                  let value = Int(match.output.2) {
            // "open 8" is "8 open"; "move 6 to 18:00" is "6 move to 18:00".
            number = value
            rest = ([String(match.output.1)] + (match.output.3.map { [String($0)] } ?? []))
                .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }
        guard let worklist = currentWorklist,
              let item = worklist.items.first(where: { $0.number == number })
        else { return nil }
        if rest.isEmpty {
            // A bare number picks a plate row only right under the plate;
            // after another answer it answers that answer's own list.
            guard worklist.onNewestAnswer else { return nil }
            return .ask("\(item.reference.prefix(1).uppercased())\(item.reference.dropFirst()): \(Self.worklistFocusQuestion)")
        }
        guard !rest.hasSuffix("?"),
              rest.split(whereSeparator: \.isWhitespace).count <= Self.worklistCommandMaxWords
        else { return nil }
        if ["open", "o", "show"].contains(rest.lowercased()) {
            if let url = item.url.flatMap(URL.init(string:)), PublicURLCheck.isAllowed(url) {
                return .open(url, item)
            }
            return .ask("Open \(item.reference).")
        }
        return .ask("\(item.reference.prefix(1).uppercased())\(item.reference.dropFirst()): \(rest)")
    }

    /// Runs a worklist command in place of a typed submit. True when it
    /// was one and nothing more should be sent as typed.
    func runWorklistCommandIfAny() -> Bool {
        guard !isStreaming, let command = worklistCommand(for: input) else { return false }
        switch command {
        case .open(let url, let item):
            workspace.open(url)
            input = ""
            confirmInComposer("Opened \(item.number). \(item.text)")
            return true
        case .ask(let text):
            input = text
            return false
        }
    }
}
