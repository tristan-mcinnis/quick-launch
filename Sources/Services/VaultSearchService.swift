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

    var errorDescription: String? {
        switch self {
        case .failed(let message): "Vault Search failed: \(message)"
        case .empty: "Vault Search returned no evidence. Add a project name or narrow the question."
        case .timedOut: "Vault Search took too long. Check the VPS connection and try again."
        }
    }
}

actor SSHVaultSearchService: VaultSearchServicing {
    private let host: String
    private let remoteScript: String
    private let requestTimeout: Duration
    private let localVaultRoot: URL

    /// The vault checkout on vault-vps. Paths the search returns are
    /// relative to it, or absolute under it.
    static let remoteVaultRoot = "/home/ubuntu/vault-private/"
    /// The SSH host of the vault lane, as `~/.ssh/config` names it.
    static let defaultHost = "vault-vps"

    /// One attempt, `requestTimeout` long, then `VaultSearchError.timedOut`.
    /// There is no retry. `localVaultRoot` is this Mac's clone of the same
    /// vault, where a source opens.
    init(
        host: String = SSHVaultSearchService.defaultHost,
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
                let data = try await Self.run(host: host, remoteScript: remoteScript, mode: mode, query: bounded)
                return try Self.outcome(from: data, localVaultRoot: localVaultRoot)
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

    nonisolated static func run(
        host: String,
        remoteScript: String,
        mode: VaultSearchMode,
        query: String
    ) async throws -> Data {
        let result: ProcessResult
        do {
            result = try await SSHRunner.run(
                host: host,
                remoteCommand: remoteArguments(remoteScript: remoteScript, mode: mode),
                disablePTY: true,
                stdin: Data(query.utf8)
            )
        } catch let error as ProcessRunnerError {
            throw VaultSearchError.failed(error.localizedDescription)
        }
        guard result.status == 0 else {
            throw VaultSearchError.failed(result.trimmedStderr ?? "exit \(result.status)")
        }
        return result.stdout
    }

    /// The remote argv after the host. Pure; tests pin it.
    nonisolated static func remoteArguments(remoteScript: String, mode: VaultSearchMode) -> [String] {
        ["python3", remoteScript, mode.rawValue, "--stdin", "--limit", "10", "--json"]
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
            return VaultSearchOutcome(text: text, resultCount: candidates.count, sources: [], needsScope: true)
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
            sources: Array(sources.filter { seen.insert($0.id).inserted }.prefix(10))
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
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VaultSearchError.failed("invalid response")
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
            return "## Choose a project\n\nMore than one project matches. Add one of these names to the question:\n\n" + rows.joined(separator: "\n")
        }

        let mode = text(payload["mode"]) ?? "current"
        if mode == "history" { return try formatHistory(payload) }
        if mode == "portfolio" { return try formatPortfolio(payload) }
        return try formatCurrent(payload)
    }

    private nonisolated static func formatCurrent(_ payload: [String: Any]) throws -> String {
        guard let state = payload["state"] as? [String: Any],
              let project = state["project"] as? [String: Any]
        else { throw VaultSearchError.empty }
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
        let rows = payload["results"] as? [[String: Any]] ?? []
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
        let rows = payload["results"] as? [[String: Any]] ?? []
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
