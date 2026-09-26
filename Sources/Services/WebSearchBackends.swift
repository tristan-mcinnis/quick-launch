import Foundation

/// The bytes plus HTTP status a direct search API returned. Status is kept as
/// an `Int` so the transport stays `Sendable` for tests and actors.
typealias WebSearchHTTPTransport = @Sendable (URLRequest) async throws -> (Data, Int)

/// Races one async call against a timeout. Every backend gets the same
/// bounded wait so a slow provider cannot hold a chat open.
enum WebSearchTimeout {
    static func run<T: Sendable>(
        _ timeout: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WebSearchError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw WebSearchError.empty
            }
            return result
        }
    }
}

/// The default live transport used by every direct search API. A non-2xx
/// status is returned, not thrown, so the service owns the error text.
enum WebSearchURLSession {
    static let transport: WebSearchHTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}

/// Formats backend results the way every web-search surface already shows
/// them: a heading, the URL, and a short snippet, top five only.
enum WebSearchResultText {
    struct Row {
        let title: String?
        let url: String?
        let snippet: String?
    }

    static func format(_ rows: [Row]) throws -> String {
        let formatted = rows.prefix(5).compactMap { row -> String? in
            guard let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let url = row.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty
            else { return nil }

            var text = "## \(title)\nURL: \(url)"
            if let snippet = row.snippet?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !snippet.isEmpty {
                text += "\nSnippet: \(String(snippet.prefix(320)))"
            }
            return text
        }

        guard !formatted.isEmpty else { throw WebSearchError.empty }
        return formatted.joined(separator: "\n\n")
    }
}

/// The Tavily search API, called directly with a Keychain key.
struct TavilySearchService: WebSearchServicing {
    /// The stored key, read lazily so a settings change takes effect without
    /// rebuilding the service.
    var apiKey: @Sendable () -> String?
    var requestTimeout: Duration = .seconds(8)
    var transport: WebSearchHTTPTransport

    private struct Response: Decodable {
        struct Result: Decodable {
            let title: String?
            let url: String?
            let content: String?
        }
        let results: [Result]?
    }

    init(
        apiKey: @escaping @Sendable () -> String?,
        requestTimeout: Duration = .seconds(8),
        transport: @escaping WebSearchHTTPTransport = WebSearchURLSession.transport
    ) {
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
        self.transport = transport
    }

    static let endpoint = URL(string: "https://api.tavily.com/search")!

    func search(_ query: String) async throws -> String {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw WebSearchError.failed(WebSearchRouter.missingKeyMessage(for: .tavily))
        }

        let request = try makeRequest(query: query, key: key)

        let (data, status) = try await WebSearchTimeout.run(requestTimeout) {
            try await transport(request)
        }
        guard (200..<300).contains(status) else {
            throw WebSearchError.failed("Tavily returned HTTP \(status)")
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WebSearchError.failed("invalid Tavily response")
        }
        let rows = (decoded.results ?? []).map {
            WebSearchResultText.Row(title: $0.title, url: $0.url, snippet: $0.content)
        }
        return try WebSearchResultText.format(rows)
    }

    private func makeRequest(query: String, key: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": String(query.prefix(500)),
            "max_results": 5,
            "search_depth": "basic",
        ])
        return request
    }
}

/// The Brave Search API, called directly with a Keychain key.
struct BraveSearchService: WebSearchServicing {
    var apiKey: @Sendable () -> String?
    var requestTimeout: Duration = .seconds(8)
    var transport: WebSearchHTTPTransport

    private struct Response: Decodable {
        struct Web: Decodable {
            struct Result: Decodable {
                let title: String?
                let url: String?
                let description: String?
            }
            let results: [Result]?
        }
        let web: Web?
    }

    init(
        apiKey: @escaping @Sendable () -> String?,
        requestTimeout: Duration = .seconds(8),
        transport: @escaping WebSearchHTTPTransport = WebSearchURLSession.transport
    ) {
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
        self.transport = transport
    }

    static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!

    func search(_ query: String) async throws -> String {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw WebSearchError.failed(WebSearchRouter.missingKeyMessage(for: .brave))
        }

        let request = try makeRequest(query: query, key: key)

        let (data, status) = try await WebSearchTimeout.run(requestTimeout) {
            try await transport(request)
        }
        guard (200..<300).contains(status) else {
            throw WebSearchError.failed("Brave returned HTTP \(status)")
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WebSearchError.failed("invalid Brave response")
        }
        let rows = (decoded.web?.results ?? []).map {
            WebSearchResultText.Row(title: $0.title, url: $0.url, snippet: $0.description)
        }
        return try WebSearchResultText.format(rows)
    }

    private func makeRequest(query: String, key: String) throws -> URLRequest {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: String(query.prefix(500))),
            URLQueryItem(name: "count", value: "5"),
        ]
        guard let url = components?.url else {
            throw WebSearchError.failed("invalid query")
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        return request
    }
}

/// The Bocha Chinese-web search API, called directly with a Keychain key.
struct BochaSearchService: WebSearchServicing {
    var apiKey: @Sendable () -> String?
    var requestTimeout: Duration = .seconds(8)
    var transport: WebSearchHTTPTransport

    private struct Response: Decodable {
        struct Payload: Decodable {
            struct WebPages: Decodable {
                struct Page: Decodable {
                    let name: String?
                    let url: String?
                    let snippet: String?
                    let summary: String?
                }
                let value: [Page]?
            }
            let webPages: WebPages?
        }
        let code: Int?
        let message: String?
        let data: Payload?
    }

    init(
        apiKey: @escaping @Sendable () -> String?,
        requestTimeout: Duration = .seconds(8),
        transport: @escaping WebSearchHTTPTransport = WebSearchURLSession.transport
    ) {
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
        self.transport = transport
    }

    static let endpoint = URL(string: "https://api.bochaai.com/v1/web-search")!

    func search(_ query: String) async throws -> String {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw WebSearchError.failed(WebSearchRouter.missingKeyMessage(for: .bocha))
        }

        let request = try makeRequest(query: query, key: key)
        let (data, status) = try await WebSearchTimeout.run(requestTimeout) {
            try await transport(request)
        }
        guard (200..<300).contains(status) else {
            throw WebSearchError.failed("Bocha returned HTTP \(status)")
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WebSearchError.failed("invalid Bocha response")
        }
        if let code = decoded.code, code != 200 {
            throw WebSearchError.failed("Bocha error \(code): \(decoded.message ?? "unknown")")
        }
        let rows = (decoded.data?.webPages?.value ?? []).map {
            WebSearchResultText.Row(title: $0.name, url: $0.url, snippet: $0.summary ?? $0.snippet)
        }
        return try WebSearchResultText.format(rows)
    }

    private func makeRequest(query: String, key: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": String(query.prefix(500)),
            "count": 5,
            "freshness": "noLimit",
            "summary": true,
        ])
        return request
    }
}

/// The Exa semantic search API, called directly with a Keychain key.
struct ExaSearchService: WebSearchServicing {
    var apiKey: @Sendable () -> String?
    var requestTimeout: Duration = .seconds(8)
    var transport: WebSearchHTTPTransport

    private struct Response: Decodable {
        struct Result: Decodable {
            let title: String?
            let url: String?
            let text: String?
        }
        let results: [Result]?
    }

    init(
        apiKey: @escaping @Sendable () -> String?,
        requestTimeout: Duration = .seconds(8),
        transport: @escaping WebSearchHTTPTransport = WebSearchURLSession.transport
    ) {
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
        self.transport = transport
    }

    static let endpoint = URL(string: "https://api.exa.ai/search")!

    func search(_ query: String) async throws -> String {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw WebSearchError.failed(WebSearchRouter.missingKeyMessage(for: .exa))
        }

        let request = try makeRequest(query: query, key: key)
        let (data, status) = try await WebSearchTimeout.run(requestTimeout) {
            try await transport(request)
        }
        guard (200..<300).contains(status) else {
            throw WebSearchError.failed("Exa returned HTTP \(status)")
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WebSearchError.failed("invalid Exa response")
        }
        let rows = (decoded.results ?? []).map {
            WebSearchResultText.Row(title: $0.title, url: $0.url, snippet: $0.text)
        }
        return try WebSearchResultText.format(rows)
    }

    private func makeRequest(query: String, key: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": String(query.prefix(500)),
            "numResults": 5,
            "type": "auto",
            "contents": ["text": ["maxCharacters": 500]],
        ])
        return request
    }
}

/// Sends every web search to the backend the chosen provider names. The
/// Automatic provider prefers Bocha for a Chinese query when its key is
/// stored, then Tavily, then SearXNG, then Brave, skipping any step whose key
/// is missing.
struct WebSearchRouter: WebSearchServicing {
    let searxng: any WebSearchServicing
    let tavily: any WebSearchServicing
    let brave: any WebSearchServicing
    let bocha: any WebSearchServicing
    let exa: any WebSearchServicing
    var hasTavilyKey: @Sendable () -> Bool
    var hasBraveKey: @Sendable () -> Bool
    var hasBochaKey: @Sendable () -> Bool
    var hasExaKey: @Sendable () -> Bool

    func search(_ query: String) async throws -> String {
        try await search(query, provider: .automatic)
    }

    func search(_ query: String, provider: WebSearchProvider) async throws -> String {
        switch provider.backend {
        case .searxng:
            return try await searxng.search(query, provider: provider)
        case .tavily:
            guard hasTavilyKey() else {
                throw WebSearchError.failed(Self.missingKeyMessage(for: .tavily))
            }
            return try await tavily.search(query)
        case .brave:
            guard hasBraveKey() else {
                throw WebSearchError.failed(Self.missingKeyMessage(for: .brave))
            }
            return try await brave.search(query)
        case .bocha:
            guard hasBochaKey() else {
                throw WebSearchError.failed(Self.missingKeyMessage(for: .bocha))
            }
            return try await bocha.search(query)
        case .exa:
            guard hasExaKey() else {
                throw WebSearchError.failed(Self.missingKeyMessage(for: .exa))
            }
            return try await exa.search(query)
        case .chain:
            return try await runChain(query)
        }
    }

    private func runChain(_ query: String) async throws -> String {
        var attempted: [String] = []

        if WebSearchQuery.containsCJK(query), hasBochaKey() {
            attempted.append("Bocha")
            if let result = try await Self.attempt({ try await bocha.search(query) }) {
                return result
            }
        }

        if hasTavilyKey() {
            attempted.append("Tavily")
            if let result = try await Self.attempt({ try await tavily.search(query) }) {
                return result
            }
        }

        attempted.append("SearXNG")
        if let result = try await Self.attempt({ try await searxng.search(query, provider: .automatic) }) {
            return result
        }

        if hasBraveKey() {
            attempted.append("Brave")
            if let result = try await Self.attempt({ try await brave.search(query) }) {
                return result
            }
        }

        throw WebSearchError.failed("No results from " + attempted.joined(separator: ", "))
    }

    /// One step of the chain: its text, or nil so the chain moves on. A
    /// cancelled search stops the chain instead: an Escape must not try each
    /// later backend and end on "No results from ...". URLSession reports a
    /// cancelled task as `URLError.cancelled`, so the task's own flag is
    /// checked after any failure too.
    private static func attempt(
        _ step: () async throws -> String
    ) async throws -> String? {
        try Task.checkCancellation()
        do {
            let result = try await step()
            return result.isEmpty ? nil : result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    static func missingKeyMessage(for provider: WebSearchProvider) -> String {
        "Add a \(provider.title) API key in Models \u{203A} Web search."
    }
}
