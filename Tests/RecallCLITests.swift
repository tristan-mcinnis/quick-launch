import Foundation
import Testing
@testable import QuickLaunch

/// `RecallCLI` on a fake process runner: the argv it sends, the timeout it
/// asks for, and how it reads recall's JSON (shapes copied from a real
/// `recall search … --json` and `recall today --json`). The real binary is
/// never started.
@Suite("recall CLI")
struct RecallCLITests {

    /// Every launch the CLI asked for, and a canned result.
    private actor FakeRunner {
        struct Call: Equatable {
            let executable: URL
            let arguments: [String]
            let timeout: TimeInterval
        }
        private(set) var calls: [Call] = []
        let result: Result<ProcessResult, Error>

        init(_ result: Result<ProcessResult, Error>) { self.result = result }

        func run(_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) throws -> ProcessResult {
            calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
            return try result.get()
        }
    }

    private static let recallURL = URL(fileURLWithPath: "/fake/bin/recall")

    private static func cli(_ runner: FakeRunner, installed: Bool = true) -> RecallCLI {
        RecallCLI(
            executable: { installed ? recallURL : nil },
            run: { try await runner.run($0, $1, $2) }
        )
    }

    private static func output(_ json: String, status: Int32 = 0, stderr: String = "") -> ProcessResult {
        ProcessResult(stdout: Data(json.utf8), stderr: Data(stderr.utf8), status: status)
    }

    private static let searchJSON = #"{"count":2,"file_count":3777,"hits":[{"absolute_path":"/Users/test/memory/episodic/ava/conversations/2026-09-06.md","day":"2026-09-11","line":"Note the 2026 reforms lowered the requirement","line_number":70,"path":"episodic/ava/conversations/2026-09-06.md","score":2},{"absolute_path":"/Users/test/memory/state/decisions/dec-01.md","day":"2026-09-03","line":"decision log entry","line_number":17,"path":"state/decisions/dec-01.md","score":4}],"query":"test","rank_ms":121,"scan_ms":193,"schema_version":1}"#

    @Test func searchRunsRecallWithTheQueryAsOneArgumentAndAFiveSecondTimeout() async throws {
        let runner = FakeRunner(.success(Self.output(Self.searchJSON)))
        let result = try await Self.cli(runner).search("pricing deck; rm -rf ~")

        let calls = await runner.calls
        #expect(calls == [.init(
            executable: Self.recallURL,
            arguments: ["search", "pricing deck; rm -rf ~", "--json"],
            timeout: 5
        )])
        #expect(result.hits.count == 2)
        #expect(result.hits[0].absolutePath == "/Users/test/memory/episodic/ava/conversations/2026-09-06.md")
        #expect(result.hits[0].path == "episodic/ava/conversations/2026-09-06.md")
        #expect(result.hits[0].lineNumber == 70)
        #expect(result.hits[1].day == "2026-09-03")
    }

    @Test func noHitsExitsOneAndIsStillAnEmptyResult() async throws {
        let json = #"{"count":0,"file_count":3777,"hits":[],"query":"zzq","rank_ms":89,"scan_ms":248,"schema_version":1}"#
        let runner = FakeRunner(.success(Self.output(json, status: 1)))
        let result = try await Self.cli(runner).search("zzq")
        #expect(result.hits.isEmpty)
    }

    @Test func aMissingStoreIsAnError() async throws {
        let runner = FakeRunner(.success(Self.output(#"{"error":"no memory repo at ~/memory","schema_version":1}"#, status: 1)))
        await #expect(throws: RecallError.failed("no memory repo at ~/memory")) {
            _ = try await Self.cli(runner).search("x")
        }
    }

    @Test func aTimeoutIsReportedAsTimedOut() async throws {
        let runner = FakeRunner(.failure(ProcessRunnerError.timedOut(executable: "recall", seconds: 5)))
        await #expect(throws: RecallError.timedOut) {
            _ = try await Self.cli(runner).search("x")
        }
    }

    @Test func notInstalledNeverRunsAnything() async throws {
        let runner = FakeRunner(.success(Self.output(Self.searchJSON)))
        await #expect(throws: RecallError.notInstalled) {
            _ = try await Self.cli(runner, installed: false).search("x")
        }
        #expect(await runner.calls.isEmpty)
    }

    @Test func todayReadsBothSections() async throws {
        let json = #"{"captures":{"items":[{"kind":"note","text":"Call Sam","time":"09:12"}],"readable":true},"schema_version":1,"tasks":{"items":[{"lane":"in_progress","project":"stack","title":"Audit screenctx after 24h live"}],"readable":true}}"#
        let runner = FakeRunner(.success(Self.output(json)))
        let today = try await Self.cli(runner).today()
        #expect(await runner.calls.map(\.arguments) == [["today", "--json"]])
        #expect(today.captures.items.map(\.text) == ["Call Sam"])
        #expect(today.tasks.items.map(\.project) == ["stack"])
        #expect(today.tasks.readable)
    }

    @Test func todayCarriesAnUnreadableSectionsReason() async throws {
        let json = #"{"captures":{"items":[],"readable":false,"reason":"no read interface"},"schema_version":1,"tasks":{"items":[],"readable":true}}"#
        let today = try await Self.cli(FakeRunner(.success(Self.output(json)))).today()
        #expect(!today.captures.readable)
        #expect(today.captures.reason == "no read interface")
    }

    @Test func rememberSendsTheTextAsOneArgument() async throws {
        let runner = FakeRunner(.success(Self.output("● Captured")))
        try await Self.cli(runner).remember("Ship on Friday.\nThen Monday.")
        #expect(await runner.calls == [.init(
            executable: Self.recallURL,
            arguments: ["remember", "Ship on Friday.\nThen Monday."],
            timeout: 10
        )])
    }

    @Test func aRefusedCaptureSaysWhy() async throws {
        let runner = FakeRunner(.success(Self.output("● usage: recall remember <text>", status: 2)))
        await #expect(throws: RecallError.failed("● usage: recall remember <text>")) {
            try await Self.cli(runner).remember("x")
        }
    }

    @Test func openSourceRunsUsrBinOpenOnThePath() async throws {
        let runner = FakeRunner(.success(Self.output("")))
        let opener = OpenCommandFileOpener(run: { try await runner.run($0, $1, $2) })
        try await opener.open(URL(fileURLWithPath: "/Users/test/vault/kb/00-status.md"))
        #expect(await runner.calls == [.init(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["/Users/test/vault/kb/00-status.md"],
            timeout: 5
        )])
    }
}
