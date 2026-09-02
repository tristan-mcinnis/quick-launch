import Foundation

/// Everything a finished child process left behind.
struct ProcessResult: Sendable, Equatable {
    let stdout: Data
    let stderr: Data
    let status: Int32

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }

    /// Trimmed stderr, or nil when the process wrote nothing there.
    var trimmedStderr: String? {
        let text = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

enum ProcessRunnerError: LocalizedError, Equatable {
    case launchFailed(executable: String, reason: String)
    case timedOut(executable: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let reason):
            "Could not start \(executable): \(reason)"
        case .timedOut(let executable, let seconds):
            "\(executable) did not finish within \(Int(seconds)) seconds"
        }
    }
}

/// The one way Quick Launch runs external programs. Always a direct
/// `argv` launch: no shell, no string interpolation, user text can only ever
/// be a single argument or stdin. Both output pipes are drained on
/// background queues while the process runs, so large output on either side
/// never deadlocks, and nothing here touches the main actor.
enum ProcessRunner {

    /// Runs `executable` to completion and returns everything it produced.
    ///
    /// - `environment`: nil inherits the parent environment.
    /// - `stdin`: bytes to feed the process; nil connects `/dev/null`.
    /// - `currentDirectory`: nil inherits the parent's working directory.
    /// - `timeout`: seconds before the process is terminated and
    ///   ``ProcessRunnerError/timedOut`` is thrown.
    ///
    /// Task cancellation terminates the child and rethrows as
    /// `CancellationError`.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        let box = ProcessBox(configure(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory
        ))
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe: Pipe? = stdin == nil ? nil : Pipe()
        box.process.standardOutput = stdoutPipe
        box.process.standardError = stderrPipe
        box.process.standardInput = stdinPipe ?? FileHandle.nullDevice

        let result: ProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let queue = DispatchQueue.global(qos: .userInitiated)
                let group = DispatchGroup()
                let collector = OutputCollector()
                let timedOut = TimeoutFlag()

                // Termination must be wired before run() so a process that
                // exits instantly is never missed.
                group.enter()
                box.process.terminationHandler = { _ in group.leave() }

                do {
                    try box.process.run()
                } catch {
                    box.process.terminationHandler = nil
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(
                        executable: executable.lastPathComponent,
                        reason: error.localizedDescription
                    ))
                    return
                }

                // Drain both pipes concurrently, before waiting on exit.
                group.enter()
                queue.async {
                    collector.stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                queue.async {
                    collector.stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                if let stdin, let stdinPipe {
                    queue.async {
                        // A closed read end (child exited early) raises
                        // SIGPIPE-free EPIPE via the FileHandle API; ignore.
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                        try? stdinPipe.fileHandleForWriting.close()
                    }
                }

                var timer: DispatchWorkItem?
                if let timeout {
                    let item = DispatchWorkItem {
                        timedOut.fired = true
                        if box.process.isRunning { box.process.terminate() }
                    }
                    timer = item
                    queue.asyncAfter(deadline: .now() + timeout, execute: item)
                }

                group.notify(queue: queue) {
                    timer?.cancel()
                    if timedOut.fired, let timeout {
                        continuation.resume(throwing: ProcessRunnerError.timedOut(
                            executable: executable.lastPathComponent,
                            seconds: timeout
                        ))
                        return
                    }
                    continuation.resume(returning: ProcessResult(
                        stdout: collector.stdout,
                        stderr: collector.stderr,
                        status: box.process.terminationStatus
                    ))
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
        try Task.checkCancellation()
        return result
    }

    /// Streams stdout as it arrives. stderr is collected in the background;
    /// a non-zero exit finishes the stream with `onFailure(status, stderr)`.
    /// Cancelling the consuming task terminates the child.
    static func stream(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdin: Data? = nil,
        currentDirectory: URL? = nil,
        onFailure: @escaping @Sendable (Int32, Data) -> Error
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let box = ProcessBox(configure(
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory
            ))
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let stdinPipe: Pipe? = stdin == nil ? nil : Pipe()
            box.process.standardOutput = stdoutPipe
            box.process.standardError = stderrPipe
            box.process.standardInput = stdinPipe ?? FileHandle.nullDevice

            let queue = DispatchQueue.global(qos: .userInitiated)
            let group = DispatchGroup()
            let collector = OutputCollector()

            group.enter()
            box.process.terminationHandler = { _ in group.leave() }

            do {
                try box.process.run()
            } catch {
                box.process.terminationHandler = nil
                continuation.finish(throwing: ProcessRunnerError.launchFailed(
                    executable: executable.lastPathComponent,
                    reason: error.localizedDescription
                ))
                return
            }

            continuation.onTermination = { _ in
                if box.process.isRunning { box.process.terminate() }
            }

            group.enter()
            queue.async {
                let handle = stdoutPipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    continuation.yield(chunk)
                }
                group.leave()
            }
            group.enter()
            queue.async {
                collector.stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            if let stdin, let stdinPipe {
                queue.async {
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                    try? stdinPipe.fileHandleForWriting.close()
                }
            }

            group.notify(queue: queue) {
                let status = box.process.terminationStatus
                if status == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: onFailure(status, collector.stderr))
                }
            }
        }
    }

    /// Fire-and-forget launch for tools that own their own UI lifetime
    /// (Quick Look previews and the like). Output is discarded.
    @discardableResult
    static func launch(executable: URL, arguments: [String]) -> Bool {
        let process = configure(
            executable: executable,
            arguments: arguments,
            environment: nil,
            currentDirectory: nil
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Internals

    private static func configure(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectory: URL?
    ) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        return process
    }

    /// `Process` is not Sendable; every access after `run()` is either on a
    /// dispatch queue or a cancellation handler, and Process is documented
    /// thread-safe for `isRunning`, `terminate()` and `terminationStatus`.
    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }

    /// Written by exactly one queue block each, read only after the group
    /// has joined all of them.
    private final class OutputCollector: @unchecked Sendable {
        var stdout = Data()
        var stderr = Data()
    }

    private final class TimeoutFlag: @unchecked Sendable {
        var fired = false
    }
}

/// Builds the `ssh` argv Quick Launch uses to reach vault-vps. One place
/// for the batch-mode options so every remote lane behaves the same.
enum SSHRunner {
    static let executable = URL(fileURLWithPath: "/usr/bin/ssh")
    static let connectTimeoutSeconds = 5

    /// - `remoteCommand`: passed through as separate argv elements after the
    ///   host. ssh joins them with spaces on the remote side, so a caller
    ///   that needs quoting must quote each element itself.
    /// - `disablePTY`: adds `-T`, for commands that read stdin.
    static func arguments(
        host: String,
        remoteCommand: [String],
        disablePTY: Bool = false
    ) -> [String] {
        var argv: [String] = []
        if disablePTY { argv.append("-T") }
        argv += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeoutSeconds)", host]
        argv += remoteCommand
        return argv
    }

    static func run(
        host: String,
        remoteCommand: [String],
        disablePTY: Bool = false,
        stdin: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: executable,
            arguments: arguments(host: host, remoteCommand: remoteCommand, disablePTY: disablePTY),
            stdin: stdin,
            timeout: timeout
        )
    }
}
