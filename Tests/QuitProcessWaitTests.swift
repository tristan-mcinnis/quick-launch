import Foundation
import Testing

/// The installer's bounded quit wait. It never signals the app: a process
/// that is still there refuses the replacement. These tests use fake
/// predicates and temp files; nothing here touches /Applications, pgrep, or
/// the real app.
///
/// Predicate contract: 0 = still running, 1 = confirmed gone, anything else
/// (2, 3, 126, 127, a signal) fails closed. Helper exit: 0 gone, 1 still
/// running, 2 refused for a usage, predicate, poll, or sleep error.
@Suite("Installer quit wait")
struct QuitProcessWaitTests {
    private func scriptURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/wait-for-exit.sh")
    }

    private struct Run {
        var status: Int32
        var output: String
    }

    private func run(_ arguments: [String], environment: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL().path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quit-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func returnsAsSoonAsTheProcessIsGone() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = directory.appendingPathComponent("count")
        try "0".write(to: counter, atomically: true, encoding: .utf8)
        let predicate = directory.appendingPathComponent("predicate.sh")
        try writeExecutable("""
        #!/bin/sh
        n=$(cat "\(counter.path)")
        echo $((n+1)) > "\(counter.path)"
        if [ "$n" -lt 2 ]; then exit 0; fi
        exit 1
        """, to: predicate)

        let result = try run(
            ["3", predicate.path],
            environment: ["QUIT_WAIT_POLL_SECONDS": "0.02"]
        )

        #expect(result.status == 0, Comment(rawValue: result.output))
        #expect(try String(contentsOf: counter, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "3")
    }

    @Test func refusesWhenTheProcessStays() throws {
        let result = try run(
            ["2", "/usr/bin/true"],
            environment: ["QUIT_WAIT_POLL_SECONDS": "0.02"]
        )
        #expect(result.status == 1, Comment(rawValue: result.output))
    }

    @Test func oneCheckConfirmsGone() throws {
        let result = try run(
            ["1", "/usr/bin/false"],
            environment: ["QUIT_WAIT_POLL_SECONDS": "0.02"]
        )
        #expect(result.status == 0, Comment(rawValue: result.output))
    }

    @Test func oneCheckStillRunning() throws {
        let result = try run(
            ["1", "/usr/bin/true"],
            environment: ["QUIT_WAIT_POLL_SECONDS": "0.02"]
        )
        #expect(result.status == 1, Comment(rawValue: result.output))
    }

    /// Any predicate status other than 0 or 1 is unknown, not "gone".
    @Test func failsClosedOnAPredicateError() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let predicate = directory.appendingPathComponent("error.sh")
        try writeExecutable("#!/bin/sh\nexit 2\n", to: predicate)

        let result = try run(
            ["1", predicate.path],
            environment: ["QUIT_WAIT_POLL_SECONDS": "0.02"]
        )
        #expect(result.status == 2, Comment(rawValue: result.output))
    }

    @Test func failsClosedOnAMidWaitPredicateError() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = directory.appendingPathComponent("count")
        try "0".write(to: counter, atomically: true, encoding: .utf8)
        let predicate = directory.appendingPathComponent("mid-error.sh")
        try writeExecutable("""
        #!/bin/sh
        n=$(cat "\(counter.path)")
        echo $((n+1)) > "\(counter.path)"
        if [ "$n" -lt 1 ]; then exit 0; fi
        exit 3
        """, to: predicate)

        let result = try run(
            ["3", predicate.path],
            environment: ["QUIT_WAIT_POLL_SECONDS": "0.02"]
        )
        #expect(result.status == 2, Comment(rawValue: result.output))
        #expect(try String(contentsOf: counter, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    /// An error on the last allowed attempt is still a refusal, not a timeout.
    @Test func failsClosedOnALastAttemptError() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = directory.appendingPathComponent("count")
        try "0".write(to: counter, atomically: true, encoding: .utf8)
        let predicate = directory.appendingPathComponent("last-error.sh")
        try writeExecutable("""
        #!/bin/sh
        n=$(cat "\(counter.path)")
        echo $((n+1)) > "\(counter.path)"
        if [ "$n" -lt 1 ]; then exit 0; fi
        exit 2
        """, to: predicate)

        let result = try run(
            ["2", predicate.path],
            environment: ["QUIT_WAIT_POLL_SECONDS": "0.02"]
        )
        #expect(result.status == 2, Comment(rawValue: result.output))
    }

    @Test func failsClosedWhenTheExecutableIsMissing() throws {
        let result = try run(
            ["1", "/nonexistent/quit-wait-\(UUID().uuidString)"],
            environment: ["QUIT_WAIT_POLL_SECONDS": "0.02"]
        )
        #expect(result.status == 2, Comment(rawValue: result.output))
    }

    @Test func failsClosedWhenTheExecutableIsNotRunnable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try run(
            ["1", directory.path],
            environment: ["QUIT_WAIT_POLL_SECONDS": "0.02"]
        )
        #expect(result.status == 2, Comment(rawValue: result.output))
    }

    @Test(arguments: ["", "0", "0.0", "abc", "-1", "1.2.3", ".5", "1."])
    func failsClosedOnAnInvalidPoll(_ poll: String) throws {
        let result = try run(
            ["1", "/usr/bin/false"],
            environment: ["QUIT_WAIT_POLL_SECONDS": poll]
        )
        #expect(result.status == 2, Comment(rawValue: "poll: \(poll)"))
    }

    @Test func failsClosedWhenSleepFails() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sleep = directory.appendingPathComponent("sleep")
        try writeExecutable("#!/bin/sh\nexit 1\n", to: sleep)

        let result = try run(
            ["2", "/usr/bin/true"],
            environment: [
                "QUIT_WAIT_POLL_SECONDS": "0.02",
                "PATH": "\(directory.path):/usr/bin:/bin",
            ]
        )
        #expect(result.status == 2, Comment(rawValue: result.output))
    }

    @Test(arguments: ["many", "0", "000", "-1"])
    func failsClosedOnMalformedAttempts(_ attempts: String) throws {
        let result = try run(
            [attempts, "/usr/bin/false"],
            environment: ["QUIT_WAIT_POLL_SECONDS": "0.02"]
        )
        #expect(result.status == 2, Comment(rawValue: "attempts: \(attempts)"))
    }

    @Test func refusesMissingArguments() throws {
        let noArguments = try run([])
        #expect(noArguments.status == 2, Comment(rawValue: noArguments.output))

        let noPredicate = try run(["1"])
        #expect(noPredicate.status == 2, Comment(rawValue: noPredicate.output))
    }
}
