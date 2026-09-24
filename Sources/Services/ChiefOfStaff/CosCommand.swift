import Foundation
import HouseChatCore

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
    /// Feedback on a card; each writes a learned rule.
    case more(id: String)
    case less(id: String, why: String?)
    /// A consent rung for the card's action types on its project.
    case always(id: String)
    /// Remove a rung.
    case never(rung: String)
    case rungs
    /// Run the recorded undo steps of a done or auto card.
    case undo(id: String)
    /// What it did one day.
    case activity(day: String?)
    case artifacts
    case charter
    /// A learning (`all`, `project:<slug>`, `sender:<name>`, `kind:<kind>`).
    case rule(text: String, scope: String)
    /// One line into a charter section (`voice` and the like).
    case charterLine(text: String, section: String)
    case learnings
    /// Remove one learning by its key.
    case forget(key: String)
    /// Record a chat turn this app made. The text goes on stdin (`-`), so a
    /// long answer never meets an argument limit.
    case append(role: Role, text: String, meta: [String: String])
    /// Tell the Chief of Staff something: it answers, or turns a fact or an
    /// instruction into a card (`cos tell`). The text goes on stdin; `card`
    /// is the card the message is about.
    case tell(text: String, card: String?, surface: TellSurface)

    /// Where a `cos tell` came from.
    enum TellSurface: String, Sendable {
        /// The pinned conversation.
        case pinned = "quick-launch"
        /// A branch: every message in it.
        case branch
    }

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
        case .more(let id):
            return ["more", id]
        case .less(let id, let why):
            guard let why = why?.trimmingCharacters(in: .whitespacesAndNewlines), !why.isEmpty else { return ["less", id] }
            return ["less", id, "--why", why]
        case .always(let id):
            return ["always", id]
        case .never(let rung):
            return ["never", rung]
        case .rungs:
            return ["rungs", "--json"]
        case .undo(let id):
            return ["undo", id]
        case .activity(let day):
            return ["activity"] + (day.map { ["--day", $0] } ?? []) + ["--json"]
        case .artifacts:
            return ["artifacts", "--json"]
        case .charter:
            return ["charter", "--json"]
        case .rule(let text, let scope):
            return ["rule", text, "--scope", scope]
        case .charterLine(let text, let section):
            return ["rule", text, "--section", section]
        case .learnings:
            return ["learnings", "--json"]
        case .forget(let key):
            return ["forget", key]
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
        case .tell(_, let card, let surface):
            var arguments = ["tell", "-", "--surface", surface.rawValue]
            if let card, !card.isEmpty { arguments += ["--card", card] }
            return arguments + ["--json"]
        }
    }

    /// What goes on the child's stdin: the appended turn's or the told
    /// text, else nothing.
    var stdin: Data? {
        switch self {
        case .append(_, let text, _), .tell(let text, _, _): Data(text.utf8)
        default: nil
        }
    }

    /// Seconds the call may run before it is stopped. Do and Edit run the
    /// vault writers (an Outlook draft can take a while).
    var timeout: TimeInterval {
        switch self {
        case .status, .no, .later, .reopen, .append, .projects, .tasks, .more, .less, .always, .never,
             .rungs, .activity, .artifacts, .charter, .rule, .charterLine, .learnings, .forget: 20
        // A `prepare` action calls the model: the contract allows 250 s.
        case .doIt, .edit: 260
        case .add, .undo: 180
        // A maker call and maybe a review: 60 s and 90 s in the contract.
        case .tell: 200
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
    /// Today's model calls against their caps, and the breaker.
    var modelCalls: ModelCalls?

    struct ModelCalls: Sendable, Equatable, Decodable {
        struct Cap: Sendable, Equatable, Decodable {
            var maker: Int
            var reviewer: Int
        }

        var maker: Int
        var reviewer: Int
        var cap: Cap
        var failuresInRow: Int
        /// Set while the breaker holds model calls ("YYYY-MM-DDTHH:MM").
        var pausedUntil: String?

        private enum CodingKeys: String, CodingKey {
            case maker, reviewer, cap
            case failuresInRow = "failures_in_row"
            case pausedUntil = "paused_until"
        }

        /// "Model calls today: 12 of 40, reviews 3 of 10".
        var line: String {
            var line = "Model calls today: \(maker) of \(cap.maker), reviews \(reviewer) of \(cap.reviewer)"
            if let pausedUntil, let date = CosDate.parse(pausedUntil) {
                line += ". Paused until \(date.formatted(date: .omitted, time: .shortened)) after \(failuresInRow) failures"
            }
            return line
        }
    }

    private enum CodingKeys: String, CodingKey {
        case paused, total, pending, decided, accepted, today, cap
        case modelCalls = "model_calls"
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
        modelCalls = try? c.decodeIfPresent(ModelCalls.self, forKey: .modelCalls)
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

/// One thing the Chief of Staff did, from `cos activity --json`.
struct CosActivityEvent: Sendable, Equatable, Identifiable, Decodable {
    /// `read`, `proposed`, `reviewed`, `ran`, `closed_on_their_own`,
    /// `failed`, or `answered`.
    var kind: String
    var text: String
    var ts: Date?
    /// "HH:MM" as `cos` prints it.
    var time: String?
    var card: String?
    /// On ran and failed items: `running` (it never finished), `ok`, `failed`.
    var state: String?
    var index = 0

    var id: String { "\(kind)-\(index)" }

    private enum CodingKeys: String, CodingKey { case kind, text, ts, time, card, state }

    init(kind: String, text: String, ts: Date? = nil, time: String? = nil, card: String? = nil) {
        self.kind = kind
        self.text = text
        self.ts = ts
        self.time = time
        self.card = card
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        if let text = try? c.decodeIfPresent(String.self, forKey: .ts) {
            ts = CosDate.parse(text)
        } else if let seconds = try? c.decodeIfPresent(Double.self, forKey: .ts) {
            ts = Date(timeIntervalSince1970: seconds)
        }
        time = try? c.decodeIfPresent(String.self, forKey: .time)
        card = try? c.decodeIfPresent(String.self, forKey: .card)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
    }

    /// An action cut off by a crash: its row says so.
    var didNotFinish: Bool { state == "running" }

    /// The time the row shows: the one `cos` printed, else the stamp's.
    var clock: String {
        time ?? ts.map { $0.formatted(date: .omitted, time: .shortened) } ?? ""
    }
}

/// `cos activity --json`: the day's events, grouped as the view draws them.
struct CosActivity: Sendable, Equatable {
    /// The groups in the order they are drawn, with what each is called.
    static let groups: [(kind: String, title: String)] = [
        ("read", "Read"), ("proposed", "Proposed"), ("reviewed", "Reviewed"), ("ran", "Ran"),
        ("closed_on_their_own", "Closed on their own"), ("failed", "Failed"), ("answered", "Your answers"),
    ]

    var day: String?
    /// How many runs that day.
    var runs: Int?
    var events: [CosActivityEvent]

    func events(_ kind: String) -> [CosActivityEvent] { events.filter { $0.kind == kind } }

    /// `{"day", "runs", "<group>": {"count", "items": [...]}}` (contract v1);
    /// a bare array of events with a `kind` each also reads.
    static func decode(_ stdout: String) throws -> CosActivity {
        let data = Data(stdout.utf8)
        var events: [CosActivityEvent] = []
        var day: String?
        var runs: Int?
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            day = object["day"] as? String
            runs = object["runs"] as? Int
            for (kind, _) in groups {
                guard let group = object[kind] as? [String: Any], let items = group["items"] else { continue }
                let itemData = try JSONSerialization.data(withJSONObject: items)
                for var event in try JSONDecoder().decode([CosActivityEvent].self, from: itemData) {
                    event.kind = kind
                    events.append(event)
                }
            }
        } else {
            events = try JSONDecoder().decode([CosActivityEvent].self, from: data)
        }
        for index in events.indices { events[index].index = index }
        return CosActivity(day: day, runs: runs, events: events)
    }
}

/// One prepared file, from `cos artifacts --json`:
/// `{card, path, rel, name, headline, project, bytes, modified}`.
struct CosArtifact: Sendable, Equatable, Identifiable, Decodable {
    var card: String
    var path: String
    var rel: String?
    var title: String?
    var headline: String?
    var created: Date?
    var project: String?

    var id: String { "\(card)/\(rel ?? path)" }

    private enum CodingKeys: String, CodingKey { case card, path, rel, name, title, headline, modified, created, project }

    init(card: String, path: String, rel: String? = nil, title: String? = nil, headline: String? = nil,
         created: Date? = nil, project: String? = nil) {
        self.card = card
        self.path = path
        self.rel = rel
        self.title = title
        self.headline = headline
        self.created = created
        self.project = project
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        card = (try? c.decodeIfPresent(String.self, forKey: .card)) ?? ""
        path = try c.decode(String.self, forKey: .path)
        rel = try? c.decodeIfPresent(String.self, forKey: .rel)
        title = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? (try? c.decodeIfPresent(String.self, forKey: .title))
        headline = try? c.decodeIfPresent(String.self, forKey: .headline)
        let stamp = (try? c.decodeIfPresent(String.self, forKey: .modified)) ?? (try? c.decodeIfPresent(String.self, forKey: .created))
        created = stamp.flatMap { CosDate.parse($0) }
        project = try? c.decodeIfPresent(String.self, forKey: .project)
    }

    /// What a row calls it: the card's headline (cos's advice), else the
    /// file's name.
    var name: String { headline ?? title ?? (path as NSString).lastPathComponent }

    /// The file on disk: an absolute path as given; else relative to the
    /// data directory (`artifacts/<id>/draft.md`), or to the card's folder.
    func url(in paths: CosPaths) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let relative = rel ?? path
        if relative.hasPrefix("artifacts/") { return paths.data.appending(path: relative) }
        return paths.data.appending(path: "artifacts/\(card)/\(relative)")
    }

    static func decodeList(_ stdout: String) throws -> [CosArtifact] {
        try JSONDecoder().decode([CosArtifact].self, from: Data(stdout.utf8))
    }
}

/// `cos charter --json`: the charter's sections, read only, and the rungs
/// under `## Autonomy`.
struct CosCharter: Sendable, Equatable {
    struct Section: Sendable, Equatable, Identifiable {
        var key: String
        var name: String
        var lines: [String]
        /// The section as written: prose paragraphs and "- " lines.
        var text: String = ""

        var id: String { key }

        /// The prose paragraphs of `text`, each on one line, without the
        /// "- " lines `lines` already carries.
        var prose: [String] {
            text.components(separatedBy: "\n\n").compactMap { paragraph in
                let lines = paragraph.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("- ") && $0 != "-" }
                return lines.isEmpty ? nil : lines.joined(separator: " ")
            }
        }
    }

    /// The sections `cos rule --section` takes.
    /// (Autonomy lines come from Always, not from a typed rule.)
    static let ruleSections = ["watch", "people", "ignore", "style", "quiet", "learned"]

    var path: String?
    var sections: [Section]
    var rungs: [CosRung] = []

    /// `{"path", "sections": [{"key", "title", "text", "items"}], "rungs"}`
    /// (contract v1); an object keyed by section with lines also reads.
    static func decode(_ stdout: String) throws -> CosCharter {
        let data = Data(stdout.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let path = object["path"] as? String
        var rungs: [CosRung] = []
        if let list = object["rungs"] {
            rungs = (try? JSONDecoder().decode([CosRung].self, from: JSONSerialization.data(withJSONObject: list))) ?? []
        }
        if let list = object["sections"] as? [[String: Any]] {
            let sections = list.map { section in
                let name = section["title"] as? String ?? section["name"] as? String ?? section["key"] as? String ?? ""
                let lines = section["items"] as? [String] ?? section["lines"] as? [String]
                    ?? (section["text"] as? String)?.split(separator: "\n").map(String.init) ?? []
                return Section(
                    key: section["key"] as? String ?? name.lowercased(),
                    name: name,
                    lines: lines,
                    text: section["text"] as? String ?? ""
                )
            }
            return CosCharter(path: path, sections: sections, rungs: rungs)
        }
        let keyed = (object["sections"] as? [String: Any]) ?? object.filter { $0.key != "path" && $0.key != "rungs" }
        return CosCharter(path: path, sections: keyed.keys.sorted().compactMap { key in
            guard let lines = keyed[key] as? [String] else { return nil }
            return Section(key: key.lowercased(), name: key.capitalized, lines: lines)
        }, rungs: rungs)
    }
}

/// One consent rung: `{"id": "status_note@<project>"|"task_add@*", "type",
/// "project": str|null, "note"}`.
struct CosRung: Sendable, Equatable, Identifiable, Decodable {
    /// What `cos never` takes.
    var rung: String
    var type: String
    /// A slug, or "*" for every project.
    var project: String
    var note: String?

    var id: String { rung }

    private enum CodingKeys: String, CodingKey { case id, rung, type, project, note }

    init(rung: String, type: String, project: String, note: String? = nil) {
        self.rung = rung
        self.type = type
        self.project = project
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? c.decodeIfPresent(String.self, forKey: .id) {
            rung = id
        } else {
            rung = try c.decode(String.self, forKey: .rung)
        }
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        project = (try? c.decodeIfPresent(String.self, forKey: .project)) ?? "*"
        note = try? c.decodeIfPresent(String.self, forKey: .note)
    }

    static func decodeList(_ stdout: String) throws -> [CosRung] {
        try JSONDecoder().decode([CosRung].self, from: Data(stdout.utf8))
    }
}

/// A time as `cos` prints it: the thread's own format, Python's
/// `isoformat()` with or without fractions and an offset, or a local time
/// with no zone ("YYYY-MM-DDTHH:MM[:SS]", a meeting's start, an
/// artifact's modified time).
enum CosDate {
    static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        if let date = HouseChatCoding.date(from: text) { return date }
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
}

/// One learning, from `cos learnings --json`: a typed row, not charter
/// prose. The latest row per key wins; `cos forget <key>` removes it.
struct CosLearning: Sendable, Equatable, Identifiable, Decodable {
    var key: String
    var text: String
    /// `all`, `project:<slug>`, `sender:<name>`, or `kind:<event_kind>`.
    var scope: String
    /// `user` (More, Less, Add rule) or `inferred`.
    var source: String
    var created: Date?
    var weight: Double?

    var id: String { key }

    private enum CodingKeys: String, CodingKey { case key, text, scope, source, created, weight }

    init(key: String, text: String, scope: String = "all", source: String = "user", created: Date? = nil, weight: Double? = nil) {
        self.key = key
        self.text = text
        self.scope = scope
        self.source = source
        self.created = created
        self.weight = weight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        scope = (try? c.decodeIfPresent(String.self, forKey: .scope)) ?? "all"
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "user"
        created = (try? c.decodeIfPresent(String.self, forKey: .created))?.flatMap { CosDate.parse($0) }
        weight = try? c.decodeIfPresent(Double.self, forKey: .weight)
    }

    /// "Everywhere", "Project: Acme Amplify", "Sender: Charlie", "Cards: meeting".
    func scopeLabel(projectName: (String) -> String? = { _ in nil }) -> String {
        let parts = scope.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "Everywhere" }
        switch parts[0] {
        case "project": return "Project: " + (projectName(parts[1]) ?? parts[1])
        case "sender": return "Sender: " + parts[1]
        case "kind": return "Cards: " + parts[1]
        default: return scope
        }
    }

    static func decodeList(_ stdout: String) throws -> [CosLearning] {
        try JSONDecoder().decode([CosLearning].self, from: Data(stdout.utf8))
    }
}
