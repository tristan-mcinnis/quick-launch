import Foundation

/// One numbered row of the plate as it was shown. The number is the user's
/// handle ("3", "3 done", "3 open"); it always means this row of this
/// snapshot, never a row of a later, refreshed plate.
struct PlateItem: Codable, Sendable, Equatable, Hashable {
    var number: Int
    var section: String
    var text: String
    var note: String
    /// plate.py's key: `t:<todoist id>`, `c:<date><title>`, `m:` mail,
    /// `f:` a file ready to review, `drafts`, and others.
    var key: String
    var url: String?

    /// What the row is, in words the model and the user both read.
    var kindName: String {
        switch key.split(separator: ":", maxSplits: 1).first.map(String.init) ?? key {
        case "t": "Todoist task"
        case "c": "work calendar event"
        case "m": "work mail"
        case "f": "file ready to review"
        case "drafts": "Outlook drafts"
        case "pr": "pull request"
        case "s": "Slack message"
        default: "plate item"
        }
    }

    /// "3. “Check the backup drive” (Todoist task, Wed 18 · p2)"
    var reference: String {
        let detail = [kindName, note].filter { !$0.isEmpty }.joined(separator: ", ")
        return "plate item \(number), “\(text)” (\(detail))"
    }
}

/// `plate.py --peek --json`, numbered in the order and caps `render` uses,
/// so the model shows exactly the rows the numbers point at.
struct PlateSnapshot: Sendable, Equatable {
    var items: [PlateItem]
    /// The numbered plate for the model.
    var text: String

    /// plate.py's `ORDER` and `CAPS`.
    static let order = ["Do now", "Risks", "Waiting on you", "Next 3 days", "Waiting on others",
                        "New mail", "Ready to review", "If you have time", "Clean up"]
    static let caps = ["Waiting on you": 8, "Next 3 days": 5, "New mail": 4, "Ready to review": 4]
    static let defaultCap = 8

    init(items: [PlateItem], text: String) {
        self.items = items
        self.text = text
    }

    init(json data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = object["sections"] as? [String: [[String: Any]]]
        else { throw HarnessScriptError.failed("The plate gave no answer") }
        let more = object["more"] as? [String: Int] ?? [:]
        let down = object["down"] as? [String] ?? []
        var items: [PlateItem] = []
        var lines: [String] = []
        let names = Self.order + sections.keys.filter { !Self.order.contains($0) }.sorted()
        for name in names {
            guard let rows = sections[name], !rows.isEmpty else { continue }
            let cap = Self.caps[name] ?? Self.defaultCap
            lines.append("\n\(name)")
            for row in rows.prefix(cap) {
                let item = PlateItem(
                    number: items.count + 1,
                    section: name,
                    text: (row["text"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                    note: row["note"] as? String ?? "",
                    key: row["key"] as? String ?? "",
                    url: (row["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                )
                items.append(item)
                let tail = [item.note, row["new"] as? Bool == true ? "new" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
                lines.append("\(item.number). \(item.text)" + (tail.isEmpty ? "" : " · \(tail)"))
            }
            let extra = rows.count - cap + (more[name] ?? 0)
            if extra > 0 { lines.append("+\(extra) more") }
        }
        if !down.isEmpty { lines.append("\nDown: " + down.joined(separator: ". ")) }
        self.items = items
        self.text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
