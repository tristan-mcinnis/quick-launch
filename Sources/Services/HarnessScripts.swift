import Foundation

/// A task the model proposed for Todoist. Nothing is added until the user
/// presses Add to Todoist under the answer; the proposal rides on the
/// answer's tool record so a reopened chat still shows it.
struct TodoistProposal: Codable, Sendable, Equatable, Hashable {
    var id: UUID
    var content: String
    /// Todoist's own natural-language due string ("tomorrow 10am"), or empty.
    var due: String
    /// The number the user sees: 1 is p1 (highest), 4 is p4.
    var priority: Int
    var description: String

    init(id: UUID = UUID(), content: String, due: String = "", priority: Int = 4, description: String = "") {
        self.id = id
        self.content = content
        self.due = due
        self.priority = min(max(priority, 1), 4)
        self.description = description
    }

    /// "Call Sam · tomorrow · p2"
    var line: String {
        var parts = [content]
        if !due.isEmpty { parts.append(due) }
        if priority < 4 { parts.append("p\(priority)") }
        return parts.joined(separator: " · ")
    }
}

/// What a Todoist add left: the task's link.
struct TodoistAdded: Sendable, Equatable {
    var url: String
}

/// The skills-repo scripts the chat tools call: the plate, the work
/// calendar, and the one Todoist write. A protocol seam so tests never run
/// Python, read a calendar, or write a task.
protocol HarnessScripting: Sendable {
    /// `plate.py --peek`: the rundown, phone format.
    func plate() async throws -> String
    /// `calendar-ops.py <arguments>`: read-only subcommands only.
    func calendar(_ arguments: [String]) async throws -> String
    /// `todoist-add.py`: the user's own button press, never the model's call.
    func addTodoist(_ proposal: TodoistProposal) async throws -> TodoistAdded
}

enum HarnessScriptError: LocalizedError, Equatable {
    case notInstalled(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let what): "\(what) is not installed"
        case .failed(let message): message
        }
    }
}

/// Runs the scripts with Python through `ProcessRunner`: a direct argv
/// launch, no shell, every user word a single argument.
struct HarnessScripts: HarnessScripting {
    static let skillsRoot = FileManager.default.homeDirectoryForCurrentUser.appending(path: "skills", directoryHint: .isDirectory)
    static let plateScript = "plate/scripts/plate.py"
    static let todoistScript = "plate/scripts/todoist-add.py"
    static let calendarScript = "ic-calendar-ops/scripts/calendar-ops.py"
    /// The calendar subcommands that only read.
    static let calendarReads: Set<String> = ["agenda", "day", "free", "search"]

    /// Plate fans out to Todoist, GitHub, Slack and Outlook; about 13 s here.
    static let plateTimeout: TimeInterval = 25
    static let calendarTimeout: TimeInterval = 15
    static let todoistTimeout: TimeInterval = 20

    private let run: ProcessRunning
    private let python: @Sendable () -> URL?
    private let root: URL

    init(
        run: @escaping ProcessRunning = ProcessRunner.live,
        python: @escaping @Sendable () -> URL? = { ExecutableResolver.resolve("python3") },
        root: URL = HarnessScripts.skillsRoot
    ) {
        self.run = run
        self.python = python
        self.root = root
    }

    func plate() async throws -> String {
        try await script(Self.plateScript, ["--peek"], timeout: Self.plateTimeout)
    }

    func calendar(_ arguments: [String]) async throws -> String {
        guard let verb = arguments.first, Self.calendarReads.contains(verb) else {
            throw HarnessScriptError.failed("Only calendar reads are allowed here.")
        }
        return try await script(Self.calendarScript, arguments, timeout: Self.calendarTimeout)
    }

    func addTodoist(_ proposal: TodoistProposal) async throws -> TodoistAdded {
        var arguments = ["--content", proposal.content, "--priority", String(proposal.priority)]
        if !proposal.due.isEmpty { arguments += ["--due", proposal.due] }
        if !proposal.description.isEmpty { arguments += ["--description", proposal.description] }
        let output = try await script(Self.todoistScript, arguments, timeout: Self.todoistTimeout, checkStatus: false)
        let line = output.split(separator: "\n").last.map(String.init) ?? ""
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw HarnessScriptError.failed("Todoist add gave no answer") }
        if let error = object["error"] as? String { throw HarnessScriptError.failed("Todoist add failed: \(error)") }
        guard let url = object["url"] as? String else { throw HarnessScriptError.failed("Todoist add gave no task link") }
        return TodoistAdded(url: url)
    }

    private func script(
        _ relativePath: String,
        _ arguments: [String],
        timeout: TimeInterval,
        checkStatus: Bool = true
    ) async throws -> String {
        let scriptURL = root.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw HarnessScriptError.notInstalled(relativePath)
        }
        guard let python = python() else { throw HarnessScriptError.notInstalled("python3") }
        let result = try await run(python, [scriptURL.path] + arguments, timeout)
        if checkStatus, result.status != 0 {
            throw HarnessScriptError.failed(Self.lastLine(result.stderrText) ?? "\(relativePath) exited with status \(result.status)")
        }
        return result.stdoutText
    }

    /// The last line of stderr that is not a Python warning.
    private static func lastLine(_ text: String) -> String? {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("Warning") && !$0.hasPrefix("warnings.warn") }
            .last
    }
}

/// Whether a URL the model chose may be fetched: http(s) to a public host.
/// A page or a prompt could ask the model to read `localhost` or a router;
/// those are refused.
enum PublicURLCheck {
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty
        else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || !host.contains(".") {
            return false
        }
        // Any IPv6 literal, and private, loopback and link-local IPv4.
        if host.contains(":") || host.hasPrefix("[") { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (0, _), (169, 254), (192, 168): return false
            case (172, 16...31): return false
            case (100, 64...127): return false
            default: return true
            }
        }
        return true
    }
}
