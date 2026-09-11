import Foundation

/// `ProcessRunner.run` as a value: executable, argv, and a timeout in
/// seconds. A service that runs a CLI takes one of these, so a test hands it
/// a fake and never starts the real program.
typealias ProcessRunning = @Sendable (URL, [String], TimeInterval) async throws -> ProcessResult

extension ProcessRunner {
    /// The real runner: a direct argv launch, no shell.
    static let live: ProcessRunning = { executable, arguments, timeout in
        try await run(executable: executable, arguments: arguments, timeout: timeout)
    }
}

/// `recall search <query> --json`, one line of JSON. The shape is spelled
/// in memory-recall's `RecallJSON` (schema version 1).
struct MemorySearchResult: Sendable, Equatable, Decodable {
    struct Hit: Sendable, Equatable, Decodable {
        /// The matched line, as the ranker capped it.
        var line: String
        /// Path inside the memory store, what the text output prints.
        var path: String
        /// The file on this Mac, what a source opens.
        var absolutePath: String
        var lineNumber: Int
        /// `yyyy-MM-dd` of the file's last change.
        var day: String
        var score: Int

        enum CodingKeys: String, CodingKey {
            case line, path, day, score
            case absolutePath = "absolute_path"
            case lineNumber = "line_number"
        }
    }

    var query: String
    var hits: [Hit]
}

/// `recall today --json`: two sections, each saying whether it could be read.
struct MemoryToday: Sendable, Equatable, Decodable {
    struct Section<Item: Sendable & Equatable & Decodable>: Sendable, Equatable, Decodable {
        var readable: Bool
        var reason: String?
        var items: [Item]
    }

    struct Capture: Sendable, Equatable, Decodable {
        var time: String
        var text: String
        var kind: String
    }

    struct Task: Sendable, Equatable, Decodable {
        var title: String
        var project: String
        var lane: String
    }

    var captures: Section<Capture>
    var tasks: Section<Task>
}

enum RecallError: LocalizedError, Equatable {
    case notInstalled
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: "recall is not installed"
        case .timedOut: "recall did not answer in time"
        case .failed(let message): message
        }
    }
}

/// The `recall` CLI over `~/memory`. Every call is a direct argv launch
/// through `ProcessRunner` with a timeout; the query or the captured text is
/// always one argument, never shell syntax.
actor RecallCLI: MemoryRecalling, MemoryCapturing {
    /// Searches and `today` run in about 0.3 s on the live store.
    static let readTimeout: TimeInterval = 5
    /// `remember` hands off to the memory repo's Python capture CLI, which
    /// starts slower than a scan.
    static let captureTimeout: TimeInterval = 10

    private let executable: @Sendable () -> URL?
    private let run: ProcessRunning

    /// `executable` defaults to `recall` found the way every CLI provider is
    /// found (`~/.local/bin` first, then the usual bins and `PATH`).
    init(
        executable: @escaping @Sendable () -> URL? = { ExecutableResolver.resolve("recall") },
        run: @escaping ProcessRunning = ProcessRunner.live
    ) {
        self.executable = executable
        self.run = run
    }

    static func searchArguments(_ query: String) -> [String] { ["search", query, "--json"] }
    static let todayArguments = ["today", "--json"]
    static func rememberArguments(_ text: String) -> [String] { ["remember", text] }

    func search(_ query: String) async throws -> MemorySearchResult {
        let result = try await invoke(Self.searchArguments(query), timeout: Self.readTimeout)
        return try Self.parseSearch(result)
    }

    func today() async throws -> MemoryToday {
        let result = try await invoke(Self.todayArguments, timeout: Self.readTimeout)
        return try Self.parseToday(result)
    }

    func remember(_ text: String) async throws {
        let result = try await invoke(Self.rememberArguments(text), timeout: Self.captureTimeout)
        guard result.status == 0 else {
            throw RecallError.failed(
                result.trimmedStderr
                    ?? Self.lastLine(of: result.stdoutText)
                    ?? "recall exited with status \(result.status)"
            )
        }
    }

    private func invoke(_ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        guard let url = executable() else { throw RecallError.notInstalled }
        do {
            return try await run(url, arguments, timeout)
        } catch ProcessRunnerError.timedOut {
            throw RecallError.timedOut
        } catch let error as ProcessRunnerError {
            throw RecallError.failed(error.localizedDescription)
        }
    }

    /// A search with no hits exits 1 and still prints its JSON, so the
    /// payload decides, not the status. A missing store prints `{"error": …}`.
    nonisolated static func parseSearch(_ result: ProcessResult) throws -> MemorySearchResult {
        if let payload = try? JSONDecoder().decode(MemorySearchResult.self, from: result.stdout) {
            return payload
        }
        throw RecallError.failed(errorMessage(in: result))
    }

    nonisolated static func parseToday(_ result: ProcessResult) throws -> MemoryToday {
        if result.status == 0,
           let payload = try? JSONDecoder().decode(MemoryToday.self, from: result.stdout) {
            return payload
        }
        throw RecallError.failed(errorMessage(in: result))
    }

    private nonisolated static func errorMessage(in result: ProcessResult) -> String {
        struct ErrorPayload: Decodable { var error: String }
        if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: result.stdout) {
            return payload.error
        }
        return result.trimmedStderr ?? "recall exited with status \(result.status)"
    }

    private nonisolated static func lastLine(of text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}

/// Opens a file with `/usr/bin/open`, through `ProcessRunner`, so a source
/// opens in the app that owns its type.
actor OpenCommandFileOpener: LocalFileOpening {
    static let executable = URL(fileURLWithPath: "/usr/bin/open")
    static let timeout: TimeInterval = 5

    private let run: ProcessRunning

    init(run: @escaping ProcessRunning = ProcessRunner.live) {
        self.run = run
    }

    func open(_ url: URL) async throws {
        let result = try await run(Self.executable, [url.path], Self.timeout)
        guard result.status == 0 else {
            throw QuickServiceError.commandFailed(
                result.trimmedStderr ?? "open exited with status \(result.status)"
            )
        }
    }
}
