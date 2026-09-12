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

    func write(_ name: String, _ contents: String) {
        try? contents.write(
            to: url.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    var directory: HouseCommandDirectory { HouseCommandDirectory(root: url) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

private let rtiManifest = """
{
  "schema": 1,
  "app": "rti",
  "name": "RTI",
  "transport": "socket",
  "endpoint": "~/.config/rti/control.sock",
  "status": "status",
  "commands": [
    {"id": "record.start", "title": "Start Recording", "verb": "start",
     "needs": null, "unavailableWhen": "recording"},
    {"id": "record.stop", "title": "Stop Recording", "verb": "stop",
     "needs": null, "unavailableWhen": "!recording"}
  ]
}
"""

private let memoryManifest = """
{
  "schema": 1,
  "app": "memory",
  "name": "Memory",
  "transport": "exec",
  "endpoint": "/usr/local/bin/recall",
  "commands": [
    {"id": "remember", "title": "Capture a Thought", "verb": "remember", "needs": "text"}
  ]
}
"""

private let modelsManifest = """
{
  "schema": 1,
  "app": "local-models",
  "name": "Local Models",
  "transport": "http",
  "endpoint": "http://127.0.0.1:8078",
  "status": "status",
  "commands": [
    {"id": "warm", "title": "Warm a Model", "verb": "warm", "needs": "choice",
     "choices": ["gemma-4", "qwen-3"]},
    {"id": "unload", "title": "Unload Every Model", "verb": "unload"}
  ]
}
"""

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
    private var failure: HouseCommandError?

    init(
        statuses: [String: HouseCommandStatus?] = [:],
        statusFailures: Set<String> = [],
        failure: HouseCommandError? = nil
    ) {
        self.statuses = statuses
        self.statusFailures = statusFailures
        self.failure = failure
    }

    func run(
        _ command: HouseCommand,
        argument: String?,
        in manifest: HouseCommandManifest
    ) async throws -> String {
        runs.append(Run(app: manifest.app, verb: command.verb, argument: argument))
        if let failure { throw failure }
        return "ok"
    }

    func status(for manifest: HouseCommandManifest) async throws -> HouseCommandStatus? {
        statusReads.append(manifest.app)
        if statusFailures.contains(manifest.app) {
            throw HouseCommandError.unreachable(app: manifest.name)
        }
        return statuses[manifest.app] ?? nil
    }

    func recordedRuns() -> [Run] { runs }
    func recordedStatusReads() -> [String] { statusReads }
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

    @Test func expandsATildeEndpointAgainstTheHome() throws {
        let manifest = try #require(HouseCommandManifest.parse(Data(rtiManifest.utf8)))
        #expect(!manifest.endpoint.hasPrefix("~"))
        #expect(manifest.endpoint.hasSuffix("/.config/rti/control.sock"))
        #expect(manifest.endpoint.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test func malformedAndUnknownSchemaManifestsOfferNothing() {
        // Not JSON at all.
        #expect(HouseCommandManifest.parse(Data("this is not json".utf8)) == nil)
        // JSON, but not an object.
        #expect(HouseCommandManifest.parse(Data("[1, 2, 3]".utf8)) == nil)
        // Truncated mid-object.
        #expect(HouseCommandManifest.parse(Data(#"{"schema": 1, "app": "rti""#.utf8)) == nil)
        // Empty file.
        #expect(HouseCommandManifest.parse(Data()) == nil)
        // A schema from a later version of the contract: the shape is
        // unknown, so none of it is read.
        #expect(HouseCommandManifest.parse(Data(#"{"schema": 2, "app": "rti", "name": "RTI", "transport": "socket", "endpoint": "/tmp/x.sock", "commands": []}"#.utf8)) == nil)
        // No schema at all.
        #expect(HouseCommandManifest.parse(Data(#"{"app": "rti", "transport": "socket", "endpoint": "/tmp/x.sock"}"#.utf8)) == nil)
        // A transport this build does not speak.
        #expect(HouseCommandManifest.parse(Data(#"{"schema": 1, "app": "x", "transport": "carrier-pigeon", "endpoint": "/tmp/x"}"#.utf8)) == nil)
        // Missing endpoint.
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
           {"id": "choice-without-choices", "title": "Pick", "verb": "go", "needs": "choice"}
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
        // A string is not a flag.
        #expect(parsed.flags["app"] == nil)
        #expect(HouseCommandStatus.parse("not json") == nil)
        #expect(HouseCommandStatus.parse("") == nil)
    }

    @Test func unavailableWhenReadsBothWaysAndNeverGuesses() throws {
        let manifest = try #require(HouseCommandManifest.parse(Data(rtiManifest.utf8)))
        let start = manifest.commands[0]
        let stop = manifest.commands[1]

        // Idle: Start is offered, Stop is not.
        let idle = status(["recording": false])
        #expect(start.isAvailable(given: idle))
        #expect(!stop.isAvailable(given: idle))

        // Recording: the other way round.
        let recording = status(["recording": true])
        #expect(!start.isAvailable(given: recording))
        #expect(stop.isAvailable(given: recording))

        // No status at all, and a status without the field: neither row is
        // offered, because the launcher never guesses.
        #expect(!start.isAvailable(given: nil))
        #expect(!stop.isAvailable(given: nil))
        #expect(!start.isAvailable(given: status(["ok": true])))
    }

    @Test func aCommandWithNoConditionIsAlwaysOffered() throws {
        let manifest = try #require(HouseCommandManifest.parse(Data(memoryManifest.utf8)))
        #expect(manifest.commands[0].isAvailable(given: nil))
        #expect(!manifest.needsStatus, "nothing it publishes is gated on a status")
    }
}

// MARK: - The manifest folder

@Suite("House command directory")
struct HouseCommandDirectoryTests {

    @Test func readsEveryManifestAndSkipsTheRest() {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        folder.write("memory.json", memoryManifest)
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

    @Test func socketSendsOneLineAndReadsOneLine() async throws {
        let manifest = try manifest(rtiManifest)
        let sent = Sent()
        let dispatcher = HouseCommandDispatcher(
            sendLine: { url, line, timeout in
                await sent.record(url: url, line: line, timeout: timeout)
                return "ok"
            }
        )
        let reply = try await dispatcher.run(manifest.commands[0], argument: nil, in: manifest)
        #expect(reply == "ok")
        let record = await sent.last
        #expect(record?.line == "start")
        #expect(record?.url.path == manifest.endpoint)
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

    @Test func socketErrorReplyBecomesTheMessageTheUserSees() async throws {
        let manifest = try manifest(rtiManifest)
        let dispatcher = HouseCommandDispatcher(sendLine: { _, _, _ in "error unknown verb" })
        await #expect(throws: HouseCommandError.refused(app: "RTI", message: "unknown verb")) {
            try await dispatcher.run(manifest.commands[0], argument: nil, in: manifest)
        }
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

    @Test func httpPostsTheRouteAndGetsTheStatus() async throws {
        let host = "http://127.0.0.1:8101"
        let manifest = try manifest(modelsManifest.replacingOccurrences(
            of: "http://127.0.0.1:8078",
            with: host
        ))
        HouseHTTPStub.serve(host + "/warm", status: 200, body: "ok")
        HouseHTTPStub.serve(
            host + "/status",
            status: 200,
            body: #"{"app": "local-models", "ok": true, "busy": false, "detail": "2 warm"}"#
        )
        let dispatcher = HouseCommandDispatcher(session: HouseHTTPStub.session())

        let reply = try await dispatcher.run(manifest.commands[0], argument: "gemma-4", in: manifest)
        #expect(reply == "ok")
        let posted = try #require(HouseHTTPStub.requests.first { $0.url?.absoluteString == host + "/warm" })
        #expect(posted.httpMethod == "POST")
        let body = try #require(HouseHTTPStub.bodies[host + "/warm"])
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(decoded?["argument"] == "gemma-4")

        let status = try await dispatcher.status(for: manifest)
        #expect(status?.detail == "2 warm")
        let read = try #require(HouseHTTPStub.requests.first { $0.url?.absoluteString == host + "/status" })
        #expect(read.httpMethod == "GET")
    }

    @Test func httpFailuresBecomeSentencesTheUserCanRead() async throws {
        let host = "http://127.0.0.1:8102"
        let manifest = try manifest(modelsManifest.replacingOccurrences(
            of: "http://127.0.0.1:8078",
            with: host
        ))
        HouseHTTPStub.serve(host + "/unload", status: 500, body: "no model loaded")
        let dispatcher = HouseCommandDispatcher(session: HouseHTTPStub.session())
        await #expect(throws: HouseCommandError.refused(app: "Local Models", message: "no model loaded")) {
            try await dispatcher.run(manifest.commands[1], argument: nil, in: manifest)
        }
    }

    @Test func aDaemonThatIsNotRunningIsUnreachable() async throws {
        // Nothing is ever served on this port, so the request cannot connect.
        let manifest = try manifest(modelsManifest.replacingOccurrences(
            of: "http://127.0.0.1:8078",
            with: "http://127.0.0.1:8103"
        ))
        let dead = HouseCommandDispatcher(session: HouseHTTPStub.session())
        await #expect(throws: HouseCommandError.unreachable(app: "Local Models")) {
            try await dead.run(manifest.commands[1], argument: nil, in: manifest)
        }
    }

    @Test func execRunsADirectArgvLaunchAndNeverAShell() async throws {
        let manifest = try manifest(memoryManifest)
        let launched = Launched()
        let dispatcher = HouseCommandDispatcher(
            runProcess: { url, arguments, timeout in
                await launched.record(url: url, arguments: arguments, timeout: timeout)
                return ProcessResult(stdout: Data("saved".utf8), stderr: Data(), status: 0)
            },
            resolveExecutable: { URL(fileURLWithPath: $0) }
        )
        let reply = try await dispatcher.run(
            manifest.commands[0],
            argument: "buy milk; rm -rf /",
            in: manifest
        )
        #expect(reply == "saved")
        let record = await launched.last
        #expect(record?.url.path == "/usr/local/bin/recall")
        #expect(
            record?.arguments == ["remember", "buy milk; rm -rf /"],
            "user text is one argument, never shell syntax"
        )
    }

    @Test func anAppThatIsNotInstalledSaysSoRatherThanFailing() async throws {
        let manifest = try manifest(memoryManifest)
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
        let manifest = try manifest(memoryManifest)
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
        let manifest = try manifest(memoryManifest)
        let dispatcher = HouseCommandDispatcher(
            runProcess: { _, _, _ in
                throw ProcessRunnerError.timedOut(executable: "recall", seconds: 3)
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
        #expect(rows.count == 1, "only Start Recording is available while idle")
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

    @Test func aDeadAppOffersNothingAndNeverThrows() async {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let catalog = HouseCommandCatalog(
            directory: folder.directory,
            dispatcher: FakeDispatcher(statusFailures: ["rti"])
        )
        // Both RTI rows are gated on a status nobody answered, so neither is
        // offered. Nothing is thrown to the launcher.
        #expect(await catalog.refresh().isEmpty)
    }

    @Test func anAppWithNoStatusIsNeverProbedAndStillOffersItsCommands() async {
        let folder = FixtureFolder()
        folder.write("memory.json", memoryManifest)
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

    @Test func runningACommandDispatchesItAndDropsTheStaleStatus() async throws {
        let folder = FixtureFolder()
        folder.write("rti.json", rtiManifest)
        let dispatcher = FakeDispatcher(statuses: ["rti": status(["recording": false])])
        let catalog = HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)

        let rows = await catalog.refresh()
        _ = try await catalog.run(rows[0], argument: nil)
        #expect(await dispatcher.recordedRuns() == [FakeDispatcher.Run(app: "rti", verb: "start", argument: nil)])

        // The run changed what the app is doing, so the next refresh reads
        // the status again rather than trusting the cache.
        _ = await catalog.refresh()
        #expect(await dispatcher.recordedStatusReads() == ["rti", "rti"])
    }

    @Test func aChoiceValueSplitsBackIntoTheCommandAndTheOption() {
        let value = HouseCommandCatalog.choiceValue(rowID: "house.local-models.warm", choice: "gemma-4")
        #expect(value == "house.local-models.warm#gemma-4")
        let parsed = HouseCommandCatalog.choice(inValue: value)
        #expect(parsed?.rowID == "house.local-models.warm")
        #expect(parsed?.choice == "gemma-4")
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

        let item = vm.houseCommandItems[0]
        await vm.performHouseCommand(item)
        await vm.waitForHouseCommandRefreshForTesting()

        #expect(await dispatcher.recordedRuns() == [FakeDispatcher.Run(app: "rti", verb: "start", argument: nil)])
        #expect(vm.errorMessage == nil)
        #expect(presenter.dismissals == 1, "a plain ok closes the launcher")
    }

    @Test func aTextCommandAsksForItsArgumentWithTheExistingPrompt() async {
        let folder = FixtureFolder()
        folder.write("memory.json", memoryManifest)
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
            FakeDispatcher.Run(app: "memory", verb: "remember", argument: "the roof needs fixing")
        ])
        #expect(vm.inputMode == nil)
    }

    @Test func aChoiceCommandOffersItsChoicesAsRows() async throws {
        let folder = FixtureFolder()
        folder.write("models.json", modelsManifest)
        let dispatcher = FakeDispatcher(statuses: ["local-models": status(["ok": true])])
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        )
        vm.overlayPresenter = RecordingPresenter()
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()

        let warm = try #require(vm.houseCommandItems.first { $0.title == "Warm a Model" })
        await vm.performHouseCommand(warm)

        #expect(vm.pendingHouseChoice != nil)
        #expect(vm.topLayer == .houseCommandChoice)
        let choices = vm.launcherMatches.compactMap { result -> String? in
            guard case .item(let item) = result else { return nil }
            return item.title
        }
        #expect(choices == ["gemma-4", "qwen-3"])

        // Typing narrows the list, as it does in any catalog.
        vm.input = "qwen"
        let narrowed = vm.launcherMatches.compactMap { result -> String? in
            guard case .item(let item) = result else { return nil }
            return item.title
        }
        #expect(narrowed == ["qwen-3"])

        vm.input = ""
        guard case .item(let picked)? = vm.launcherMatches.last else {
            Issue.record("no choice row")
            return
        }
        await vm.performHouseCommand(picked)
        await vm.waitForHouseCommandRefreshForTesting()

        #expect(await dispatcher.recordedRuns() == [
            FakeDispatcher.Run(app: "local-models", verb: "warm", argument: "qwen-3")
        ])
        #expect(vm.pendingHouseChoice == nil)
    }

    @Test func backspaceLeavesAChoiceListWithoutRunningAnything() async {
        let folder = FixtureFolder()
        folder.write("models.json", modelsManifest)
        let dispatcher = FakeDispatcher(statuses: ["local-models": status(["ok": true])])
        let vm = QuickViewModel(
            service: MockQuickService(),
            houseCommandCatalog: HouseCommandCatalog(directory: folder.directory, dispatcher: dispatcher)
        )
        vm.overlayPresenter = RecordingPresenter()
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()

        await vm.performHouseCommand(vm.houseCommandItems.first { $0.title == "Warm a Model" }!)
        #expect(vm.topLayer == .houseCommandChoice)
        #expect(vm.popLayerForEmptyBackspace())
        #expect(vm.pendingHouseChoice == nil)
        #expect(vm.topLayer == .root)
        #expect(await dispatcher.recordedRuns().isEmpty)
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
private final class HouseHTTPStub: URLProtocol {
    private struct Route: Sendable {
        let status: Int
        let body: Data
    }

    private static let routes = Mutex<[String: Route]>([:])
    private static let recorded = Mutex<[URLRequest]>([])
    private static let recordedBodies = Mutex<[String: Data]>([:])

    static func serve(_ url: String, status: Int, body: String) {
        routes.withLock { $0[url] = Route(status: status, body: Data(body.utf8)) }
    }

    static var requests: [URLRequest] { recorded.withLock { $0 } }

    static var bodies: [String: Data] { recordedBodies.withLock { $0 } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HouseHTTPStub.self]
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
