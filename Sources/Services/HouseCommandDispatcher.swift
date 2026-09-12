import Foundation

/// Runs one house command, and reads one app's status, over whichever of the
/// three transports its manifest declares.
///
/// Every outward lane is injected, so a test drives all three without
/// opening a socket, making an HTTP call, or starting a process:
/// `sendLine` for `socket`, `session` for `http` (a `URLProtocol` stub),
/// and `runProcess` plus `resolveExecutable` for `exec`.
protocol HouseCommandDispatching: Sendable {
    /// Runs `command`, with its one argument when it takes one. Returns the
    /// app's own reply text, which may be empty.
    @discardableResult
    func run(
        _ command: HouseCommand,
        argument: String?,
        in manifest: HouseCommandManifest
    ) async throws -> String

    /// Reads the app's status document, or `nil` when the app publishes no
    /// status verb. Throws when the app should have answered and did not.
    func status(for manifest: HouseCommandManifest) async throws -> HouseCommandStatus?
}

actor HouseCommandDispatcher: HouseCommandDispatching {
    /// The contract's own ceiling: a command never blocks longer than a
    /// second, so work that takes longer starts and returns. A little
    /// headroom above that, and no more.
    static let runTimeout: TimeInterval = 3
    /// A status read sits on the launcher's path, so it is cheap or it is
    /// nothing.
    static let statusTimeout: TimeInterval = 1

    private let sendLine: HouseSocketSending
    private let session: URLSession
    private let runProcess: ProcessRunning
    private let resolveExecutable: @Sendable (String) -> URL?

    init(
        sendLine: @escaping HouseSocketSending = UnixSocketLineClient.live,
        session: URLSession = .shared,
        runProcess: @escaping ProcessRunning = ProcessRunner.live,
        resolveExecutable: @escaping @Sendable (String) -> URL? = { ExecutableResolver.resolve($0) }
    ) {
        self.sendLine = sendLine
        self.session = session
        self.runProcess = runProcess
        self.resolveExecutable = resolveExecutable
    }

    @discardableResult
    func run(
        _ command: HouseCommand,
        argument: String?,
        in manifest: HouseCommandManifest
    ) async throws -> String {
        let trimmed = argument?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        switch manifest.transport {
        case .socket:
            return try await socketExchange(
                verb: command.verb,
                argument: value,
                manifest: manifest,
                timeout: Self.runTimeout
            )
        case .http:
            return try await httpRequest(
                route: command.verb,
                method: "POST",
                argument: value,
                manifest: manifest,
                timeout: Self.runTimeout
            )
        case .exec:
            return try await execute(
                verb: command.verb,
                argument: value,
                manifest: manifest,
                timeout: Self.runTimeout
            )
        }
    }

    func status(for manifest: HouseCommandManifest) async throws -> HouseCommandStatus? {
        guard let verb = manifest.status else { return nil }
        let line: String
        switch manifest.transport {
        case .socket:
            line = try await socketExchange(
                verb: verb,
                argument: nil,
                manifest: manifest,
                timeout: Self.statusTimeout
            )
        case .http:
            // A status read is a read: the command lane posts, this gets.
            line = try await httpRequest(
                route: verb,
                method: "GET",
                argument: nil,
                manifest: manifest,
                timeout: Self.statusTimeout
            )
        case .exec:
            line = try await execute(
                verb: verb,
                argument: nil,
                manifest: manifest,
                timeout: Self.statusTimeout
            )
        }
        return HouseCommandStatus.parse(line)
    }

    // MARK: - Transports

    /// One line out, one line back. `error …` is the contract's refusal,
    /// including `error unknown verb`, and is reported as the app's words.
    private func socketExchange(
        verb: String,
        argument: String?,
        manifest: HouseCommandManifest,
        timeout: TimeInterval
    ) async throws -> String {
        // A word, then optional argument text after a single space. A
        // newline inside the argument would end the request early, so it
        // becomes a space: one request is always one line.
        let line = argument.map { "\(verb) \(Self.oneLine($0))" } ?? verb
        let reply: String
        do {
            reply = try await sendLine(manifest.endpointURL, line, timeout)
        } catch UnixSocketLineClient.Failure.timedOut {
            throw HouseCommandError.timedOut(app: manifest.name)
        } catch {
            throw HouseCommandError.unreachable(app: manifest.name)
        }
        if reply.hasPrefix("error") {
            let message = reply.dropFirst("error".count).trimmingCharacters(in: .whitespaces)
            throw HouseCommandError.refused(
                app: manifest.name,
                message: message.isEmpty ? "the command was refused" : message
            )
        }
        return reply
    }

    private func httpRequest(
        route: String,
        method: String,
        argument: String?,
        manifest: HouseCommandManifest,
        timeout: TimeInterval
    ) async throws -> String {
        guard let base = manifest.baseURL else {
            throw HouseCommandError.unreachable(app: manifest.name)
        }
        var request = URLRequest(url: base.appendingPathComponent(route))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let argument {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["argument": argument])
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw HouseCommandError.timedOut(app: manifest.name)
        } catch {
            throw HouseCommandError.unreachable(app: manifest.name)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (200..<300).contains(status) else {
            throw HouseCommandError.refused(
                app: manifest.name,
                message: text.isEmpty ? "the request failed (HTTP \(status))" : text
            )
        }
        return text
    }

    /// A direct `argv` launch through the repo's one process lane: the verb
    /// and the argument are separate arguments, never a shell string, so
    /// user text can never become extra arguments or shell syntax.
    private func execute(
        verb: String,
        argument: String?,
        manifest: HouseCommandManifest,
        timeout: TimeInterval
    ) async throws -> String {
        guard let executable = resolveExecutable(manifest.endpoint) else {
            throw HouseCommandError.notInstalled(app: manifest.name)
        }
        var argv = [verb]
        if let argument { argv.append(argument) }
        let result: ProcessResult
        do {
            result = try await runProcess(executable, argv, timeout)
        } catch ProcessRunnerError.timedOut {
            throw HouseCommandError.timedOut(app: manifest.name)
        } catch {
            throw HouseCommandError.unreachable(app: manifest.name)
        }
        let text = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            throw HouseCommandError.refused(
                app: manifest.name,
                message: result.trimmedStderr
                    ?? (text.isEmpty ? "the command exited with status \(result.status)" : text)
            )
        }
        return text
    }

    /// Newlines and carriage returns become spaces: the socket protocol is
    /// one request per line, so an argument may not carry a line break.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
