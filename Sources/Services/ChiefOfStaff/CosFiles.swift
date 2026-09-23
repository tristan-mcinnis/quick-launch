import Foundation
import HouseChatCore

/// Where the `cos` organ keeps its files, and where its CLI is installed.
/// Every path comes from the home directory; `COS_HOME` moves the data
/// directory and `COS_BIN` names another CLI, exactly as for `cos` itself.
struct CosPaths: Sendable, Equatable {
    /// `~/.local/share/chief-of-staff`
    var data: URL
    /// `~/.local/bin/cos`
    var executable: URL

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CosPaths {
        let data = environment["COS_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".local/share/chief-of-staff", directoryHint: .isDirectory)
        let executable = environment["COS_BIN"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".local/bin/cos", directoryHint: .notDirectory)
        return CosPaths(data: data, executable: executable)
    }

    /// The one thread, a HouseChatCore `ConversationRecord`.
    var thread: URL { data.appending(path: "thread/chief-of-staff.json") }
    /// Present while the kill switch is on (`cos pause`).
    var pauseFlag: URL { data.appending(path: "PAUSED") }
    /// Touched every 30 s while Quick Launch runs; `cos` then leaves its
    /// own banners to Quick Launch.
    var alive: URL { data.appending(path: "app.alive") }
}

/// Quick Launch's only file reads of the `cos` organ and its one write: the
/// thread (read when it changed), the pause flag, and the liveness file
/// (touched). An actor, so no file I/O runs on the main actor.
actor CosFiles {
    enum ThreadRead: Sendable {
        case unchanged
        case missing
        case record(ConversationRecord)
        case unreadable(String)
    }

    private struct Stamp: Equatable {
        var modified: Date
        var size: Int
    }

    let paths: CosPaths
    private var lastStamp: Stamp?
    private var lastWasMissing = false

    init(paths: CosPaths) {
        self.paths = paths
    }

    /// Read and decode the thread only when its modification time or size
    /// moved since the last call, so a 2 s poll costs one `stat`.
    func readThreadIfChanged(force: Bool = false) -> ThreadRead {
        let url = paths.thread
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)) else {
            defer { lastStamp = nil; lastWasMissing = true }
            return lastWasMissing && !force ? .unchanged : .missing
        }
        lastWasMissing = false
        let stamp = Stamp(
            modified: attributes[.modificationDate] as? Date ?? .distantPast,
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0
        )
        if !force, stamp == lastStamp { return .unchanged }
        do {
            let record = try ChiefOfStaffThread.decode(Data(contentsOf: url))
            lastStamp = stamp
            return .record(record)
        } catch {
            // Unset, so the next poll tries again: a half replaced file
            // reads fine a moment later.
            lastStamp = nil
            return .unreadable(String(describing: error))
        }
    }

    func isPaused() -> Bool {
        FileManager.default.fileExists(atPath: paths.pauseFlag.path(percentEncoded: false))
    }

    /// Whether the CLI is installed, so a Mac without it shows no row.
    func cliExists() -> Bool {
        FileManager.default.isExecutableFile(atPath: paths.executable.path(percentEncoded: false))
    }

    /// Mark Quick Launch alive: `cos` leaves notifications to it while this
    /// file is younger than two minutes.
    func touchAlive(now: Date = .now) {
        let url = paths.alive
        let path = url.path(percentEncoded: false)
        let manager = FileManager.default
        if manager.fileExists(atPath: path) {
            try? manager.setAttributes([.modificationDate: now], ofItemAtPath: path)
        } else {
            try? manager.createDirectory(at: paths.data, withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
    }
}

/// Runs the `cos` CLI through `ProcessRunner`: an executable path and an
/// argument array, no shell, a bounded run time, never on the main actor.
protocol CosRunning: Sendable {
    func run(_ command: CosCommand) async throws -> CosResult
}

struct CosCLI: CosRunning {
    let executable: URL
    /// Nil inherits Quick Launch's; a test sets `COS_HOME`.
    var environment: [String: String]? = nil

    func run(_ command: CosCommand) async throws -> CosResult {
        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: try command.arguments(),
            environment: environment,
            stdin: command.stdin,
            timeout: command.timeout
        )
        return CosResult(exitCode: result.status, stdout: result.stdoutText, stderr: result.stderrText)
    }
}
