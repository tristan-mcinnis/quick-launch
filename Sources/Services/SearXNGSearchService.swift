import Foundation

enum WebSearchError: LocalizedError {
    case failed(String)
    case empty
    case timedOut

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            "Web search failed: \(message)"
        case .empty:
            "Web search returned no results."
        case .timedOut:
            "Web search took too long. Please try again."
        }
    }
}

actor SearXNGSearchService: WebSearchServicing {
    private struct Response: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let title: String?
        let content: String?
        let url: String?
    }

    private let requestTimeout: Duration
    private let transport: @Sendable (URL) async throws -> Data

    init(
        host: String = "vault-vps",
        requestTimeout: Duration = .seconds(8),
        transport: (@Sendable (URL) async throws -> Data)? = nil
    ) {
        self.requestTimeout = requestTimeout
        self.transport = transport ?? { url in try await Self.runSearch(host: host, url: url) }
    }

    func search(_ query: String) async throws -> String {
        try await search(query, provider: .automatic)
    }

    func search(_ query: String, provider: WebSearchProvider) async throws -> String {
        guard let selection = provider.searxngSelection else {
            throw WebSearchError.failed("\(provider.title) does not run through SearXNG")
        }
        return try await search(query, selection: selection)
    }

    func search(_ query: String, selection: SearXNGSelection) async throws -> String {
        let boundedQuery = String(query.prefix(500))
        let date = Date.now.formatted(.iso8601.year().month().day())
        guard let url = Self.searchURL(query: "\(boundedQuery) current date \(date)", selection: selection) else {
            throw WebSearchError.failed("invalid query")
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [transport] in
                let data = try await transport(url)
                return try Self.formatResults(data)
            }
            group.addTask { [requestTimeout] in
                try await Task.sleep(for: requestTimeout)
                throw WebSearchError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw WebSearchError.empty
            }
            return result
        }
    }

    nonisolated static func formatResults(_ data: Data) throws -> String {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WebSearchError.failed("invalid SearXNG response")
        }

        let rows = response.results.prefix(5).compactMap { result -> String? in
            guard let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let url = result.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty
            else { return nil }

            var row = "## \(title)\nURL: \(url)"
            if let snippet = result.content?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !snippet.isEmpty {
                row += "\nSnippet: \(String(snippet.prefix(320)))"
            }
            return row
        }

        guard !rows.isEmpty else { throw WebSearchError.empty }
        return rows.joined(separator: "\n\n")
    }

    nonisolated static func searchURL(query: String, selection: SearXNGSelection) -> URL? {
        var components = URLComponents(string: "http://127.0.0.1:8888/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "pageno", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "safesearch", value: "0"),
        ]
        // Passing categories together with engines makes SearXNG include
        // the category's other engines. A selected selection must stay exact.
        switch selection {
        case .engine(let engine):
            components?.queryItems?.append(URLQueryItem(name: "engines", value: engine))
        case .category(let category):
            components?.queryItems?.append(URLQueryItem(name: "categories", value: category))
        }
        return components?.url
    }

    /// The single remote command string ssh runs on vault-vps. Pure; tests
    /// pin the quoting.
    nonisolated static func remoteCommand(for url: URL) -> [String] {
        ["curl -s --max-time 6 '\(url.absoluteString.replacingOccurrences(of: "'", with: "%27"))'"]
    }

    private nonisolated static func runSearch(host: String, url: URL) async throws -> Data {
        let result: ProcessResult
        do {
            result = try await SSHRunner.run(host: host, remoteCommand: remoteCommand(for: url))
        } catch let error as ProcessRunnerError {
            throw WebSearchError.failed(error.localizedDescription)
        }
        guard result.status == 0 else {
            throw WebSearchError.failed(result.trimmedStderr ?? "exit \(result.status)")
        }
        return result.stdout
    }
}
