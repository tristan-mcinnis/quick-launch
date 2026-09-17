import Foundation
import Testing
@testable import QuickLaunch

/// Runs real system binaries (`/bin/echo`, `/bin/cat`, `/bin/sh` with a
/// script *file*, never `-c`). Nothing here reaches the network.
@Suite("ProcessRunner")
struct ProcessRunnerTests {

    @Test func echoReturnsStdoutAndZeroStatus() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "world"]
        )
        #expect(result.status == 0)
        #expect(result.stdoutText == "hello world\n")
        #expect(result.stderr.isEmpty)
        #expect(result.trimmedStderr == nil)
    }

    @Test func argumentsAreNeverShellInterpolated() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["$HOME; rm -rf /", "`id`", "a && b"]
        )
        #expect(result.stdoutText == "$HOME; rm -rf / `id` a && b\n")
    }

    @Test func largeStdinRoundTripsThroughCat() async throws {
        let payload = Data(repeating: UInt8(ascii: "x"), count: 3 * 1_024 * 1_024)
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            stdin: payload
        )
        #expect(result.status == 0)
        #expect(result.stdout.count == payload.count)
        #expect(result.stdout == payload)
    }

    /// Over 1 MB on stdout AND stderr at the same time. A runner that reads
    /// one pipe to the end before the other, or waits before reading, hangs
    /// here once the unread pipe's 64 KB buffer fills.
    @Test(.timeLimit(.minutes(1)))
    func largeOutputOnBothPipesDoesNotDeadlock() async throws {
        let script = try Self.writeScript("""
        #!/bin/sh
        i=0
        while [ $i -lt 20000 ]; do
          echo "out-line-$i-0123456789012345678901234567890123456789012345678901234567890123456789"
          echo "err-line-$i-0123456789012345678901234567890123456789012345678901234567890123456789" 1>&2
          i=$((i+1))
        done
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path]
        )
        #expect(result.status == 0)
        #expect(result.stdout.count > 1_024 * 1_024)
        #expect(result.stderr.count > 1_024 * 1_024)
        #expect(result.stdoutText.hasPrefix("out-line-0-"))
        #expect(result.stderrText.hasPrefix("err-line-0-"))
        #expect(result.stdoutText.contains("out-line-19999-"))
        #expect(result.stderrText.contains("err-line-19999-"))
    }

    @Test func nonZeroExitIsReportedNotThrown() async throws {
        let script = try Self.writeScript("""
        #!/bin/sh
        echo partial
        echo boom 1>&2
        exit 3
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path]
        )
        #expect(result.status == 3)
        #expect(result.stdoutText == "partial\n")
        #expect(result.trimmedStderr == "boom")
    }

    @Test func missingExecutableThrowsLaunchFailed() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/nonexistent/quick-launch-no-such-binary"),
                arguments: []
            )
        }
    }

    @Test func environmentAndWorkingDirectoryAreHonoured() async throws {
        let script = try Self.writeScript("""
        #!/bin/sh
        printf '%s|%s' "$QL_PROBE" "$(pwd)"
        """)
        defer { try? FileManager.default.removeItem(at: script) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            environment: ["QL_PROBE": "present", "PATH": "/usr/bin:/bin"],
            currentDirectory: directory
        )
        let parts = result.stdoutText.split(separator: "|").map(String.init)
        #expect(parts.first == "present")
        #expect(parts.last.map { $0.hasSuffix(directory.lastPathComponent) } == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutTerminatesTheChild() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 0.3
            )
        }
    }

    @Test func streamYieldsStdoutAndFinishes() async throws {
        let script = try Self.writeScript("""
        #!/bin/sh
        cat
        echo tail
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        var collected = Data()
        let stream = ProcessRunner.stream(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            stdin: Data("head\n".utf8),
            onFailure: { status, _ in ProcessRunnerError.launchFailed(executable: "sh", reason: "\(status)") }
        )
        for try await chunk in stream { collected.append(chunk) }
        #expect(String(decoding: collected, as: UTF8.self) == "head\ntail\n")
    }

    @Test func streamSurfacesFailureWithStderr() async throws {
        let script = try Self.writeScript("""
        #!/bin/sh
        echo nope 1>&2
        exit 7
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        struct Failure: Error, Equatable { let status: Int32; let stderr: String }
        let stream = ProcessRunner.stream(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            onFailure: { status, stderr in
                Failure(status: status, stderr: String(decoding: stderr, as: UTF8.self))
            }
        )
        await #expect(throws: Failure(status: 7, stderr: "nope\n")) {
            for try await _ in stream {}
        }
    }

    // MARK: - SSHRunner argv snapshots

    @Test func sshArgvMatchesTheOriginalBuilders() {
        #expect(SSHRunner.executable.path == "/usr/bin/ssh")

        // WebPageReader / SearXNG shape: single remote command string.
        #expect(
            SSHRunner.arguments(host: "vault-vps", remoteCommand: ["curl -s 'http://x'"]) == [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "vault-vps",
                "curl -s 'http://x'",
            ]
        )

        // VaultSearch shape: -T, then separate argv elements.
        #expect(
            SSHRunner.arguments(
                host: "vault-vps",
                remoteCommand: ["python3", "/remote/vault-search.py", "current", "--stdin", "--limit", "10", "--json"],
                disablePTY: true
            ) == [
                "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "vault-vps",
                "python3", "/remote/vault-search.py", "current",
                "--stdin", "--limit", "10", "--json",
            ]
        )
    }

    @Test func serviceRemoteCommandsArePinned() {
        #expect(
            SSHVaultSearchService.remoteArguments(remoteScript: "/r/vs.py", mode: .current)
                == ["python3", "/r/vs.py", "current", "--stdin", "--limit", "10", "--json"]
        )
        // History declares --project required, so its call carries the slug the
        // server-side scope resolver returned.
        #expect(
            SSHVaultSearchService.remoteArguments(remoteScript: "/r/vs.py", mode: .history, project: "acme-launch")
                == ["python3", "/r/vs.py", "history", "--stdin", "--limit", "10", "--json", "--project", "acme-launch"]
        )
        #expect(
            WebPageReader.remoteCommand(for: URL(string: "https://a.example/p?q=it's")!)
                == ["~/search-tools/venv/bin/python ~/search-tools/read_page.py 'https://a.example/p?q=it%27s'"]
        )
        #expect(
            SearXNGSearchService.remoteCommand(for: URL(string: "http://127.0.0.1:8888/search?q=a'b")!)
                == ["curl -s --max-time 6 'http://127.0.0.1:8888/search?q=a%27b'"]
        )
    }

    // MARK: - Helpers

    /// Writes an executable script to a temp file. It is run as
    /// `/bin/sh <path>`: the path is a plain argument, never `-c` text.
    private static func writeScript(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-runner-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
