import Foundation

enum VaultSearchMode: String, CaseIterable, Sendable {
    case current
    case reconcile
    case history
    case portfolio

    init?(commandID: String) {
        guard commandID.hasPrefix("vault.") else { return nil }
        self.init(rawValue: String(commandID.dropFirst("vault.".count)))
    }

    var commandID: String { "vault.\(rawValue)" }

    var title: String {
        switch self {
        case .current: "Current Project"
        case .reconcile: "Reconcile Changes"
        case .history: "Project History"
        case .portfolio: "Across Projects"
        }
    }

    var detail: String {
        switch self {
        case .current: "What is true now, with current state and recent evidence"
        case .reconcile: "Check a completed meeting or event against what changed after it"
        case .history: "Find an earlier or superseded project version"
        case .portfolio: "Search current state across projects"
        }
    }

    var keywords: String {
        switch self {
        case .current: "status now active latest"
        case .reconcile: "meeting email deliverable changed after"
        case .history: "old archive superseded version as of"
        case .portfolio: "all cross project waiting options"
        }
    }

    var placeholder: String {
        switch self {
        case .current: "Project and question…"
        case .reconcile: "Project, meeting, and what to check…"
        case .history: "Project, version, or date…"
        case .portfolio: "Question across current projects…"
        }
    }
}

enum VaultSearchError: LocalizedError {
    case failed(String)
    case empty
    case timedOut
    /// The backend answered in a shape this adapter does not understand. Kept
    /// apart from `empty`: a schema break says nothing about the vault.
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): "Vault Search failed: \(message)"
        case .empty: "Vault Search returned no evidence. Add a project name or narrow the question."
        case .timedOut: "Vault Search took too long. Check the VPS connection and try again."
        case .malformed(let detail): "Vault Search answered in an unexpected shape: \(detail)"
        }
    }

    /// The normalized state behind this error, so a caller can record the
    /// outcome beside the answer instead of only the localized string.
    var status: VaultSearchStatus {
        switch self {
        case .empty: .noMatch
        case .timedOut: .unavailable(reason: "no response within the request deadline")
        case .failed(let message): .unavailable(reason: message)
        case .malformed(let detail): .unavailable(reason: "unexpected response shape: \(detail)")
        }
    }
}

actor SSHVaultSearchService: VaultSearchServicing {
    private let host: String
    private let remoteScript: String
    private let requestTimeout: Duration
    private let localVaultRoot: URL

    /// The vault checkout on the House server. Paths the search returns are
    /// relative to it, or absolute under it.
    static let remoteVaultRoot = "/home/ubuntu/vault-private/"
    /// One attempt, `requestTimeout` long, then `VaultSearchError.timedOut`.
    /// There is no retry. `localVaultRoot` is this Mac's clone of the same
    /// vault, where a source opens.
    init(
        host: String = HouseServer.host,
        remoteScript: String = "/home/ubuntu/vault-private/.claude/tools/state/vault-search.py",
        requestTimeout: Duration = .seconds(8),
        localVaultRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "vault", directoryHint: .isDirectory)
    ) {
        self.host = host
        self.remoteScript = remoteScript
        self.requestTimeout = requestTimeout
        self.localVaultRoot = localVaultRoot
    }

    func search(mode: VaultSearchMode, query: String) async throws -> String {
        try await searchWithSources(mode: mode, query: query).text
    }

    func searchWithSources(mode: VaultSearchMode, query: String) async throws -> VaultSearchOutcome {
        let bounded = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2_000))
        guard !bounded.isEmpty else { throw VaultSearchError.empty }

        return try await withThrowingTaskGroup(of: VaultSearchOutcome.self) { group in
            group.addTask { [host, remoteScript, localVaultRoot] in
                try await Self.searchOnce(
                    host: host,
                    remoteScript: remoteScript,
                    localVaultRoot: localVaultRoot,
                    mode: mode,
                    query: bounded
                )
            }
            group.addTask { [requestTimeout] in
                try await Task.sleep(for: requestTimeout)
                throw VaultSearchError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw VaultSearchError.empty }
            return result
        }
    }

    /// One search, including the project resolution `history` requires. The
    /// remote script declares `--project` required for history and refuses to
    /// run without it, so a history question resolves its project through the
    /// same server-side resolver the other modes use; when no single project is
    /// named, the resolver's candidate list is the answer.
    nonisolated static func searchOnce(
        host: String,
        remoteScript: String,
        localVaultRoot: URL,
        mode: VaultSearchMode,
        query: String
    ) async throws -> VaultSearchOutcome {
        guard mode == .history else {
            let data = try await run(
                host: host,
                remoteScript: remoteScript,
                arguments: remoteArguments(remoteScript: remoteScript, mode: mode),
                query: query
            )
            return try outcome(from: data, localVaultRoot: localVaultRoot)
        }
        let scopeData = try await run(
            host: host,
            remoteScript: remoteScript,
            arguments: scopeResolutionArguments(remoteScript: remoteScript),
            query: query
        )
        guard let project = resolvedProject(from: scopeData) else {
            return try outcome(from: scopeData, localVaultRoot: localVaultRoot)
        }
        let data = try await run(
            host: host,
            remoteScript: remoteScript,
            arguments: remoteArguments(remoteScript: remoteScript, mode: mode, project: project),
            query: query
        )
        return try outcome(from: data, localVaultRoot: localVaultRoot)
    }

    /// The project slug a `scope` answer names, or nil when the question does
    /// not pin one project (the payload then carries candidates to choose from).
    nonisolated static func resolvedProject(from data: Data) -> String? {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              payload["needs_scope"] as? Bool != true,
              let slug = payload["resolved_project"] as? String
        else { return nil }
        let clean = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    nonisolated static func run(
        host: String,
        remoteScript: String,
        arguments: [String],
        query: String
    ) async throws -> Data {
        let result: ProcessResult
        do {
            result = try await SSHRunner.run(
                host: host,
                remoteCommand: arguments,
                disablePTY: true,
                stdin: Data(query.utf8)
            )
        } catch let error as ProcessRunnerError {
            throw VaultSearchError.failed(unavailableReason(error, remoteScript: remoteScript))
        }
        guard result.status == 0 else {
            throw VaultSearchError.failed(diagnostic(
                status: result.status,
                stdout: result.stdout,
                stderr: result.stderr,
                remoteScript: remoteScript
            ))
        }
        return result.stdout
    }

    /// A launch failure or a timeout as one diagnostic line naming the tool.
    nonisolated static func unavailableReason(_ error: ProcessRunnerError, remoteScript: String) -> String {
        let tool = remoteToolName(remoteScript)
        return switch error {
        case .launchFailed(_, let reason): "\(tool) could not start: \(reason)"
        case .timedOut(_, let seconds): "\(tool) did not respond within \(Int(seconds)) seconds"
        }
    }

    /// A non-zero exit as one diagnostic line: the tool's own error message
    /// when it wrote one, otherwise its last non-empty stderr line. Never a
    /// whole traceback and never a bare exit code.
    nonisolated static func diagnostic(
        status: Int32,
        stdout: Data,
        stderr: Data,
        remoteScript: String
    ) -> String {
        let tool = remoteToolName(remoteScript)
        if let message = payloadError(stdout) {
            return "\(tool) reported: \(message)"
        }
        if let line = lastMeaningfulLine(stderr) {
            return "\(tool) exited \(status): \(line)"
        }
        return "\(tool) exited \(status) with no message"
    }

    /// The remote script's name, for a message a person reads.
    nonisolated static func remoteToolName(_ remoteScript: String) -> String {
        let name = URL(fileURLWithPath: remoteScript).lastPathComponent
        return name.isEmpty ? remoteScript : name
    }

    /// The `error` (or refusal) a failed remote call printed to stdout before
    /// exiting non-zero.
    private nonisolated static func payloadError(_ data: Data) -> String? {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for key in ["error", "refusal"] {
            if let value = payload[key] as? String {
                let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return clean }
            }
        }
        return nil
    }

    /// The last non-empty stderr line: a Python traceback's own final line is
    /// the exception, which is the part worth keeping.
    private nonisolated static func lastMeaningfulLine(_ data: Data) -> String? {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
    }

    /// The remote argv after the host. Pure; tests pin it. `project` is the
    /// CLI's own `--project` filter, passed only by the modes that take one.
    nonisolated static func remoteArguments(
        remoteScript: String,
        mode: VaultSearchMode,
        project: String? = nil
    ) -> [String] {
        var arguments = ["python3", remoteScript, mode.rawValue, "--stdin", "--limit", "10", "--json"]
        if let project, !project.isEmpty { arguments += ["--project", project] }
        return arguments
    }

    /// The remote argv for the server-side project resolver: the same free-text
    /// question in, one project slug or a list of candidates out.
    nonisolated static func scopeResolutionArguments(remoteScript: String) -> [String] {
        ["python3", remoteScript, "scope", "--stdin", "--limit", "10", "--json"]
    }

    /// The rendered answer plus the rows behind it. Current and Reconcile
    /// cite their `evidence`; History and Across Projects their `results`.
    /// A row's `source_path` is mapped onto `localVaultRoot`; a row with no
    /// path, or a path outside the vault, is listed without one.
    nonisolated static func outcome(from data: Data, localVaultRoot: URL) throws -> VaultSearchOutcome {
        let text = try formatResponse(data)
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if payload["needs_scope"] as? Bool == true {
            let candidates = payload["candidates"] as? [[String: Any]] ?? []
            return VaultSearchOutcome(
                text: text,
                resultCount: candidates.count,
                sources: [],
                needsScope: true,
                status: .degraded(reason: candidates.isEmpty
                    ? "the backend needs a project named"
                    : "more than one project matches")
            )
        }
        let rows = (payload["evidence"] as? [[String: Any]])
            ?? (payload["results"] as? [[String: Any]])
            ?? []
        let sources = rows.compactMap { row -> ChatSource? in
            let remotePath = Self.text(row["source_path"])
            guard let title = Self.text(row["title"])
                ?? remotePath.map({ URL(fileURLWithPath: $0).lastPathComponent })
                ?? Self.text(row["slug"])
            else { return nil }
            let day = ["authored_at", "updated_at", "verified_at"]
                .lazy
                .compactMap { Self.text(row[$0]) }
                .first
                .map { String($0.prefix(10)) }
            return ChatSource(
                title: title,
                day: day,
                path: remotePath.flatMap { localPath(forVaultPath: $0, localVaultRoot: localVaultRoot) }
            )
        }
        var seen = Set<String>()
        return VaultSearchOutcome(
            text: text,
            resultCount: rows.count,
            sources: Array(sources.filter { seen.insert($0.id).inserted }.prefix(10)),
            status: rows.isEmpty ? .noMatch : .available
        )
    }

    /// A vault path as a path on this Mac: `/home/ubuntu/vault-private/x`
    /// and the relative `x` both become `<localVaultRoot>/x`. Any other
    /// absolute path, or one that climbs out with `..`, has no local file.
    nonisolated static func localPath(forVaultPath path: String, localVaultRoot: URL) -> String? {
        let relative: String
        if path.hasPrefix(remoteVaultRoot) {
            relative = String(path.dropFirst(remoteVaultRoot.count))
        } else if path.hasPrefix("/") {
            return nil
        } else {
            relative = path
        }
        let components = relative.split(separator: "/")
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return localVaultRoot.appending(path: relative, directoryHint: .notDirectory).path
    }

    nonisolated static func formatResponse(_ data: Data) throws -> String {
        // `try?`: an unparseable body is a schema break with a diagnostic, not
        // a raw Cocoa error escaping as an opaque failure.
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw VaultSearchError.malformed("the answer was not a JSON object")
        }
        if let refusal = payload["refusal"] as? String, refusal == "future_not_available" {
            let boundary = payload["requested_boundary"] as? String ?? "that date"
            let asOf = payload["as_of"] as? String ?? "now"
            return "## No future evidence\n\nVault Search has no evidence for \(boundary). Current data is available as of \(asOf)."
        }
        if payload["needs_scope"] as? Bool == true {
            let candidates = payload["candidates"] as? [[String: Any]] ?? []
            let rows = candidates.prefix(8).map { row in
                let title = text(row["title"]) ?? text(row["slug"]) ?? "Untitled project"
                let slug = text(row["slug"]) ?? ""
                let status = [text(row["phase"]), text(row["status"])].compactMap { $0 }.joined(separator: " · ")
                return "- **\(title)** (`\(slug)`)" + (status.isEmpty ? "" : " · \(status)")
            }
            let body = candidates.isEmpty
                ? "No project matched that name. Name the project in the question."
                : "More than one project matches. Add one of these names to the question:\n\n" + rows.joined(separator: "\n")
            return "## Choose a project\n\n" + body
        }

        // A failure the backend reported itself, with exit status 0: its own
        // message is the diagnostic, and it is not evidence about the vault.
        guard payload["ok"] as? Bool == true else {
            throw VaultSearchError.failed(
                text(payload["error"]) ?? "the vault search reported a failure"
            )
        }
        // Every answer names its mode; a shape the remote script cannot emit
        // means the two sides have drifted, which a caller must not read as
        // "the vault has nothing".
        guard let mode = text(payload["mode"]) else {
            throw VaultSearchError.malformed("an answer with no mode")
        }
        switch mode {
        case "history": return try formatHistory(payload)
        case "portfolio": return try formatPortfolio(payload)
        case "current", "reconcile": return try formatCurrent(payload)
        default: throw VaultSearchError.malformed("an unknown mode, \"\(mode)\"")
        }
    }

    private nonisolated static func formatCurrent(_ payload: [String: Any]) throws -> String {
        guard let state = payload["state"] as? [String: Any],
              let project = state["project"] as? [String: Any]
        else { throw VaultSearchError.malformed("a current-state answer with no state.project") }
        let title = text(project["title"]) ?? text(project["slug"]) ?? "Project"
        let status = [text(project["phase"]), text(project["status"])].compactMap { $0 }.joined(separator: " · ")
        let verified = text(project["verified_at"]) ?? text(payload["as_of"]) ?? "unknown time"
        let evidence = payload["evidence"] as? [[String: Any]] ?? []
        let statusSummary = evidence.first { text($0["source_root"]) == "project_status" }
            .flatMap { text($0["summary"]) }
        let tasks = state["tasks"] as? [[String: Any]] ?? []
        let decisions = state["decisions"] as? [[String: Any]] ?? []

        var sections = ["## \(title)", "As of \(verified)" + (status.isEmpty ? "" : ": \(status)")]
        if let statusSummary, !statusSummary.isEmpty {
            sections += ["### Current state", statusSummary]
        }
        if !tasks.isEmpty {
            sections += ["### Open actions", tasks.prefix(5).map { row in
                "- " + (text(row["title"]) ?? "Untitled task")
            }.joined(separator: "\n")]
        }
        if !decisions.isEmpty {
            sections += ["### Recent decisions", decisions.prefix(4).map { row in
                "- " + (text(row["title"]) ?? "Untitled decision")
            }.joined(separator: "\n")]
        }
        let sources = evidence.prefix(8).compactMap { row -> String? in
            guard let path = text(row["source_path"]) else { return nil }
            let name = text(row["title"]) ?? path
            return "- \(name)\n  `\(path)`"
        }
        if !sources.isEmpty { sections += ["### Sources", sources.joined(separator: "\n")] }
        return sections.joined(separator: "\n\n")
    }

    private nonisolated static func formatHistory(_ payload: [String: Any]) throws -> String {
        guard let rows = payload["results"] as? [[String: Any]] else {
            throw VaultSearchError.malformed("a history answer with no results")
        }
        // An empty result set is a real answer: the index found no earlier version.
        guard !rows.isEmpty else { throw VaultSearchError.empty }
        let project = text(payload["project"]) ?? "project"
        let asOf = text(payload["as_of"]).map { " as of \($0)" } ?? ""
        let body = rows.prefix(10).map { row in
            let title = text(row["title"]) ?? text(row["source_path"]) ?? "Untitled source"
            let date = text(row["authored_at"]).map { " · \($0.prefix(10))" } ?? ""
            let path = text(row["source_path"]) ?? ""
            return "- **\(title)**\(date)\n  `\(path)`"
        }.joined(separator: "\n")
        return "## \(project) history\(asOf)\n\n\(body)"
    }

    private nonisolated static func formatPortfolio(_ payload: [String: Any]) throws -> String {
        guard let rows = payload["results"] as? [[String: Any]] else {
            throw VaultSearchError.malformed("an across-projects answer with no results")
        }
        // An empty result set is a real answer: no current project matches.
        guard !rows.isEmpty else { throw VaultSearchError.empty }
        let body = rows.prefix(10).map { row in
            let title = text(row["title"]) ?? text(row["slug"]) ?? "Untitled project"
            let status = [text(row["phase"]), text(row["status"])].compactMap { $0 }.joined(separator: " · ")
            let summary = text(row["summary"])
            return "### \(title)" + (status.isEmpty ? "" : "\n\(status)")
                + (summary.map { "\n\n\($0)" } ?? "")
        }.joined(separator: "\n\n")
        return "## Across projects\n\n\(body)"
    }

    private nonisolated static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
