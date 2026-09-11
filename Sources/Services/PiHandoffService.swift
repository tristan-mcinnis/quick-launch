import Foundation

/// Continue in pi, the plan's Phase E (docs/ai-chat-plan-20260911.md,
/// section 7). Three steps, each a direct argv launch through
/// `ProcessRunner` with a timeout, never a shell:
///
/// 1. Write the thread as Markdown to `pi-handoff/<timestamp>-<slug>.md`
///    in the app's support folder: owner-only (folder `0700`, file `0600`)
///    and bounded to the newest `retainedFileCount` files.
/// 2. `tmux new-session -d -s ql-<id> -c <folder> -e PATH=… <pi> @<file>
///    <instruction>`: a fresh, detached session of its own. tmux runs a
///    command given as several arguments directly, without `sh -c`. pi is
///    a Node script (`#!/usr/bin/env node`), so the session's `PATH` is
///    the tmux server's own (`show-environment -g PATH`) with the folders
///    of pi, node, tmux, and the usual CLI folders added; with no server
///    running yet, the app's launchd `PATH` stands in for it.
/// 3. `open -n -b com.mitchellh.ghostty --args -e <tmux> attach-session -t
///    ql-<id>`. Ghostty's own help says a macOS terminal cannot be started
///    from its CLI (`+new-window` is GTK only) and names `open -na
///    Ghostty.app --args …` as the way to pass it flags; `-e` runs the
///    rest as the window's command, without a shell, and quits that
///    instance when the window closes. When `open` fails the session keeps
///    running and the result says so.
///
/// tmux and pi are found by `ExecutableResolver`: `~/.local/bin`,
/// `/opt/homebrew/bin`, and the other usual folders, then `PATH`.
///
/// An actor: it owns the file writes and the child processes.
actor PiHandoffService: PiHandoffServicing {
    /// Runs one program to completion: the `ProcessRunner.run` seam.
    typealias Run = @Sendable (_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) async throws -> ProcessResult
    /// Finds a CLI by name.
    typealias Resolve = @Sendable (_ name: String) -> URL?

    /// The message pi gets with the attached thread.
    static let instruction = "Continue this conversation from Quick Launch. The thread is attached."
    /// Thread files kept in `pi-handoff`; older ones are deleted on write.
    static let retainedFileCount = 20
    static let directoryName = "pi-handoff"
    static let sessionPrefix = "ql-"
    static let ghosttyBundleIdentifier = "com.mitchellh.ghostty"
    static let openExecutable = URL(fileURLWithPath: "/usr/bin/open")
    /// Each step is a short-lived client: tmux returns once the session
    /// exists, `open` once Ghostty is asked.
    static let stepTimeout: TimeInterval = 10
    /// System folders a login shell has that launchd's `PATH` may not.
    static let systemPathDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private let directory: URL
    private let home: URL
    private let run: Run
    private let resolve: Resolve
    private let launchPath: String?
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let makeShortID: @Sendable () -> String

    init(
        directory: URL = AppPaths.directory(PiHandoffService.directoryName),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        run: @escaping Run = { executable, arguments, timeout in
            try await ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        },
        resolve: @escaping Resolve = { ExecutableResolver.resolve($0) },
        launchPath: String? = ProcessInfo.processInfo.environment["PATH"],
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        makeShortID: @escaping @Sendable () -> String = PiHandoffService.randomShortID
    ) {
        self.directory = directory
        self.home = home
        self.run = run
        self.resolve = resolve
        self.launchPath = launchPath
        self.timeZone = timeZone
        self.now = now
        self.makeShortID = makeShortID
    }

    func handOff(_ request: PiHandoffRequest) async throws -> PiHandoffResult {
        guard let tmux = resolve("tmux") else { throw PiHandoffError.missingExecutable("tmux") }
        guard let pi = resolve("pi") else { throw PiHandoffError.missingExecutable("pi") }
        let shortID = makeShortID()
        let file = try writeThread(request, shortID: shortID)
        let session = Self.sessionPrefix + shortID
        let folder = request.workingDirectory ?? home

        let path = await sessionPath(tmux: tmux, pi: pi)
        let started: ProcessResult
        do {
            started = try await run(
                tmux,
                Self.newSessionArguments(session: session, folder: folder, path: path, pi: pi, file: file),
                Self.stepTimeout
            )
        } catch {
            throw PiHandoffError.sessionFailed(error.localizedDescription)
        }
        guard started.status == 0 else {
            throw PiHandoffError.sessionFailed(
                started.trimmedStderr ?? "tmux exited with status \(started.status)"
            )
        }

        let opened = await openGhostty(tmux: tmux, session: session)
        return PiHandoffResult(sessionName: session, threadFile: file, openedGhostty: opened)
    }

    // MARK: - Argument lists

    /// tmux takes its options before the command; everything after the
    /// pi path is pi's argv (`pi [options] [@files...] [messages...]`).
    static func newSessionArguments(
        session: String,
        folder: URL,
        path: String,
        pi: URL,
        file: URL
    ) -> [String] {
        [
            "new-session", "-d",
            "-s", session,
            "-c", folder.path,
            "-e", "PATH=\(path)",
            pi.path, "@\(file.path)", instruction,
        ]
    }

    static func ghosttyArguments(tmux: URL, session: String) -> [String] {
        [
            "-n", "-b", ghosttyBundleIdentifier,
            "--args", "-e", tmux.path, "attach-session", "-t", session,
        ]
    }

    /// `base` in its own order, then each of `adding` it lacks. Empty
    /// entries and repeats go.
    static func mergedPath(base: String, adding: [String]) -> String {
        var seen = Set<String>()
        var merged: [String] = []
        for entry in base.split(separator: ":").map(String.init) + adding where !entry.isEmpty {
            if seen.insert(entry).inserted { merged.append(entry) }
        }
        return merged.joined(separator: ":")
    }

    // MARK: - Steps

    private func writeThread(_ request: PiHandoffRequest, shortID: String) throws -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // An existing folder keeps its own mode unless it is set again.
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw PiHandoffError.writeFailed(error.localizedDescription)
        }
        let name = PiHandoffDocument.fileName(date: now(), title: request.title, timeZone: timeZone)
        var file = directory.appendingPathComponent(name, isDirectory: false)
        if fileManager.fileExists(atPath: file.path) {
            // Two hand-offs of one chat in the same second.
            let stem = file.deletingPathExtension().lastPathComponent
            file = directory.appendingPathComponent("\(stem)-\(shortID).md", isDirectory: false)
        }
        guard fileManager.createFile(
            atPath: file.path,
            contents: Data(request.markdown.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw PiHandoffError.writeFailed("\(file.lastPathComponent) could not be created")
        }
        prune(keeping: file)
        return file
    }

    /// Keeps the newest `retainedFileCount` thread files by name, which
    /// sorts by time. pi reads its file once, at start.
    private func prune(keeping current: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let threads = names.filter { $0.hasSuffix(".md") }.sorted(by: >)
        for name in threads.dropFirst(Self.retainedFileCount) where name != current.lastPathComponent {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
        }
    }

    private func sessionPath(tmux: URL, pi: URL) async -> String {
        var base = launchPath ?? ""
        if let result = try? await run(tmux, ["show-environment", "-g", "PATH"], Self.stepTimeout),
           result.status == 0 {
            let line = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("PATH=") { base = String(line.dropFirst("PATH=".count)) }
        }
        var adding = [pi, tmux].map { $0.deletingLastPathComponent().path }
        if let node = resolve("node") { adding.insert(node.deletingLastPathComponent().path, at: 1) }
        adding += ExecutableResolver.searchDirectories(home: home).map(\.path)
        adding += Self.systemPathDirectories
        return Self.mergedPath(base: base, adding: adding)
    }

    private func openGhostty(tmux: URL, session: String) async -> Bool {
        guard let result = try? await run(
            Self.openExecutable,
            Self.ghosttyArguments(tmux: tmux, session: session),
            Self.stepTimeout
        ) else { return false }
        return result.status == 0
    }

    // MARK: - Defaults

    /// Six lowercase hex digits: short enough to type in `tmux attach -t`.
    static func randomShortID() -> String {
        String(UUID().uuidString.lowercased().prefix(6))
    }
}
