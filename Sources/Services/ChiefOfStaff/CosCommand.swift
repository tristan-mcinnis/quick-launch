import Foundation

/// One call to the `cos` CLI, the Chief of Staff's only writer. Each case is
/// an argument array, never a shell string: a quote or a semicolon in a note
/// is one argument, never syntax. Quick Launch never writes the thread file.
enum CosCommand: Sendable, Equatable {
    case status
    case doIt(id: String)
    case edit(id: String, actions: [ProposalAction])
    /// No: nothing runs; recorded as a no (`cos no`, `skip` is its alias).
    case no(id: String, reason: String?)
    /// Later: hidden until `until`, then back (`tonight`, `tomorrow`,
    /// `nextweek`, or `YYYY-MM-DD[THH:MM]`).
    case later(id: String, until: String)
    /// Bring back a Later, No, handled or expired card now.
    case reopen(id: String)
    /// The active projects strip.
    case projects
    /// The canonical task tree's open lanes for one project.
    case tasks(project: String)
    /// A new canonical task (`task-tree.py add` behind `cos add`).
    case add(title: String, project: String, due: String?)
    /// Record a chat turn this app made. The text goes on stdin (`-`), so a
    /// long answer never meets an argument limit.
    case append(role: Role, text: String, meta: [String: String])

    enum Role: String, Sendable {
        case user
        case assistant
    }

    /// The arguments after the executable.
    func arguments() throws -> [String] {
        switch self {
        case .status:
            return ["status", "--json"]
        case .doIt(let id):
            return ["do", id]
        case .edit(let id, let actions):
            return ["edit", id, "--actions-json", try ProposalAction.actionsJSON(actions)]
        case .no(let id, let reason):
            guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
                return ["no", id]
            }
            return ["no", id, "--reason", reason]
        case .later(let id, let until):
            return ["later", id, "--until", until]
        case .reopen(let id):
            return ["reopen", id]
        case .projects:
            return ["projects", "--json"]
        case .tasks(let project):
            return ["tasks", "--project", project]
        case .add(let title, let project, let due):
            // `--` would be safer, but argparse reads a leading dash in the
            // title as an option; one is refused before it gets here.
            var arguments = ["add", title, "--project", project]
            if let due, !due.isEmpty { arguments += ["--due", due] }
            return arguments
        case .append(let role, _, let meta):
            var arguments = ["append", "--role", role.rawValue, "--surface", ChiefOfStaffThread.surface]
            if !meta.isEmpty {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                arguments += ["--meta", String(decoding: try encoder.encode(meta), as: UTF8.self)]
            }
            return arguments + ["-"]
        }
    }

    /// What goes on the child's stdin: the appended turn's text, else nothing.
    var stdin: Data? {
        if case .append(_, let text, _) = self { return Data(text.utf8) }
        return nil
    }

    /// Seconds the call may run before it is stopped. Do and Edit run the
    /// vault writers (an Outlook draft can take a while).
    var timeout: TimeInterval {
        switch self {
        case .status, .no, .later, .reopen, .append, .projects, .tasks: 20
        case .doIt, .edit, .add: 180
        }
    }
}

/// What one `cos` call returned.
struct CosResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
}

/// One line of an action's outcome, as `cos do` and `cos edit` print it:
/// `OK   status_note: …` or `FAIL task_add: …`.
struct OutcomeLine: Sendable, Equatable, Hashable {
    var ok: Bool
    var text: String

    /// The lines a Do it or Edit call printed. A call that printed none of
    /// them and failed says why in one FAIL line, from its own stderr; a
    /// call that ran no action and succeeded says so.
    static func lines(from result: CosResult) -> [OutcomeLine] {
        let lines = result.stdout.split(separator: "\n").compactMap { raw -> OutcomeLine? in
            if raw.hasPrefix("OK ") {
                return OutcomeLine(ok: true, text: raw.dropFirst(3).trimmingCharacters(in: .whitespaces))
            }
            if raw.hasPrefix("FAIL ") {
                return OutcomeLine(ok: false, text: raw.dropFirst(5).trimmingCharacters(in: .whitespaces))
            }
            return nil
        }
        if !lines.isEmpty { return lines }
        if result.succeeded { return [OutcomeLine(ok: true, text: "No action to run.")] }
        return [OutcomeLine(ok: false, text: lastLine(of: result.stderr) ?? "cos exited with code \(result.exitCode).")]
    }

    static func lastLine(of text: String) -> String? {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }
}

/// What `cos status --json` says. The CLI owns every number; the app shows
/// them and never recounts.
struct CosStatus: Sendable, Equatable, Decodable {
    var paused: Bool
    var total: Int = 0
    var pending: Int = 0
    var decided: Int = 0
    var accepted: Int = 0
    var today: Int = 0
    var cap: Int = 8

    private enum CodingKeys: String, CodingKey {
        case paused, total, pending, decided, accepted, today, cap
    }

    init(paused: Bool) {
        self.paused = paused
    }

    /// Every number but `paused` may be missing: an older CLI prints fewer.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = try c.decode(Bool.self, forKey: .paused)
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        pending = try c.decodeIfPresent(Int.self, forKey: .pending) ?? 0
        decided = try c.decodeIfPresent(Int.self, forKey: .decided) ?? 0
        accepted = try c.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
        today = try c.decodeIfPresent(Int.self, forKey: .today) ?? 0
        cap = try c.decodeIfPresent(Int.self, forKey: .cap) ?? 8
    }

    static func decode(_ stdout: String) throws -> CosStatus {
        try JSONDecoder().decode(CosStatus.self, from: Data(stdout.utf8))
    }
}

/// One row of `cos projects --json`: an active project, its next due date,
/// open and overdue tasks, cards waiting on it, and a risk word.
struct CosProject: Sendable, Equatable, Identifiable, Decodable {
    var slug: String
    var name: String
    var phase: String?
    var openTasks: Int
    var nextDue: String?
    var overdue: Int
    var waitingCards: Int
    var laterCards: Int
    /// `red`, `amber`, or `ok`.
    var risk: String

    var id: String { slug }

    /// The name before " — ": "Acme Amplify", not its long subtitle.
    var shortName: String {
        let short = name.components(separatedBy: " — ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return short.isEmpty ? slug : short
    }

    private enum CodingKeys: String, CodingKey {
        case slug, name, phase, risk, overdue
        case openTasks = "open_tasks"
        case nextDue = "next_due"
        case waitingCards = "waiting_cards"
        case laterCards = "later_cards"
    }

    init(slug: String, name: String, phase: String? = nil, openTasks: Int = 0, nextDue: String? = nil,
         overdue: Int = 0, waitingCards: Int = 0, laterCards: Int = 0, risk: String = "ok") {
        self.slug = slug
        self.name = name
        self.phase = phase
        self.openTasks = openTasks
        self.nextDue = nextDue
        self.overdue = overdue
        self.waitingCards = waitingCards
        self.laterCards = laterCards
        self.risk = risk
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? slug
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        openTasks = try c.decodeIfPresent(Int.self, forKey: .openTasks) ?? 0
        nextDue = try c.decodeIfPresent(String.self, forKey: .nextDue)
        overdue = try c.decodeIfPresent(Int.self, forKey: .overdue) ?? 0
        waitingCards = try c.decodeIfPresent(Int.self, forKey: .waitingCards) ?? 0
        laterCards = try c.decodeIfPresent(Int.self, forKey: .laterCards) ?? 0
        risk = try c.decodeIfPresent(String.self, forKey: .risk) ?? "ok"
    }

    static func decodeList(_ stdout: String) throws -> [CosProject] {
        try JSONDecoder().decode([CosProject].self, from: Data(stdout.utf8))
    }
}

/// One open task of the canonical task tree (`cos tasks --project P`).
struct CosTask: Sendable, Equatable, Identifiable, Decodable {
    var id: String
    var lane: String
    var title: String
    var due: String?

    static func decodeList(_ stdout: String) throws -> [CosTask] {
        try JSONDecoder().decode([CosTask].self, from: Data(stdout.utf8))
    }
}
