import Foundation

/// What a command did. An app with slow work starts it and says so rather
/// than making the caller wait; the caller then polls `status`.
enum HouseCommandOutcome: Sendable, Equatable {
    /// Finished. The app's own reply text, which may be empty.
    case completed(String)
    /// Running. The launcher says "started" and polls `status` for the end.
    case started
}

/// Runs one house command, reads one app's status, and fetches one command's
/// choices, over whichever of the three transports its manifest declares.
///
/// Every outward lane is injected, so a test drives all three without
/// opening a socket, making an HTTP call, or starting a process:
/// `sendLine` for `socket`, `session` for `http` (a `URLProtocol` stub),
/// `runProcess` plus `resolveExecutable` for `exec`, and `readFile` for the
/// status file an `exec` app publishes.
protocol HouseCommandDispatching: Sendable {
    /// Runs `command`, with its one argument when it takes one.
    @discardableResult
    func run(
        _ command: HouseCommand,
        argument: String?,
        in manifest: HouseCommandManifest
    ) async throws -> HouseCommandOutcome

    /// Reads the app's status document, or `nil` when the app publishes no
    /// status. Throws when the app should have answered and did not.
    func status(for manifest: HouseCommandManifest) async throws -> HouseCommandStatus?

    /// Fetches the options for a `choice` command, when the user opens it.
    func choices(
        for command: HouseCommand,
        in manifest: HouseCommandManifest
    ) async throws -> [HouseCommandChoice]
}

actor HouseCommandDispatcher: HouseCommandDispatching {
    /// Every command is dispatched off the main thread with a timeout, so a
    /// slow or hung app can never wedge the launcher. An app with slow work
    /// returns at once with `started`, so this bounds the handshake, not the
    /// work.
    static let runTimeout: TimeInterval = 5
    /// A status read sits on the launcher's path, so it is cheap or it is
    /// nothing.
    static let statusTimeout: TimeInterval = 1
    /// A choices fetch happens while the user watches, so it may cost a
    /// little more than a status read and no more than a moment.
    static let choicesTimeout: TimeInterval = 2

    private let sendLine: HouseSocketSending
    private let session: URLSession
    private let runProcess: ProcessRunning
    private let resolveExecutable: @Sendable (String) -> URL?
    private let readFile: @Sendable (String) -> Data?

    init(
        sendLine: @escaping HouseSocketSending = UnixSocketLineClient.live,
        session: URLSession = .shared,
        runProcess: @escaping ProcessRunning = ProcessRunner.live,
        resolveExecutable: @escaping @Sendable (String) -> URL? = { ExecutableResolver.resolve($0) },
        readFile: @escaping @Sendable (String) -> Data? = { path in
            try? Data(contentsOf: URL(fileURLWithPath: path))
        }
    ) {
        self.sendLine = sendLine
        self.session = session
        self.runProcess = runProcess
        self.resolveExecutable = resolveExecutable
        self.readFile = readFile
    }

    @discardableResult
    func run(
        _ command: HouseCommand,
        argument: String?,
        in manifest: HouseCommandManifest
    ) async throws -> HouseCommandOutcome {
        let value = Self.trimmed(argument)
        switch manifest.transport {
        case .socket:
            let reply = try await socketExchange(
                verb: command.verb,
                argument: value,
                manifest: manifest,
                timeout: Self.runTimeout
            )
            return .completed(reply)
        case .http:
            let reply = try await httpRequest(
                route: command.verb,
                method: "POST",
                argument: value,
                manifest: manifest,
                timeout: Self.runTimeout
            )
            // An app with slow work starts it and replies `started: true`
            // instead of a completion. That is a success, not a failure.
            return Self.startedReply(reply) ? .started : .completed(reply)
        case .exec:
            let reply = try await execute(
                arguments: value.map { [command.verb, $0] } ?? [command.verb],
                manifest: manifest,
                timeout: Self.runTimeout
            )
            return .completed(reply)
        }
    }

    func status(for manifest: HouseCommandManifest) async throws -> HouseCommandStatus? {
        guard let status = manifest.status else { return nil }
        switch manifest.transport {
        case .socket:
            let line = try await socketExchange(
                verb: status,
                argument: nil,
                manifest: manifest,
                timeout: Self.statusTimeout
            )
            return HouseCommandStatus.parse(line)
        case .http:
            // A status read is a read: the command lane posts, this gets.
            let body = try await httpRequest(
                route: status,
                method: "GET",
                argument: nil,
                manifest: manifest,
                timeout: Self.statusTimeout
            )
            return HouseCommandStatus.parse(body)
        case .exec:
            // A CLI is stateless: it cannot answer for the app, and shelling
            // out on every read would be slow and a second source of truth.
            // So `status` is an absolute path to a JSON file the app writes
            // atomically when its state changes. Nothing is executed here.
            //
            // The file is never expired by age. An app whose state rarely
            // changes has an old file and is perfectly healthy; treating
            // that as stale would hide a working app.
            guard let data = readFile(status) else {
                throw HouseCommandError.unreachable(app: manifest.name)
            }
            guard let parsed = HouseCommandStatus.parse(data) else {
                // Malformed reads exactly like a dead socket.
                throw HouseCommandError.unreachable(app: manifest.name)
            }
            return parsed
        }
    }

    func choices(
        for command: HouseCommand,
        in manifest: HouseCommandManifest
    ) async throws -> [HouseCommandChoice] {
        guard let route = command.choicesFrom else { return [] }
        // Transport-agnostic: a socket app answers it as a verb, an exec app
        // as a subcommand, an http app as a GET.
        let payload: String
        switch manifest.transport {
        case .socket:
            payload = try await socketExchange(
                verb: route,
                argument: nil,
                manifest: manifest,
                timeout: Self.choicesTimeout
            )
        case .http:
            payload = try await httpRequest(
                route: route,
                method: "GET",
                argument: nil,
                manifest: manifest,
                timeout: Self.choicesTimeout
            )
        case .exec:
            payload = try await execute(
                arguments: [route],
                manifest: manifest,
                timeout: Self.choicesTimeout
            )
        }
        return HouseCommandChoice.parse(payload)
    }

    // MARK: - Transports

    /// One line out, one line back. A reply starting `err ` is the
    /// contract's refusal, and its text is what the user is shown.
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
            reply = try await sendLine(URL(fileURLWithPath: manifest.endpoint), line, timeout)
        } catch UnixSocketLineClient.Failure.timedOut {
            throw HouseCommandError.timedOut(app: manifest.name)
        } catch {
            throw HouseCommandError.unreachable(app: manifest.name)
        }
        if let message = Self.socketErrorText(reply) {
            throw HouseCommandError.refused(app: manifest.name, message: message)
        }
        return reply
    }

    /// A command is `POST {endpoint}{verb}`; `status` and `choicesFrom` are
    /// `GET`. The route already carries its leading slash, so the two are
    /// joined as written and no existing route is bent to fit.
    private func httpRequest(
        route: String,
        method: String,
        argument: String?,
        manifest: HouseCommandManifest,
        timeout: TimeInterval
    ) async throws -> String {
        guard let url = URL(string: manifest.endpoint + route) else {
            throw HouseCommandError.unreachable(app: manifest.name)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if method == "POST" {
            // The caller never asks to wait. Nothing in a manifest says
            // which commands are slow: an app with nothing slow to do
            // ignores the unknown key, and one with slow work starts it and
            // replies `started: true`.
            var body: [String: Any] = ["wait": false]
            if let argument { body["argument"] = argument }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
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
        arguments: [String],
        manifest: HouseCommandManifest,
        timeout: TimeInterval
    ) async throws -> String {
        guard let executable = resolveExecutable(manifest.endpoint) else {
            throw HouseCommandError.notInstalled(app: manifest.name)
        }
        let result: ProcessResult
        do {
            result = try await runProcess(executable, arguments, timeout)
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

    // MARK: - Reply shapes

    /// The refusal line the socket protocol defines: one line starting
    /// `err `, e.g. `err unknown command "foo"`. Its text is surfaced as it
    /// stands; nothing further is parsed out of it.
    static func socketErrorText(_ reply: String) -> String? {
        guard reply == "err" || reply.hasPrefix("err ") else { return nil }
        let message = reply.dropFirst("err".count).trimmingCharacters(in: .whitespaces)
        return message.isEmpty ? "the command was refused" : message
    }

    /// `{"started": true}`: the work is running, not finished.
    static func startedReply(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return false }
        return (root["started"] as? Bool) == true
    }

    /// Newlines and carriage returns become spaces: the socket protocol is
    /// one request per line, so an argument may not carry a line break.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private static func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}
