import Darwin
import Foundation
import Synchronization
import Testing
@testable import QuickLaunch

// MARK: - Fixtures

/// A manifest folder in a temporary directory. Never the real one at
/// `~/Library/Application Support/House/commands`, and never a live app.
private struct FixtureFolder: ~Copyable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-house-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ name: String, _ contents: String) -> String {
        let file = url.appendingPathComponent(name)
        try? contents.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// Backdates a file, for the rule that a status file is never expired by
    /// age.
    func backdate(_ name: String, days: Int) {
        let file = url.appendingPathComponent(name)
        let old = Date().addingTimeInterval(-Double(days) * 86_400)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
    }

    var directory: HouseCommandDirectory { HouseCommandDirectory(root: url) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Endpoints are always resolved and absolute in a real manifest.
private let rtiManifest = """
{
  "schema": 1,
  "app": "rti",
  "name": "RTI",
  "transport": "socket",
  "endpoint": "/Users/fixture/.config/rti/control.sock",
  "status": "status",
  "commands": [
    {"id": "record.start", "title": "Start Recording", "verb": "start",
     "needs": null, "unavailableWhen": "recording"},
    {"id": "record.stop", "title": "Stop Recording", "verb": "stop",
     "needs": null, "unavailableWhen": "!recording"}
  ]
}
"""

/// `exec`: `status` is an absolute path to a JSON file, not a verb.
private func memoryManifest(statusPath: String) -> String {
    """
    {
      "schema": 1,
      "app": "memory",
      "name": "Memory",
      "transport": "exec",
      "endpoint": "/usr/local/bin/recall",
      "status": "\(statusPath)",
      "commands": [
        {"id": "capture", "title": "Capture a Thought", "verb": "capture", "needs": "text",
         "unavailableWhen": "collecting"},
        {"id": "today", "title": "Today", "verb": "today"}
      ]
    }
    """
}

/// An `exec` app with nothing gated on a status at all.
private let plainMemoryManifest = """
{
  "schema": 1,
  "app": "memory",
  "name": "Memory",
  "transport": "exec",
  "endpoint": "/usr/local/bin/recall",
  "commands": [
    {"id": "capture", "title": "Capture a Thought", "verb": "capture", "needs": "text"}
  ]
}
"""

/// `http`: routes carry their own leading slash, and a choice command names
/// where its options come from.
private let modelsManifest = """
{
  "schema": 1,
  "app": "models",
  "name": "Local Models",
  "transport": "http",
  "endpoint": "http://127.0.0.1:8078",
  "status": "/v1/status",
  "commands": [
    {"id": "model.warm", "title": "Warm Model", "verb": "/v1/warm", "needs": "choice",
     "choicesFrom": "/v1/choices/model", "unavailableWhen": null},
    {"id": "model.unload", "title": "Unload Model", "verb": "/v1/unload",
     "unavailableWhen": "!warm"}
  ]
}
"""

private let statusDocument = #"{"app": "memory", "ok": true, "busy": false, "detail": "Collecting"}"#

/// Records what it was asked to do and answers from a script. Nothing here
/// opens a socket, spawns a process, or makes an HTTP call.
private actor FakeDispatcher: HouseCommandDispatching {
    struct Run: Sendable, Equatable {
        let app: String
        let verb: String
        let argument: String?
    }

    private var statuses: [String: HouseCommandStatus?]
    private var statusFailures: Set<String>
    private(set) var runs: [Run] = []
    private(set) var statusReads: [String] = []
    private(set) var choiceFetches: [String] = []
    private var failure: HouseCommandError?
    private var outcome: HouseCommandOutcome
    private var choices: [HouseCommandChoice]
    private var choicesFail: Bool
    /// Statuses handed out in order, for work that starts and finishes later.
    private var statusScript: [HouseCommandStatus]

    init(
        statuses: [String: HouseCommandStatus?] = [:],
        statusFailures: Set<String> = [],
        failure: HouseCommandError? = nil,
        outcome: HouseCommandOutcome = .completed("ok"),
        choices: [HouseCommandChoice] = [],
        choicesFail: Bool = false,
        statusScript: [HouseCommandStatus] = []
    ) {
        self.statuses = statuses
        self.statusFailures = statusFailures
        self.failure = failure
        self.outcome = outcome
        self.choices = choices
        self.choicesFail = choicesFail
        self.statusScript = statusScript
    }

    func run(
        _ command: HouseCommand,
        argument: String?,
        in manifest: HouseCommandManifest
    ) async throws -> HouseCommandOutcome {
        runs.append(Run(app: manifest.app, verb: command.verb, argument: argument))
        if let failure { throw failure }
        return outcome
    }

    func status(for manifest: HouseCommandManifest) async throws -> HouseCommandStatus? {
        statusReads.append(manifest.app)
        if statusFailures.contains(manifest.app) {
            throw HouseCommandError.unreachable(app: manifest.name)
        }
        // The last scripted status sticks, so a test asserts on the state
        // the app settles in rather than on how many times it was read.
        if statusScript.count > 1 { return statusScript.removeFirst() }
        if let settled = statusScript.first { return settled }
        return statuses[manifest.app] ?? nil
    }

    func choices(
        for command: HouseCommand,
        in manifest: HouseCommandManifest
    ) async throws -> [HouseCommandChoice] {
        choiceFetches.append(command.id)
        if choicesFail { throw HouseCommandError.unreachable(app: manifest.name) }
        return choices
    }

    func recordedRuns() -> [Run] { runs }
    func recordedStatusReads() -> [String] { statusReads }
    func recordedChoiceFetches() -> [String] { choiceFetches }
}

private func status(_ flags: [String: Bool], detail: String? = nil) -> HouseCommandStatus {
    HouseCommandStatus(flags: flags, detail: detail)
}

// MARK: - Parsing

@Suite("House command manifests")
struct HouseCommandManifestTests {

    @Test func readsTheContractExample() throws {
        let manifest = try #require(HouseCommandManifest.parse(Data(rtiManifest.utf8)))
        #expect(manifest.app == "rti")
        #expect(manifest.name == "RTI")
        #expect(manifest.transport == .socket)
        #expect(manifest.status == "status")
        #expect(manifest.commands.count == 2)
        #expect(manifest.commands[0].title == "Start Recording")
        #expect(manifest.commands[0].verb == "start")
        #expect(manifest.commands[0].needs == nil)
        #expect(manifest.commands[0].unavailableWhen?.field == "recording")
        #expect(manifest.commands[0].unavailableWhen?.isNegated == false)
        #expect(manifest.commands[1].unavailableWhen?.isNegated == true)
    }

    @Test func takesTheEndpointLiterallyAndExpandsNothing() throws {
        let manifest = try #require(HouseCommandManifest.parse(Data(rtiManifest.utf8)))
        #expect(manifest.endpoint == "/Users/fixture/.config/rti/control.sock")

        // A manifest is always written resolved and absolute. If one ever
        // carries a tilde, the reader takes it as written rather than
        // guessing at a path layout.
        let odd = try #require(HouseCommandManifest.parse(Data(#"""
        {"schema": 1, "app": "x", "name": "X", "transport": "socket",
         "endpoint": "~/x.sock", "commands": []}
        """#.utf8)))
        #expect(odd.endpoint == "~/x.sock")
    }

    @Test func readsTheShippedHTTPShapeWithItsRoutesAndChoicesFrom() throws {
        let manifest = try #require(HouseCommandManifest.parse(Data(modelsManifest.utf8)))
        #expect(manifest.transport == .http)
        #expect(manifest.status == "/v1/status")
        #expect(manifest.commands[0].verb == "/v1/warm")
        #expect(manifest.commands[0].needs == .choice)
        #expect(manifest.commands[0].choicesFrom == "/v1/choices/model")
        // An explicit null reads as no condition at all.
        #expect(manifest.commands[0].unavailableWhen == nil)
        #expect(manifest.commands[1].unavailableWhen?.field == "warm")
    }

    @Test func readsTheExecStatusFilePath() throws {
        let manifest = try #require(HouseCommandManifest.parse(
            Data(memoryManifest(statusPath: "/tmp/memory.status.json").utf8)
        ))
        #expect(manifest.transport == .exec)
        #expect(manifest.status == "/tmp/memory.status.json")
        #expect(manifest.needsStatus, "a gated command plus a status file")
    }

    @Test func malformedAndUnknownSchemaManifestsOfferNothing() {
        #expect(HouseCommandManifest.parse(Data("this is not json".utf8)) == nil)
        #expect(HouseCommandManifest.parse(Data("[1, 2, 3]".utf8)) == nil)
        #expect(HouseCommandManifest.parse(Data(#"{"schema": 1, "app": "rti""#.utf8)) == nil)
        #expect(HouseCommandManifest.parse(Data()) == nil)
        // A schema from a later version of the contract: the shape is
        // unknown, so none of it is read.
        #expect(HouseCommandManifest.parse(Data(#"{"schema": 2, "app": "rti", "name": "RTI", "transport": "socket", "endpoint": "/tmp/x.sock", "commands": []}"#.utf8)) == nil)
        #expect(HouseCommandManifest.parse(Data(#"{"app": "rti", "transport": "socket", "endpoint": "/tmp/x.sock"}"#.utf8)) == nil)
        #expect(HouseCommandManifest.parse(Data(#"{"schema": 1, "app": "x", "transport": "carrier-pigeon", "endpoint": "/tmp/x"}"#.utf8)) == nil)
        #expect(HouseCommandManifest.parse(Data(#"{"schema": 1, "app": "x", "transport": "exec"}"#.utf8)) == nil)
    }

    @Test func oneBadCommandIsDroppedAndTheRestSurvive() throws {
        let json = """
        {"schema": 1, "app": "x", "name": "X", "transport": "exec", "endpoint": "/bin/echo",
         "commands": [
           {"id": "good", "title": "Good", "verb": "go"},
           {"id": "", "title": "No id", "verb": "go"},
           {"id": "no-title", "verb": "go"},
           {"id": "no-verb", "title": "No verb"},
           {"id": "odd-needs", "title": "Odd", "verb": "go", "needs": "voiceprint"},
           {"id": "choice-with-nowhere-to-get-them", "title": "Pick", "verb": "go", "needs": "choice"}
         ]}
        """
        let manifest = try #require(HouseCommandManifest.parse(Data(json.utf8)))
        #expect(manifest.commands.map(\.id) == ["good"])
    }

    @Test func statusDocumentKeepsEveryBooleanAndTheDetail() throws {
        let parsed = try #require(HouseCommandStatus.parse(
            #"{"app": "rti", "ok": true, "busy": false, "detail": "Idle", "recording": false}"#
        ))
        #expect(parsed.ok)
        #expect(!parsed.busy)
        #expect(parsed.detail == "Idle")
        #expect(parsed.flags["recording"] == false)
        #expect(parsed.flags["app"] == nil, "a string is not a flag")
        #expect(HouseCommandStatus.parse("not json") == nil)
        #expect(HouseCommandStatus.parse("") == nil)
    }

    @Test func choicesPayloadReadsIdTitleAndDetail() {
        let choices = HouseCommandChoice.parse(#"""
        {"choices": [
          {"id": "qwen3-vl", "title": "Qwen3 VL", "detail": "6.2 GB"},
          {"id": "bare"},
          {"title": "no id"}
        ]}
        """#)
        #expect(choices.map(\.id) == ["qwen3-vl", "bare"])
        #expect(choices[0].title == "Qwen3 VL")
        #expect(choices[0].detail == "6.2 GB")
        #expect(choices[1].title == "bare", "a choice with no title falls back to its id")
        #expect(HouseCommandChoice.parse("not json").isEmpty)
        #expect(HouseCommandChoice.parse(#"{"choices": []}"#).isEmpty)
    }

    @Test func unavailableWhenReadsBothWaysAndNeverGuesses() throws {
        let manifest = try #require(HouseCommandManifest.parse(Data(rtiManifest.utf8)))
        let start = manifest.commands[0]
        let stop = manifest.commands[1]

        let idle = status(["recording": false])
        #expect(start.isAvailable(given: idle))
        #expect(!stop.isAvailable(given: idle))

        let recording = status(["recording": true])
        #expect(!start.isAvailable(given: recording))
        #expect(stop.isAvailable(given: recording))

        // No status at all, and a status without the field: neither row is
        // drawn, because the launcher never guesses.
        #expect(!start.isAvailable(given: nil))
        #expect(!stop.isAvailable(given: nil))
        #expect(!start.isAvailable(given: status(["ok": true])))
    }
}

// MARK: - The manifest folder

@Suite("House command directory")
struct HouseCommandDirectoryTests {

    @Test func readsEveryManifestAndSkipsTheRest() {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        folder.write("memory.json", plainMemoryManifest)
        folder.write("broken.json", "{ not json")
        folder.write("future.json", #"{"schema": 99, "app": "future"}"#)
        folder.write("notes.txt", rtiManifest)

        let manifests = folder.directory.manifests()
        #expect(manifests.map(\.app) == ["memory", "rti"], "sorted by file name, bad files skipped")
    }

    @Test func aMissingFolderIsSimplyNoCommands() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-absent-\(UUID().uuidString)")
        #expect(HouseCommandDirectory(root: missing).manifests().isEmpty)
    }

    @Test func anEmptyFolderIsSimplyNoCommands() {
        let folder = FixtureFolder()
        #expect(folder.directory.manifests().isEmpty)
    }
}

// MARK: - Transports

@Suite("House command transports")
struct HouseCommandDispatcherTests {

    private func manifest(_ json: String) throws -> HouseCommandManifest {
        try #require(HouseCommandManifest.parse(Data(json.utf8)))
    }

    // MARK: socket

    @Test func socketSendsOneLineAndReadsOneLine() async throws {
        let manifest = try manifest(rtiManifest)
        let sent = Sent()
        let dispatcher = HouseCommandDispatcher(
            sendLine: { url, line, timeout in
                await sent.record(url: url, line: line, timeout: timeout)
                return "ok"
            }
        )
        let outcome = try await dispatcher.run(manifest.commands[0], argument: nil, in: manifest)
        #expect(outcome == .completed("ok"))
        let record = await sent.last
        #expect(record?.line == "start")
        #expect(record?.url.path == "/Users/fixture/.config/rti/control.sock")
        #expect(record?.timeout == HouseCommandDispatcher.runTimeout)
    }

    @Test func socketPutsTheArgumentAfterOneSpaceOnOneLine() async throws {
        let manifest = try manifest(rtiManifest)
        let sent = Sent()
        let dispatcher = HouseCommandDispatcher(
            sendLine: { url, line, timeout in
                await sent.record(url: url, line: line, timeout: timeout)
                return "ok"
            }
        )
        _ = try await dispatcher.run(
            manifest.commands[0],
            argument: "a note\nwith a newline",
            in: manifest
        )
        let line = await sent.last?.line
        #expect(line == "start a note with a newline", "one request is always one line")
    }

    @Test func anErrReplyIsAFailureAndItsTextIsWhatTheUserSees() async throws {
        let manifest = try manifest(rtiManifest)
        let dispatcher = HouseCommandDispatcher(
            sendLine: { _, _, _ in #"err unknown command "foo""# }
        )
        await #expect(throws: HouseCommandError.refused(app: "RTI", message: #"unknown command "foo""#)) {
            try await dispatcher.run(manifest.commands[0], argument: nil, in: manifest)
        }

        // A reply that merely mentions an error is a success, not a refusal:
        // only the `err ` prefix marks one.
        let chatty = HouseCommandDispatcher(sendLine: { _, _, _ in "recovered from an error" })
        let outcome = try await chatty.run(manifest.commands[0], argument: nil, in: manifest)
        #expect(outcome == .completed("recovered from an error"))
    }

    @Test func aDeadSocketIsUnreachableAndATimeoutSaysSo() async throws {
        let manifest = try manifest(rtiManifest)
        let dead = HouseCommandDispatcher(
            sendLine: { _, _, _ in throw UnixSocketLineClient.Failure.cannotConnect }
        )
        await #expect(throws: HouseCommandError.unreachable(app: "RTI")) {
            try await dead.run(manifest.commands[0], argument: nil, in: manifest)
        }
        let slow = HouseCommandDispatcher(
            sendLine: { _, _, _ in throw UnixSocketLineClient.Failure.timedOut }
        )
        await #expect(throws: HouseCommandError.timedOut(app: "RTI")) {
            try await slow.run(manifest.commands[0], argument: nil, in: manifest)
        }
    }

    @Test func socketStatusUsesTheShortTimeout() async throws {
        let manifest = try manifest(rtiManifest)
        let sent = Sent()
        let dispatcher = HouseCommandDispatcher(
            sendLine: { url, line, timeout in
                await sent.record(url: url, line: line, timeout: timeout)
                return #"{"app": "rti", "ok": true, "busy": false, "detail": "Idle", "recording": false}"#
            }
        )
        let status = try await dispatcher.status(for: manifest)
        #expect(status?.detail == "Idle")
        #expect(status?.flags["recording"] == false)
        let record = await sent.last
        #expect(record?.line == "status")
        #expect(record?.timeout == HouseCommandDispatcher.statusTimeout)
        #expect(HouseCommandDispatcher.statusTimeout <= 1, "a status read never costs the launcher more than a second")
    }

    // MARK: http

    @Test func httpPostsTheRouteAndGetsTheStatus() async throws {
        let host = "http://127.0.0.1:8101"
        let manifest = try manifest(modelsManifest.replacingOccurrences(
            of: "http://127.0.0.1:8078",
            with: host
        ))
        HouseHTTPStub.serve(host + "/v1/unload", status: 200, body: "ok")
        HouseHTTPStub.serve(
            host + "/v1/status",
            status: 200,
            body: #"{"app": "models", "ok": true, "busy": false, "detail": "2 warm"}"#
        )
        let dispatcher = HouseCommandDispatcher(session: HouseHTTPStub.session())

        // A command is POST {endpoint}{verb}: the route carries its own
        // leading slash and is joined as written.
        let outcome = try await dispatcher.run(manifest.commands[1], argument: nil, in: manifest)
        #expect(outcome == .completed("ok"))
        let posted = try #require(HouseHTTPStub.requests.first { $0.url?.absoluteString == host + "/v1/unload" })
        #expect(posted.httpMethod == "POST")

        // status is a GET.
        let status = try await dispatcher.status(for: manifest)
        #expect(status?.detail == "2 warm")
        let read = try #require(HouseHTTPStub.requests.first { $0.url?.absoluteString == host + "/v1/status" })
        #expect(read.httpMethod == "GET")
    }

    @Test func everyPostCarriesTheArgumentEnvelopeAndNeverAsksToWait() async throws {
        let host = "http://127.0.0.1:8104"
        let manifest = try manifest(modelsManifest.replacingOccurrences(
            of: "http://127.0.0.1:8078",
            with: host
        ))
        HouseHTTPStub.serve(host + "/v1/warm", status: 200, body: "ok")
        HouseHTTPStub.serve(host + "/v1/unload", status: 200, body: "ok")
        let dispatcher = HouseCommandDispatcher(session: HouseHTTPStub.session())

        _ = try await dispatcher.run(manifest.commands[0], argument: "qwen3-vl", in: manifest)
        let body = try #require(HouseHTTPStub.bodies[host + "/v1/warm"])
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["argument"] as? String == "qwen3-vl")
        #expect(decoded["wait"] as? Bool == false)

        // Even a command with no argument and nothing slow to do says so:
        // the caller never needs to know which is which.
        _ = try await dispatcher.run(manifest.commands[1], argument: nil, in: manifest)
        let bare = try #require(HouseHTTPStub.bodies[host + "/v1/unload"])
        let plain = try #require(try JSONSerialization.jsonObject(with: bare) as? [String: Any])
        #expect(plain["wait"] as? Bool == false)
        #expect(plain["argument"] == nil)
    }

    @Test func aStartedReplyIsSuccessNotFailure() async throws {
        let host = "http://127.0.0.1:8105"
        let manifest = try manifest(modelsManifest.replacingOccurrences(
            of: "http://127.0.0.1:8078",
            with: host
        ))
        HouseHTTPStub.serve(host + "/v1/warm", status: 200, body: #"{"started": true}"#)
        let dispatcher = HouseCommandDispatcher(session: HouseHTTPStub.session())
        let outcome = try await dispatcher.run(manifest.commands[0], argument: "qwen3-vl", in: manifest)
        #expect(outcome == .started, "the work is running, and that is not an error")
    }

    @Test func choicesAreFetchedWithAGet() async throws {
        let host = "http://127.0.0.1:8106"
        let manifest = try manifest(modelsManifest.replacingOccurrences(
            of: "http://127.0.0.1:8078",
            with: host
        ))
        HouseHTTPStub.serve(
            host + "/v1/choices/model",
            status: 200,
            body: #"{"choices": [{"id": "qwen3-vl", "title": "Qwen3 VL", "detail": "6.2 GB"}]}"#
        )
        let dispatcher = HouseCommandDispatcher(session: HouseHTTPStub.session())
        let choices = try await dispatcher.choices(for: manifest.commands[0], in: manifest)
        #expect(choices.map(\.id) == ["qwen3-vl"])
        let fetch = try #require(HouseHTTPStub.requests.first { $0.url?.absoluteString == host + "/v1/choices/model" })
        #expect(fetch.httpMethod == "GET")
    }

    @Test func httpFailuresBecomeSentencesTheUserCanRead() async throws {
        let host = "http://127.0.0.1:8102"
        let manifest = try manifest(modelsManifest.replacingOccurrences(
            of: "http://127.0.0.1:8078",
            with: host
        ))
        HouseHTTPStub.serve(host + "/v1/unload", status: 500, body: "no model loaded")
        let dispatcher = HouseCommandDispatcher(session: HouseHTTPStub.session())
        await #expect(throws: HouseCommandError.refused(app: "Local Models", message: "no model loaded")) {
            try await dispatcher.run(manifest.commands[1], argument: nil, in: manifest)
        }
    }

    @Test func aDaemonThatIsNotRunningIsUnreachable() async throws {
        let manifest = try manifest(modelsManifest.replacingOccurrences(
            of: "http://127.0.0.1:8078",
            with: "http://127.0.0.1:8103"
        ))
        let dead = HouseCommandDispatcher(session: HouseHTTPStub.session())
        await #expect(throws: HouseCommandError.unreachable(app: "Local Models")) {
            try await dead.run(manifest.commands[1], argument: nil, in: manifest)
        }
    }

    @Test func aHungEndpointIsReportedAsATimeoutRatherThanHanging() async throws {
        let host = "http://127.0.0.1:8107"
        let manifest = try manifest(modelsManifest.replacingOccurrences(
            of: "http://127.0.0.1:8078",
            with: host
        ))
        // Served by nothing that ever answers: the request must come back as
        // a timeout, not sit there.
        HouseHTTPStub.hang(host + "/v1/unload")
        let dispatcher = HouseCommandDispatcher(session: HouseHTTPStub.session(timeout: 0.5))
        let started = Date()
        await #expect(throws: HouseCommandError.timedOut(app: "Local Models")) {
            try await dispatcher.run(manifest.commands[1], argument: nil, in: manifest)
        }
        #expect(Date().timeIntervalSince(started) < 20, "a hung app is bounded, never waited on")
    }

    // MARK: exec

    @Test func execRunsADirectArgvLaunchAndNeverAShell() async throws {
        let manifest = try manifest(plainMemoryManifest)
        let launched = Launched()
        let dispatcher = HouseCommandDispatcher(
            runProcess: { url, arguments, timeout in
                await launched.record(url: url, arguments: arguments, timeout: timeout)
                return ProcessResult(stdout: Data("saved".utf8), stderr: Data(), status: 0)
            },
            resolveExecutable: { URL(fileURLWithPath: $0) }
        )
        let outcome = try await dispatcher.run(
            manifest.commands[0],
            argument: "buy milk; rm -rf /",
            in: manifest
        )
        #expect(outcome == .completed("saved"))
        let record = await launched.last
        #expect(record?.url.path == "/usr/local/bin/recall")
        #expect(
            record?.arguments == ["capture", "buy milk; rm -rf /"],
            "user text is one argument, never shell syntax"
        )
    }

    @Test func execStatusReadsTheFileAndExecutesNothing() async throws {
        let folder = FixtureFolder()
        let path = folder.write("memory.status.json", statusDocument)
        let manifest = try manifest(memoryManifest(statusPath: path))
        let dispatcher = HouseCommandDispatcher(
            runProcess: { _, _, _ in
                Issue.record("a status read must never run the CLI")
                return ProcessResult(stdout: Data(), stderr: Data(), status: 0)
            },
            resolveExecutable: { URL(fileURLWithPath: $0) }
        )
        let status = try await dispatcher.status(for: manifest)
        #expect(status?.ok == true)
        #expect(status?.detail == "Collecting")
    }

    @Test func aMissingExecStatusFileIsUnavailableLikeADeadSocket() async throws {
        let manifest = try manifest(memoryManifest(statusPath: "/tmp/quick-launch-no-such-status.json"))
        let dispatcher = HouseCommandDispatcher(resolveExecutable: { URL(fileURLWithPath: $0) })
        await #expect(throws: HouseCommandError.unreachable(app: "Memory")) {
            try await dispatcher.status(for: manifest)
        }
    }

    @Test func aMalformedExecStatusFileIsUnavailableLikeADeadSocket() async throws {
        let folder = FixtureFolder()
        let path = folder.write("memory.status.json", "{ half written")
        let manifest = try manifest(memoryManifest(statusPath: path))
        let dispatcher = HouseCommandDispatcher(resolveExecutable: { URL(fileURLWithPath: $0) })
        await #expect(throws: HouseCommandError.unreachable(app: "Memory")) {
            try await dispatcher.status(for: manifest)
        }
    }

    @Test func anOldExecStatusFileIsStillCurrent() async throws {
        let folder = FixtureFolder()
        let path = folder.write("memory.status.json", statusDocument)
        // An app whose state rarely changes has an old file and is perfectly
        // healthy. Age is never staleness.
        folder.backdate("memory.status.json", days: 90)
        let manifest = try manifest(memoryManifest(statusPath: path))
        let dispatcher = HouseCommandDispatcher(resolveExecutable: { URL(fileURLWithPath: $0) })
        let status = try await dispatcher.status(for: manifest)
        #expect(status?.ok == true, "a 90-day-old file still reads as current")
        #expect(status?.detail == "Collecting")
    }

    @Test func execChoicesRunTheRouteAsASubcommand() async throws {
        let json = """
        {"schema": 1, "app": "x", "name": "X", "transport": "exec", "endpoint": "/bin/echo",
         "commands": [{"id": "pick", "title": "Pick", "verb": "use", "needs": "choice",
                       "choicesFrom": "list-choices"}]}
        """
        let manifest = try manifest(json)
        let launched = Launched()
        let dispatcher = HouseCommandDispatcher(
            runProcess: { url, arguments, timeout in
                await launched.record(url: url, arguments: arguments, timeout: timeout)
                return ProcessResult(
                    stdout: Data(#"{"choices": [{"id": "one", "title": "One"}]}"#.utf8),
                    stderr: Data(),
                    status: 0
                )
            },
            resolveExecutable: { URL(fileURLWithPath: $0) }
        )
        let choices = try await dispatcher.choices(for: manifest.commands[0], in: manifest)
        #expect(choices.map(\.id) == ["one"])
        #expect(await launched.last?.arguments == ["list-choices"])
    }

    @Test func anAppThatIsNotInstalledSaysSoRatherThanFailing() async throws {
        let manifest = try manifest(plainMemoryManifest)
        let dispatcher = HouseCommandDispatcher(
            runProcess: { _, _, _ in
                Issue.record("a missing executable must never be run")
                return ProcessResult(stdout: Data(), stderr: Data(), status: 0)
            },
            resolveExecutable: { _ in nil }
        )
        await #expect(throws: HouseCommandError.notInstalled(app: "Memory")) {
            try await dispatcher.run(manifest.commands[0], argument: "x", in: manifest)
        }
    }

    @Test func execFailureCarriesTheCommandsOwnStderr() async throws {
        let manifest = try manifest(plainMemoryManifest)
        let dispatcher = HouseCommandDispatcher(
            runProcess: { _, _, _ in
                ProcessResult(stdout: Data(), stderr: Data("the store is locked".utf8), status: 1)
            },
            resolveExecutable: { URL(fileURLWithPath: $0) }
        )
        await #expect(throws: HouseCommandError.refused(app: "Memory", message: "the store is locked")) {
            try await dispatcher.run(manifest.commands[0], argument: "x", in: manifest)
        }
    }

    @Test func execTimeoutIsReportedAsATimeout() async throws {
        let manifest = try manifest(plainMemoryManifest)
        let dispatcher = HouseCommandDispatcher(
            runProcess: { _, _, _ in
                throw ProcessRunnerError.timedOut(executable: "recall", seconds: 5)
            },
            resolveExecutable: { URL(fileURLWithPath: $0) }
        )
        await #expect(throws: HouseCommandError.timedOut(app: "Memory")) {
            try await dispatcher.run(manifest.commands[0], argument: "x", in: manifest)
        }
    }

    @Test func aSocketPathTooLongToConnectToIsRefusedBeforeAnyDescriptorOpens() async {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 200) + ".sock")
        await #expect(throws: UnixSocketLineClient.Failure.cannotConnect) {
            try await UnixSocketLineClient.send("status", to: long, timeout: 0.2)
        }
    }

    @Test func theSocketDescriptorIsNotInheritedByChildren() {
        let descriptor = UnixSocketLineClient.makeSocket()
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFD)
        #expect(flags != -1)
        #expect(flags & FD_CLOEXEC != 0)
    }
}

// MARK: - The catalog

@Suite("House command catalog")
struct HouseCommandCatalogTests {

    @Test func rowsReadAsTheEffectWithTheOwningAppAsTheDetail() async {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let dispatcher = FakeDispatcher(statuses: ["rti": status(["recording": false], detail: "Idle")])
        let catalog = HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)

        let rows = await catalog.refresh()
        #expect(rows.count == 1, "only Start Recording is drawn while idle")
        let item = rows[0].item
        #expect(item.title == "Start Recording")
        #expect(item.detail == "RTI · Idle")
        #expect(item.kind == .command)
        #expect(item.value == "house.rti.record.start")
    }

    @Test func unavailableWhenHidesTheRowBothWays() async {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)

        let idle = HouseCommandCatalog(
            directory: folder.directory,
            dispatcher: FakeDispatcher(statuses: ["rti": status(["recording": false])])
        )
        #expect(await idle.refresh().map(\.command.title) == ["Start Recording"])

        let recording = HouseCommandCatalog(
            directory: folder.directory,
            dispatcher: FakeDispatcher(statuses: ["rti": status(["recording": true])])
        )
        #expect(await recording.refresh().map(\.command.title) == ["Stop Recording"])
    }

    @Test func aHiddenRowIsStillReachableBecauseTheHintOnlyDecidesWhatIsDrawn() async throws {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let dispatcher = FakeDispatcher(statuses: ["rti": status(["recording": false])])
        let catalog = HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        _ = await catalog.refresh()

        // Stop Recording is not drawn while idle, but the app accepts it at
        // any time and answers idempotently, so a lookup must find it.
        #expect(await catalog.rows().map(\.command.title) == ["Start Recording"])
        let stop = try #require(await catalog.row(forValue: "house.rti.record.stop"))
        #expect(stop.command.title == "Stop Recording")

        _ = try await catalog.run(stop, argument: nil)
        #expect(await dispatcher.recordedRuns() == [
            FakeDispatcher.Run(app: "rti", verb: "stop", argument: nil)
        ])
    }

    @Test func aDeadAppOffersNothingAndNeverThrows() async {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let catalog = HouseCommandCatalog(
            directory: folder.directory,
            dispatcher: FakeDispatcher(statusFailures: ["rti"])
        )
        #expect(await catalog.refresh().isEmpty)
    }

    @Test func anAppWithNoStatusIsNeverProbedAndStillOffersItsCommands() async {
        let folder = FixtureFolder()
        folder.write("memory.json", plainMemoryManifest)
        let dispatcher = FakeDispatcher()
        let catalog = HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)

        let rows = await catalog.refresh()
        #expect(rows.map(\.command.title) == ["Capture a Thought"])
        #expect(await dispatcher.recordedStatusReads().isEmpty, "nothing is gated, so nothing is read")
    }

    @Test func statusIsCachedBrieflySoOpeningTheLauncherTwiceCostsOneRead() async {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000))
        let dispatcher = FakeDispatcher(statuses: ["rti": status(["recording": false])])
        let catalog = HouseCommandCatalog(
            directory: folder.directory,
            dispatcher: dispatcher,
            now: { clock.now }
        )

        _ = await catalog.refresh()
        _ = await catalog.refresh()
        #expect(await dispatcher.recordedStatusReads() == ["rti"], "the second read is served from the cache")

        clock.advance(by: HouseCommandCatalog.statusFreshness + 1)
        _ = await catalog.refresh()
        #expect(await dispatcher.recordedStatusReads() == ["rti", "rti"], "a stale status is read again")
    }

    @Test func choicesAreFetchedOnOpenAndNeverAtLaunch() async throws {
        let folder = FixtureFolder()
        folder.write("models.json", modelsManifest)
        let dispatcher = FakeDispatcher(
            statuses: ["models": status(["warm": true])],
            choices: [HouseCommandChoice(id: "qwen3-vl", title: "Qwen3 VL", detail: "6.2 GB")]
        )
        let catalog = HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)

        let rows = await catalog.refresh()
        #expect(await dispatcher.recordedChoiceFetches().isEmpty, "a list frozen at launch would be stale")

        let warm = try #require(rows.first { $0.command.id == "model.warm" })
        let choices = try await catalog.choices(for: warm)
        #expect(choices.map(\.id) == ["qwen3-vl"])
        #expect(await dispatcher.recordedChoiceFetches() == ["model.warm"])
    }

    @Test func aChoicesFetchThatFailsOrAnswersNothingIsAFailure() async throws {
        let folder = FixtureFolder()
        folder.write("models.json", modelsManifest)

        let broken = HouseCommandCatalog(
            directory: folder.directory,
            dispatcher: FakeDispatcher(statuses: ["models": status(["warm": true])], choicesFail: true)
        )
        let brokenRow = try #require(await broken.refresh().first { $0.command.id == "model.warm" })
        await #expect(throws: HouseCommandError.unreachable(app: "Local Models")) {
            try await broken.choices(for: brokenRow)
        }

        // An empty list is a failure too: a picker with nothing in it is
        // worse than a sentence saying so.
        let empty = HouseCommandCatalog(
            directory: folder.directory,
            dispatcher: FakeDispatcher(statuses: ["models": status(["warm": true])], choices: [])
        )
        let emptyRow = try #require(await empty.refresh().first { $0.command.id == "model.warm" })
        await #expect(throws: HouseCommandError.noChoices(app: "Local Models", command: "Warm Model")) {
            try await empty.choices(for: emptyRow)
        }
    }

    @Test func waitingOnStartedWorkPollsUntilBusyClears() async throws {
        let folder = FixtureFolder()
        folder.write("models.json", modelsManifest)
        let dispatcher = FakeDispatcher(
            statuses: ["models": status(["warm": true])],
            statusScript: [
                status(["warm": false], detail: "Loading"),
                status(["warm": false], detail: "Loading"),
                status(["warm": true], detail: "Warm"),
            ]
        )
        let catalog = HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        let rows = await catalog.refresh()
        let warm = try #require(rows.first { $0.command.id == "model.warm" })

        // The scripted statuses report busy until the last one.
        let busyDispatcher = FakeDispatcher(statusScript: [
            HouseCommandStatus(flags: ["ok": true, "busy": true], detail: "Loading"),
            HouseCommandStatus(flags: ["ok": true, "busy": false], detail: "Warm"),
        ])
        let busyCatalog = HouseCommandCatalog(directory: folder.directory, dispatcher: busyDispatcher)
        _ = await busyCatalog.refresh()
        let busyRow = try #require(await busyCatalog.row(forValue: warm.id))
        let final = await busyCatalog.waitWhileBusy(busyRow, pollEvery: .milliseconds(1), deadline: 5)
        #expect(final?.detail == "Warm")
        #expect(final?.busy == false)
        _ = dispatcher
    }

    @Test func waitingGivesUpRatherThanHangingForever() async throws {
        let folder = FixtureFolder()
        folder.write("models.json", modelsManifest)
        let neverIdle = FakeDispatcher(statuses: ["models": HouseCommandStatus(
            flags: ["ok": true, "busy": true],
            detail: "Loading"
        )])
        let catalog = HouseCommandCatalog(directory: folder.directory, dispatcher: neverIdle)
        _ = await catalog.refresh()
        let row = try #require(await catalog.row(forValue: "house.models.model.warm"))
        let final = await catalog.waitWhileBusy(row, pollEvery: .milliseconds(1), deadline: 0.2)
        #expect(final == nil, "a poll that never settles is reported, not waited on")
    }

    @Test func runningACommandDispatchesItAndDropsTheStaleStatus() async throws {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let dispatcher = FakeDispatcher(statuses: ["rti": status(["recording": false])])
        let catalog = HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)

        let rows = await catalog.refresh()
        _ = try await catalog.run(rows[0], argument: nil)
        #expect(await dispatcher.recordedRuns() == [FakeDispatcher.Run(app: "rti", verb: "start", argument: nil)])

        _ = await catalog.refresh()
        #expect(await dispatcher.recordedStatusReads() == ["rti", "rti"])
    }

    @Test func aChoiceValueSplitsBackIntoTheCommandAndThePosition() {
        let value = HouseCommandCatalog.choiceValue(rowID: "house.models.model.warm", index: 2)
        #expect(value == "house.models.model.warm#2")
        let parsed = HouseCommandCatalog.choice(inValue: value)
        #expect(parsed?.rowID == "house.models.model.warm")
        #expect(parsed?.index == 2)
        #expect(HouseCommandCatalog.choice(inValue: "house.rti.record.start") == nil)
        #expect(HouseCommandCatalog.choice(inValue: "toggle.lockScreen") == nil)
        #expect(HouseCommandCatalog.isHouseCommand("house.rti.record.start"))
        #expect(!HouseCommandCatalog.isHouseCommand("caffeinate.toggle"))
    }
}

// MARK: - The launcher

@Suite("House commands in the launcher", .serialized)
@MainActor
struct HouseCommandLauncherTests {

    @Test func commandsAppearInTheCommandsCatalogAndRootSearch() async {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let catalog = HouseCommandCatalog(
            directory: folder.directory,
            dispatcher: FakeDispatcher(statuses: ["rti": status(["recording": false], detail: "Idle")])
        )
        let vm = QuickViewModel(service: MockQuickService(), houseCommandCatalog: catalog)
        #expect(vm.houseCommandItems.isEmpty, "nothing is read until a refresh is asked for")

        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()

        #expect(vm.houseCommandItems.map(\.title) == ["Start Recording"])
        #expect(vm.systemCommands.contains { $0.value == "house.rti.record.start" })

        vm.input = "start recording"
        let titles = vm.launcherMatches.compactMap { result -> String? in
            guard case .item(let item) = result else { return nil }
            return item.title
        }
        #expect(titles.contains("Start Recording"))
    }

    @Test func anAbsentAppMeansNoRowsAndNoLauncherTrouble() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-absent-\(UUID().uuidString)")
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(
                directory: HouseCommandDirectory(root: missing),
                dispatcher: FakeDispatcher()
            )
        )
        let before = vm.systemCommands.count
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()

        #expect(vm.houseCommandItems.isEmpty)
        #expect(vm.systemCommands.count == before, "the launcher's own commands are untouched")
        #expect(vm.errorMessage == nil, "a missing app is not an error the user must read")
        vm.input = "start"
        #expect(!vm.launcherMatches.isEmpty, "the launcher still works")
    }

    @Test func aDeadAppsRowsDisappearRatherThanOfferingWhatWouldFail() async {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(
                directory: folder.directory,
                dispatcher: FakeDispatcher(statusFailures: ["rti"])
            )
        )
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()
        #expect(vm.houseCommandItems.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    @Test func runningACommandWithNoArgumentDispatchesItStraightAway() async {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let dispatcher = FakeDispatcher(statuses: ["rti": status(["recording": false])])
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        )
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()

        await vm.performHouseCommand(vm.houseCommandItems[0])
        await vm.waitForHouseCommandRefreshForTesting()

        #expect(await dispatcher.recordedRuns() == [FakeDispatcher.Run(app: "rti", verb: "start", argument: nil)])
        #expect(vm.errorMessage == nil)
        #expect(presenter.dismissals == 1, "a plain ok closes the launcher")
    }

    @Test func aTextCommandAsksForItsArgumentWithTheExistingPrompt() async {
        let folder = FixtureFolder()
        folder.write("memory.json", plainMemoryManifest)
        let dispatcher = FakeDispatcher()
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        )
        vm.overlayPresenter = RecordingPresenter()
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()

        await vm.performHouseCommand(vm.houseCommandItems[0])
        #expect(vm.inputMode == .houseCommandArgument)
        #expect(vm.footerContext == "Memory · Capture a Thought")
        #expect(vm.inputPlaceholder == "Capture a Thought…")
        #expect(vm.footerHints.first?.label == "Run")
        #expect(await dispatcher.recordedRuns().isEmpty, "nothing runs until the argument is given")

        vm.input = "the roof needs fixing"
        #expect(await vm.submitInputMode())
        await vm.waitForHouseCommandRefreshForTesting()

        #expect(await dispatcher.recordedRuns() == [
            FakeDispatcher.Run(app: "memory", verb: "capture", argument: "the roof needs fixing")
        ])
        #expect(vm.inputMode == nil)
    }

    @Test func aChoiceCommandFetchesItsOptionsWhenOpenedAndSendsTheChosenID() async throws {
        let folder = FixtureFolder()
        folder.write("models.json", modelsManifest)
        let dispatcher = FakeDispatcher(
            statuses: ["models": status(["warm": true])],
            choices: [
                HouseCommandChoice(id: "gemma-4", title: "Gemma 4", detail: "3.1 GB"),
                HouseCommandChoice(id: "qwen3-vl", title: "Qwen3 VL", detail: "6.2 GB"),
            ]
        )
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        )
        vm.overlayPresenter = RecordingPresenter()
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()
        #expect(await dispatcher.recordedChoiceFetches().isEmpty, "not at launch")

        let warm = try #require(vm.houseCommandItems.first { $0.title == "Warm Model" })
        await vm.performHouseCommand(warm)

        #expect(await dispatcher.recordedChoiceFetches() == ["model.warm"], "fetched when opened")
        #expect(vm.pendingHouseChoice?.row.command.id == "model.warm")
        #expect(vm.topLayer == .houseCommandChoice)
        let titles = vm.launcherMatches.compactMap { result -> String? in
            guard case .item(let item) = result else { return nil }
            return item.title
        }
        #expect(titles == ["Gemma 4", "Qwen3 VL"], "the app's own titles, in its own order")

        // Typing narrows the list, as it does in any catalog.
        vm.input = "qwen"
        let narrowed = vm.launcherMatches.compactMap { result -> String? in
            guard case .item(let item) = result else { return nil }
            return item.title
        }
        #expect(narrowed == ["Qwen3 VL"])

        guard case .item(let picked)? = vm.launcherMatches.first else {
            Issue.record("no choice row")
            return
        }
        await vm.performHouseCommand(picked)
        await vm.waitForHouseCommandRefreshForTesting()

        #expect(await dispatcher.recordedRuns() == [
            FakeDispatcher.Run(app: "models", verb: "/v1/warm", argument: "qwen3-vl")
        ], "the chosen id goes back, not its title")
        #expect(vm.pendingHouseChoice == nil)
    }

    @Test func aChoiceFetchThatFailsSaysSoAndOpensNoPicker() async throws {
        let folder = FixtureFolder()
        folder.write("models.json", modelsManifest)
        let dispatcher = FakeDispatcher(
            statuses: ["models": status(["warm": true])],
            choicesFail: true
        )
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        )
        vm.overlayPresenter = RecordingPresenter()
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()

        let warm = try #require(vm.houseCommandItems.first { $0.title == "Warm Model" })
        await vm.performHouseCommand(warm)

        #expect(vm.pendingHouseChoice == nil, "no picker with nothing in it")
        #expect(vm.topLayer != .houseCommandChoice)
        #expect(vm.errorMessage == "Local Models is not running.")
        #expect(await dispatcher.recordedRuns().isEmpty)
    }

    @Test func startedWorkIsReportedAtOnceAndItsEndFollows() async throws {
        let folder = FixtureFolder()
        folder.write("models.json", modelsManifest)
        let dispatcher = FakeDispatcher(
            statuses: ["models": status(["warm": true])],
            outcome: .started,
            choices: [HouseCommandChoice(id: "qwen3-vl", title: "Qwen3 VL", detail: nil)],
            statusScript: [
                HouseCommandStatus(flags: ["ok": true, "warm": true, "busy": true], detail: "Loading"),
                HouseCommandStatus(flags: ["ok": true, "warm": true, "busy": false], detail: "Warm · Qwen3 VL"),
            ]
        )
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        )
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()

        let warm = try #require(vm.houseCommandItems.first { $0.title == "Warm Model" })
        await vm.performHouseCommand(warm)
        guard case .item(let choice)? = vm.launcherMatches.first else {
            Issue.record("no choice row")
            return
        }
        await vm.performHouseCommand(choice)

        // Reported at once: the launcher never waits for slow work.
        #expect(vm.output == "Started. Local Models is working.")
        #expect(vm.errorMessage == nil, "started is a success, not a failure")

        await vm.waitForHouseCommandWatchForTesting()
        #expect(vm.output == "Warm · Qwen3 VL", "the end is reported when it comes")
        #expect(vm.errorMessage == nil)
    }

    @Test func aCommandThatFailsSaysSoInTheLaunchersOwnErrorLine() async {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let dispatcher = FakeDispatcher(
            statuses: ["rti": status(["recording": false])],
            failure: .refused(app: "RTI", message: "no input device")
        )
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        )
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()

        await vm.performHouseCommand(vm.houseCommandItems[0])
        await vm.waitForHouseCommandRefreshForTesting()

        #expect(vm.errorMessage == "RTI: no input device")
        #expect(presenter.dismissals == 0, "the panel stays open to show the failure")
    }

    @Test func backspaceLeavesAChoiceListWithoutRunningAnything() async throws {
        let folder = FixtureFolder()
        folder.write("models.json", modelsManifest)
        let dispatcher = FakeDispatcher(
            statuses: ["models": status(["warm": true])],
            choices: [HouseCommandChoice(id: "gemma-4", title: "Gemma 4", detail: nil)]
        )
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        )
        vm.overlayPresenter = RecordingPresenter()
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()

        let warm = try #require(vm.houseCommandItems.first { $0.title == "Warm Model" })
        await vm.performHouseCommand(warm)
        #expect(vm.topLayer == .houseCommandChoice)
        #expect(vm.popLayerForEmptyBackspace())
        #expect(vm.pendingHouseChoice == nil)
        #expect(vm.topLayer == .root)
        #expect(await dispatcher.recordedRuns().isEmpty)
    }

    @Test func aRowThatIsGoneReportsItselfRatherThanDoingNothing() async {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(
                directory: folder.directory,
                dispatcher: FakeDispatcher(statuses: ["rti": status(["recording": false])])
            )
        )
        vm.overlayPresenter = RecordingPresenter()
        await vm.performHouseCommand(
            LauncherCatalogItem(
                kind: .command,
                itemID: "house.gone.command",
                title: "Gone",
                detail: "",
                value: "house.gone.command"
            )
        )
        #expect(vm.errorMessage == "That command is no longer available.")
    }
}

// MARK: - Test doubles

/// A clock a test moves by hand, so a cache test never waits on real time.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

/// What the socket seam was handed.
private actor Sent {
    struct Record: Sendable, Equatable {
        let url: URL
        let line: String
        let timeout: TimeInterval
    }

    private(set) var records: [Record] = []
    var last: Record? { records.last }

    func record(url: URL, line: String, timeout: TimeInterval) {
        records.append(Record(url: url, line: line, timeout: timeout))
    }
}

/// What the process seam was handed.
private actor Launched {
    struct Record: Sendable, Equatable {
        let url: URL
        let arguments: [String]
        let timeout: TimeInterval
    }

    private(set) var records: [Record] = []
    var last: Record? { records.last }

    func record(url: URL, arguments: [String], timeout: TimeInterval) {
        records.append(Record(url: url, arguments: arguments, timeout: timeout))
    }
}

/// Answers the HTTP transport from a script, so no test makes a real call.
/// Routes are only ever added, and each test owns its own endpoint, so tests
/// running in parallel cannot cross wires.
private final class HouseHTTPStub: URLProtocol {
    private struct Route: Sendable {
        let status: Int
        let body: Data
        let hangs: Bool
    }

    private static let routes = Mutex<[String: Route]>([:])
    private static let recorded = Mutex<[URLRequest]>([])
    private static let recordedBodies = Mutex<[String: Data]>([:])

    static func serve(_ url: String, status: Int, body: String) {
        routes.withLock { $0[url] = Route(status: status, body: Data(body.utf8), hangs: false) }
    }

    /// Accepts the request and never answers, for the timeout case.
    static func hang(_ url: String) {
        routes.withLock { $0[url] = Route(status: 200, body: Data(), hangs: true) }
    }

    static var requests: [URLRequest] { recorded.withLock { $0 } }

    static var bodies: [String: Data] { recordedBodies.withLock { $0 } }

    static func session(timeout: TimeInterval = 60) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HouseHTTPStub.self]
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        Self.recorded.withLock { $0.append(request) }
        if let url = request.url?.absoluteString {
            let body = request.httpBody ?? Self.bodyStream(of: request)
            Self.recordedBodies.withLock { $0[url] = body }
        }
        let route = Self.routes.withLock { $0[key] }

        guard let route, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if route.hangs { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: route.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLProtocol` hands a body set on the request as a stream.
    private static func bodyStream(of request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}
