import Foundation

/// One call to the `cos` CLI, the Chief of Staff's only writer. Each case is
/// an argument array, never a shell string: a quote or a semicolon in a note
/// is one argument, never syntax. Quick Launch never writes the thread file.
enum CosCommand: Sendable, Equatable {
    case status
    case doIt(id: String)
    case edit(id: String, actions: [ProposalAction])
    case skip(id: String, reason: String?)
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
        case .skip(let id, let reason):
            guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
                return ["skip", id]
            }
            return ["skip", id, "--reason", reason]
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
        case .status, .skip, .append: 20
        case .doIt, .edit: 180
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
