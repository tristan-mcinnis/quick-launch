import Foundation

/// How a thread folds a run of tool lines into one quiet activity line.
/// Pure, so the grouping rules are tested without a view.
///
/// Lines that finished well fold into the group. A line that failed, or
/// that waits for an approval, never folds: it is the reader's to see, so it
/// is returned in `exposed` and drawn outside the collapsed group.
enum ToolActivitySummary {
    enum State: Equatable {
        case done
        case failed
        case awaitingApproval
    }

    struct Line: Equatable {
        var text: String
        var symbol: String
        /// A short noun for the headline: "memory", "vault".
        var name: String
        var state: State = .done
    }

    struct Summary: Equatable {
        /// Lines that finished well, in the order they ran.
        var folded: [Line]
        /// Failures and pending approvals, in the order they ran.
        var exposed: [Line]
        /// The group's line, or nil when `folded` holds fewer than two lines
        /// (a single line draws as itself, no group around it).
        var headline: String?

        var isGroup: Bool { headline != nil }
    }

    /// Names listed in a headline before "and more".
    static let nameCap = 3
    /// The headline's length limit, in characters.
    static let headlineLimit = 80

    static func summarize(_ lines: [Line]) -> Summary {
        let folded = lines.filter { $0.state == .done }
        let exposed = lines.filter { $0.state != .done }
        return Summary(folded: folded, exposed: exposed, headline: folded.count >= 2 ? headline(for: folded) : nil)
    }

    private static func headline(for lines: [Line]) -> String {
        var names: [String] = []
        for line in lines where !names.contains(line.name) {
            names.append(line.name)
        }
        let shown = Array(names.prefix(nameCap))
        let list: String
        if names.count > nameCap {
            list = shown.joined(separator: ", ") + " and more"
        } else if shown.count > 1 {
            list = shown.dropLast().joined(separator: ", ") + " and " + shown[shown.count - 1]
        } else {
            list = shown.first ?? ""
        }
        let text = "Used " + list
        return text.count > headlineLimit ? String(text.prefix(headlineLimit - 1)) + "…" : text
    }
}

extension ChatToolRecord {
    /// This record as an activity line.
    var activityLine: ToolActivitySummary.Line {
        ToolActivitySummary.Line(
            text: summary,
            symbol: isFailure ? "exclamationmark.triangle" : systemImage,
            name: activityName,
            state: isFailure ? .failed : .done
        )
    }

    private var activityName: String {
        switch kind {
        case .web: "web"
        case .memory: "memory"
        case .today: "today"
        case .vault: "vault"
        case .skill: "skills"
        case .context: "context"
        case .capture: "capture"
        }
    }
}
