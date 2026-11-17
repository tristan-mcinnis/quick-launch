import Foundation
import Testing
@testable import QuickLaunch

/// The tools over the user's harness: open_work_item over the Work folder,
/// read_url, show_plate, read_calendar, and propose_todoist_task with the
/// user's Add to Todoist press as the only write.
@Suite("Harness tools")
struct HarnessToolsTests {

    // MARK: - A throwaway Work folder

    /// `Acme/2026/acme-jade-fox` with a guide folder, `Acme/2025/acme-old`,
    /// and two projects that share the words "twin peak".
    private static func makeWork() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "work-\(UUID().uuidString)", directoryHint: .isDirectory)
        let project = root.appending(path: "Acme/2026/acme-jade-fox", directoryHint: .isDirectory)
        let guide = project.appending(path: "06-discussion-guide", directoryHint: .isDirectory)
        let proposal = project.appending(path: "02-proposal", directoryHint: .isDirectory)
        for folder in [guide, proposal, guide.appending(path: "drafts"),
                       root.appending(path: "Acme/2025/acme-old"),
                       root.appending(path: "Beta/2026/beta-twin-peak"),
                       root.appending(path: "Gamma/2026/gamma-twin-peak"),
                       root.appending(path: "00-receipts/2026/receipts-jade")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for name in ["dg-fgd-jade-fox-v3.11-20261112.docx", "dg-fgd-jade-fox-v3.11-marked-20261112.docx",
                     "dg-fgd-jade-fox-v2-20261101.docx", "dg-v3.11-changes-20261112.md",
                     "call-agenda-20261106.docx", "build.sh"] {
            try Data("x".utf8).write(to: guide.appending(path: name))
        }
        try Data("x".utf8).write(to: proposal.appending(path: "proposal-jade-fox-v4-20261020.pptx"))
        return root
    }

    // MARK: - WorkItemResolver

    @Test func aProjectNameOpensItsFolder() throws {
        let root = try Self.makeWork()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = WorkItemResolver(root: root)
        let result = resolver.resolve(project: "jade fox", item: nil, target: .folder)
        guard case .found(let url, _) = result else { Issue.record("got \(result)"); return }
        #expect(resolver.relativePath(url) == "Acme/2026/acme-jade-fox")
    }

    @Test func spokenWordsRunTogetherStillMatch() throws {
        let root = try Self.makeWork()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = WorkItemResolver(root: root)
        let result = resolver.resolve(project: "the jadefox folder", item: nil, target: .folder)
        guard case .found(let url, _) = result else { Issue.record("got \(result)"); return }
        #expect(url.lastPathComponent == "acme-jade-fox")
    }

    @Test func theLatestGuideIsTheNewestCleanOfficeFile() throws {
        let root = try Self.makeWork()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = WorkItemResolver(root: root)
        let result = resolver.resolve(project: "jade fox", item: "latest discussion guide", target: .file)
        guard case .found(let url, let alternatives) = result else { Issue.record("got \(result)"); return }
        #expect(url.lastPathComponent == "dg-fgd-jade-fox-v3.11-20261112.docx")
        #expect(!alternatives.contains { $0.lastPathComponent == "build.sh" }, "a script is never a document")
        #expect(alternatives.count <= 3)
    }

    @Test func startHereNamesTheCurrentFile() throws {
        let root = try Self.makeWork()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "Acme/2026/acme-jade-fox")
        try """
        # Start here

        ## What is current in each folder

        ### `02-proposal/`: Our proposal
        - `nothing-here.md`

        ### `06-discussion-guide/`: The guide
        - `dg-fgd-jade-fox-v2-20261101.docx`
        - Folders inside: `drafts/`
        """.write(to: project.appending(path: "START-HERE.md"), atomically: true, encoding: .utf8)
        let resolver = WorkItemResolver(root: root)
        let result = resolver.resolve(project: "jade fox", item: "guide", target: .file)
        guard case .found(let url, _) = result else { Issue.record("got \(result)"); return }
        #expect(url.lastPathComponent == "dg-fgd-jade-fox-v2-20261101.docx")
    }

    @Test func aStageFolderOpensInFinder() throws {
        let root = try Self.makeWork()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = WorkItemResolver(root: root)
        let result = resolver.resolve(project: "jade fox", item: "proposal", target: .folder)
        guard case .found(let url, _) = result else { Issue.record("got \(result)"); return }
        #expect(url.lastPathComponent == "02-proposal")
    }

    @Test func twoProjectsWithTheSameWordsAskWhichOne() throws {
        let root = try Self.makeWork()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = WorkItemResolver(root: root).resolve(project: "twin peak", item: nil, target: .folder)
        guard case .ambiguous(let candidates) = result else { Issue.record("got \(result)"); return }
        #expect(Set(candidates.map(\.lastPathComponent)) == ["beta-twin-peak", "gamma-twin-peak"])
    }

    @Test func noMatchAndReceiptFoldersOpenNothing() throws {
        let root = try Self.makeWork()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = WorkItemResolver(root: root)
        #expect(resolver.projectFolders().allSatisfy { !$0.path.contains("00-receipts") })
        guard case .notFound = resolver.resolve(project: "zebra", item: nil, target: .folder) else {
            Issue.record("expected not found"); return
        }
    }

    @Test func versionsAndDatesReadFromNames() {
        #expect(WorkItemResolver.versionNumber(in: "dg-v3.11-20261112") > WorkItemResolver.versionNumber(in: "dg-v3.9-20261112"))
        #expect(WorkItemResolver.versionNumber(in: "dg-v12") == 12)
        #expect(WorkItemResolver.dateStamp(in: "deck-v2-20261020") == 20261020)
        #expect(WorkItemResolver.words("The Jade-Fox FOLDER") == ["jade", "fox"])
    }

    // MARK: - The toolbox

    @Test func eachToolNeedsItsSwitch() {
        let harness = FakeHarness()
        let none = ChatToolbox(enabled: [], pages: FakePages(), workFiles: WorkItemResolver(), opener: FakeFileOpener(), harness: harness)
        #expect(none.isEmpty)
        let all = ChatToolbox(
            enabled: [.web, .files, .tasks, .calendar],
            pages: FakePages(), workFiles: WorkItemResolver(), opener: FakeFileOpener(), harness: harness
        )
        #expect(all.toolNames == [
            "read_url", "open_work_item", "show_plate", "propose_todoist_task", "propose_task_change",
            "read_calendar", "propose_event_move",
        ])
        let noOpener = ChatToolbox(enabled: [.files], workFiles: WorkItemResolver())
        #expect(noOpener.isEmpty, "a resolver with nothing to open with is not offered")
        #expect(all.definitions.count == 7)
    }

    @Test func openWorkItemOpensTheFileAndListsItAsASource() async throws {
        let root = try Self.makeWork()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = FakeFileOpener()
        let toolbox = ChatToolbox(enabled: [.files], workFiles: WorkItemResolver(root: root), opener: opener)
        let outcome = try #require(await toolbox.run(
            "open_work_item",
            arguments: #"{"project":"jade fox","item":"discussion guide","target":"file"}"#
        ))
        #expect(outcome.status == .succeeded)
        #expect(await opener.opened.map(\.lastPathComponent) == ["dg-fgd-jade-fox-v3.11-20261112.docx"])
        #expect(outcome.record.kind == .open)
        #expect(outcome.record.sources.map(\.title) == ["dg-fgd-jade-fox-v3.11-20261112.docx"], "only the opened file")
        #expect(outcome.content.contains("Other documents there"), "the rest stay in the model's text")
        #expect(outcome.content.contains("Acme/2026/acme-jade-fox/06-discussion-guide"))
    }

    @Test func anAmbiguousNameOpensNothing() async throws {
        let root = try Self.makeWork()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = FakeFileOpener()
        let toolbox = ChatToolbox(enabled: [.files], workFiles: WorkItemResolver(root: root), opener: opener)
        let outcome = try #require(await toolbox.run("open_work_item", arguments: #"{"project":"twin peak","target":"folder"}"#))
        #expect(outcome.status == .refused)
        #expect(await opener.opened.isEmpty)
        #expect(outcome.content.contains("Beta/2026/beta-twin-peak"))
    }

    @Test func readURLRefusesPrivateHostsWithoutFetching() async throws {
        let pages = FakePages()
        let toolbox = ChatToolbox(enabled: [.web], pages: pages)
        for address in ["http://localhost:8080/admin", "http://192.168.1.1", "file:///etc/hosts", "http://10.0.0.2/x", "http://[::1]/"] {
            let outcome = try #require(await toolbox.run("read_url", arguments: "{\"url\":\"\(address)\"}"))
            #expect(outcome.status == .refused, "\(address)")
        }
        #expect(await pages.read.isEmpty)
        let outcome = try #require(await toolbox.run("read_url", arguments: #"{"url":"https://example.com/post"}"#))
        #expect(outcome.status == .succeeded)
        #expect(outcome.content.contains("Example text"))
        #expect(outcome.record.summary == "Read example.com")
    }

    @Test func proposingATaskWritesNothing() async throws {
        let harness = FakeHarness()
        let toolbox = ChatToolbox(enabled: [.tasks], harness: harness)
        let outcome = try #require(await toolbox.run(
            "propose_todoist_task",
            arguments: #"{"content":"Call Sam about the costing","due":"tomorrow 10am","priority":2}"#
        ))
        #expect(outcome.status == .succeeded)
        #expect(await harness.added.isEmpty, "the model cannot add a task")
        let proposal = try #require(outcome.record.proposal)
        #expect(proposal.line == "Call Sam about the costing · tomorrow 10am · p2")
        #expect(outcome.record.kind == .todoistProposal)
        #expect(!outcome.record.drawsAboveAnswer)
        #expect(outcome.content.contains("not added"))
    }

    @Test func showPlateAndCalendarReadThroughTheScripts() async throws {
        let harness = FakeHarness()
        let toolbox = ChatToolbox(enabled: [.tasks, .calendar], harness: harness)
        let plate = try #require(await toolbox.run("show_plate", arguments: "{}"))
        #expect(plate.content.contains("Do now"))
        let free = try #require(await toolbox.run("read_calendar", arguments: #"{"mode":"free","days":30,"minutes":45}"#))
        #expect(free.status == .succeeded)
        let badDay = try #require(await toolbox.run("read_calendar", arguments: #"{"mode":"day","date":"Thursday"}"#))
        #expect(badDay.status == .refused)
        #expect(await harness.calendarCalls == [["free", "--days", "14", "--duration", "45"]])
    }

    // MARK: - HarnessScripts

    @Test func calendarWritesAreRefusedBeforeAnythingRuns() async {
        let runs = RunLog()
        let scripts = HarnessScripts(run: runs.runner(stdout: ""), python: { URL(fileURLWithPath: "/usr/bin/true") }, root: Self.skillsStub())
        await #expect(throws: HarnessScriptError.self) { try await scripts.calendar(["hold", "2026-11-18"]) }
        #expect(await runs.calls.isEmpty)
    }

    @Test func addTodoistPassesEachFieldAsOneArgument() async throws {
        let runs = RunLog()
        let root = Self.skillsStub()
        let scripts = HarnessScripts(
            run: runs.runner(stdout: #"{"id": "42", "url": "https://app.todoist.com/app/task/42"}"#),
            python: { URL(fileURLWithPath: "/usr/bin/true") },
            root: root
        )
        let added = try await scripts.addTodoist(TodoistProposal(content: "Call Sam; rm -rf ~", due: "tomorrow", priority: 2))
        #expect(added.url.hasSuffix("/42"))
        let call = try #require(await runs.calls.first)
        #expect(call.dropFirst() == ["--content", "Call Sam; rm -rf ~", "--priority", "2", "--due", "tomorrow"])
    }

    @Test func aTodoistErrorThrows() async {
        let scripts = HarnessScripts(
            run: RunLog().runner(stdout: #"{"error": "Todoist answered 401"}"#),
            python: { URL(fileURLWithPath: "/usr/bin/true") },
            root: Self.skillsStub()
        )
        await #expect(throws: HarnessScriptError.self) { try await scripts.addTodoist(TodoistProposal(content: "x")) }
    }

    @Test func publicURLCheck() throws {
        #expect(PublicURLCheck.isAllowed(try #require(URL(string: "https://www.example.com/a?b=c"))))
        #expect(!PublicURLCheck.isAllowed(try #require(URL(string: "http://172.20.0.1"))))
        #expect(!PublicURLCheck.isAllowed(try #require(URL(string: "http://printer.local"))))
        #expect(!PublicURLCheck.isAllowed(try #require(URL(string: "http://intranet/"))))
        #expect(PublicURLCheck.isAllowed(try #require(URL(string: "http://8.8.8.8"))))
    }

    /// A skills folder whose three scripts exist (empty).
    static func skillsStub() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "skills-\(UUID().uuidString)")
        for path in [HarnessScripts.plateScript, HarnessScripts.todoistScript, HarnessScripts.calendarScript, HarnessScripts.changeScript] {
            let url = root.appending(path: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        return root
    }
}

// MARK: - Fakes

actor FakeHarness: HarnessScripting {
    private(set) var added: [TodoistProposal] = []
    private(set) var calendarCalls: [[String]] = []
    var addError: Error?

    func plate() async throws -> String { "Do now\n- Send the guide" }
    func calendar(_ arguments: [String]) async throws -> String {
        calendarCalls.append(arguments)
        return "Thu 10:00-11:00 free"
    }
    func addTodoist(_ proposal: TodoistProposal) async throws -> TodoistAdded {
        if let addError { throw addError }
        added.append(proposal)
        return TodoistAdded(url: "https://app.todoist.com/app/task/1")
    }
    func setAddError(_ error: Error?) { addError = error }

    var tasks: [TaskMatch] = []
    var events: [EventMatch] = []
    private(set) var applied: [ChangeProposal] = []
    func findTasks(_ words: String) async throws -> [TaskMatch] { tasks }
    func findEvents(_ words: String) async throws -> [EventMatch] { events }
    func apply(_ change: ChangeProposal) async throws { applied.append(change) }
    func setTasks(_ tasks: [TaskMatch]) { self.tasks = tasks }
    func setEvents(_ events: [EventMatch]) { self.events = events }
}

actor FakePages: WebPageReading {
    private(set) var read: [URL] = []
    func read(_ url: URL) async throws -> String {
        read.append(url)
        return "Example text"
    }
}

actor RunLog {
    private(set) var calls: [[String]] = []
    func record(_ arguments: [String]) { calls.append(arguments) }

    nonisolated func runner(stdout: String) -> ProcessRunning {
        { _, arguments, _ in
            await self.record(arguments)
            return ProcessResult(stdout: Data(stdout.utf8), stderr: Data(), status: 0)
        }
    }
}
