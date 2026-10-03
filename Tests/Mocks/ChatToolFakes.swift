import Foundation
@testable import QuickLaunch

/// A `recall` stand-in: canned results, an optional delay, and a record of
/// every query. Never starts a process.
actor FakeMemory: MemoryRecalling, MemoryCapturing {
    var searchResult: Result<MemorySearchResult, Error>
    var todayResult: Result<MemoryToday, Error>
    var openTasksResult: Result<RecalledTaskList, Error>
    var captureError: Error?
    var delay: Duration = .zero
    private(set) var queries: [String] = []
    private(set) var captured: [String] = []

    init(
        hits: [MemorySearchResult.Hit] = [],
        today: MemoryToday = FakeMemory.emptyToday
    ) {
        searchResult = .success(MemorySearchResult(query: "", hits: hits))
        todayResult = .success(today)
        openTasksResult = .success(RecalledTaskList(
            schemaVersion: 1,
            readable: true,
            reason: nil,
            count: today.tasks.all.count,
            tasks: today.tasks.all
        ))
    }

    static let emptyToday = MemoryToday(
        schemaVersion: 2,
        captures: .init(readable: true, reason: nil, items: []),
        tasks: .init(readable: true, reason: nil, dueToday: [], overdue: [], inProgress: [])
    )

    func setSearchResult(_ result: Result<MemorySearchResult, Error>) { searchResult = result }
    func setTodayResult(_ result: Result<MemoryToday, Error>) { todayResult = result }
    func setOpenTasksResult(_ result: Result<RecalledTaskList, Error>) { openTasksResult = result }
    func setCaptureError(_ error: Error?) { captureError = error }
    func setDelay(_ value: Duration) { delay = value }

    func search(_ query: String) async throws -> MemorySearchResult {
        queries.append(query)
        if delay != .zero { try await Task.sleep(for: delay) }
        return try searchResult.get()
    }

    func today() async throws -> MemoryToday {
        if delay != .zero { try await Task.sleep(for: delay) }
        return try todayResult.get()
    }

    func openTasks() async throws -> RecalledTaskList {
        if delay != .zero { try await Task.sleep(for: delay) }
        return try openTasksResult.get()
    }

    func capture(_ text: String) async throws {
        if let captureError { throw captureError }
        captured.append(text)
    }

    static func hit(_ path: String, line: String = "a matching line", day: String = "2026-09-10", number: Int = 3) -> MemorySearchResult.Hit {
        MemorySearchResult.Hit(
            line: line,
            path: path,
            absolutePath: "/Users/test/memory/" + path,
            lineNumber: number,
            day: day,
            score: 2
        )
    }
}

/// A vault stand-in for the model's `search_vault` tool.
actor FakeVault: VaultSearchServicing {
    var outcome: Result<VaultSearchOutcome, Error>
    private(set) var calls: [(mode: VaultSearchMode, query: String)] = []

    init(outcome: Result<VaultSearchOutcome, Error>) {
        self.outcome = outcome
    }

    func search(mode: VaultSearchMode, query: String) async throws -> String {
        try await searchWithSources(mode: mode, query: query).text
    }

    func searchWithSources(mode: VaultSearchMode, query: String) async throws -> VaultSearchOutcome {
        calls.append((mode, query))
        return try outcome.get()
    }
}

/// Records every file Open Source asked for; opens nothing.
actor FakeFileOpener: LocalFileOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) async throws { opened.append(url) }
}

/// A throwaway `~/.claude/skills` with the named skills in it.
enum TemporarySkills {
    static func make(_ names: [String] = ["costing", "email-ops"]) throws -> (SkillLibrary, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "chat-tool-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
        for name in names {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "# \(name)\nHow Sam does \(name).".write(
                to: folder.appending(path: "SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        return (SkillLibrary(root: root), root)
    }
}
