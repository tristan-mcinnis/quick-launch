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

    private let host: String
    private let requestTimeout: Duration

    init(host: String = "vault-vps", requestTimeout: Duration = .seconds(8)) {
        self.host = host
        self.requestTimeout = requestTimeout
    }

    func search(_ query: String) async throws -> String {
        let boundedQuery = String(query.prefix(500))
        let date = Date.now.formatted(.iso8601.year().month().day())
        guard let url = Self.searchURL(query: "\(boundedQuery) current date \(date)") else {
            throw WebSearchError.failed("invalid query")
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [host] in
                let data = try await Self.runSearch(host: host, url: url)
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

    private nonisolated static func searchURL(query: String) -> URL? {
        var components = URLComponents(string: "http://127.0.0.1:8888/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "pageno", value: "1"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "categories", value: "general"),
            URLQueryItem(name: "safesearch", value: "0"),
        ]
        return components?.url
    }

    private nonisolated static func runSearch(host: String, url: URL) async throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            host,
            "curl -s --max-time 6 '\(url.absoluteString.replacingOccurrences(of: "'", with: "%27"))'",
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    let output = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = String(
                        decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard finished.terminationStatus == 0 else {
                        continuation.resume(throwing: WebSearchError.failed(
                            errorOutput.isEmpty
                                ? "exit \(finished.terminationStatus)"
                                : errorOutput
                        ))
                        return
                    }
                    continuation.resume(returning: output)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: WebSearchError.failed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
