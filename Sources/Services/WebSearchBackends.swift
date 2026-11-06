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

/// DeepSeek's search API (`/v1/tools/search`), called with the DeepSeek
/// provider key. It returns its own ranked pages, so the chat model never
/// sees a second provider's text. It leads the Automatic chain, so its
/// timeout is shorter than the others: a dead DeepSeek leaves the fallbacks
/// room inside the answer's tool-time budget.
struct DeepSeekSearchService: WebSearchServicing {
    var apiKey: @Sendable () -> String?
    var requestTimeout: Duration = .seconds(5)
    var transport: WebSearchHTTPTransport

    private struct Response: Decodable {
        struct Result: Decodable {
            let title: String?
            let url: String?
            let snippet: String?
            let summary: String?
        }
        let results: [Result]?
    }

    init(
        apiKey: @escaping @Sendable () -> String?,
        requestTimeout: Duration = .seconds(5),
        transport: @escaping WebSearchHTTPTransport = WebSearchURLSession.transport
    ) {
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
        self.transport = transport
    }

    /// Always DeepSeek's own host, whatever base URL the chat provider uses.
    static let endpoint = URL(string: "https://api.deepseek.com/v1/tools/search")!
    /// The API rejects a query over 128 Unicode characters (scalars).
    static let maxQueryLength = 128

    /// The query as the API accepts it: trimmed and cut to 128 scalars, so an
    /// emoji or accent made of several scalars cannot push it over.
    static func apiQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(maxQueryLength)))
        return cut.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(_ query: String) async throws -> String {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw WebSearchError.failed(WebSearchRouter.missingKeyMessage(for: .deepseek))
        }
        let apiQuery = Self.apiQuery(query)
        guard !apiQuery.isEmpty else { throw WebSearchError.failed("empty query") }

        let request = try makeRequest(query: apiQuery, key: key)
        let (data, status) = try await WebSearchTimeout.run(requestTimeout) {
            try await transport(request)
        }
        switch status {
        case 200..<300: break
        case 402: throw WebSearchError.failed("DeepSeek balance is empty")
        case 429: throw WebSearchError.failed("DeepSeek search is rate-limited")
        default: throw WebSearchError.failed("DeepSeek search returned HTTP \(status)")
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw WebSearchError.failed("invalid DeepSeek search response")
        }
        let rows = (decoded.results ?? []).map {
            WebSearchResultText.Row(title: $0.title, url: $0.url, snippet: $0.summary ?? $0.snippet)
        }
        return try WebSearchResultText.format(rows)
    }

    private func makeRequest(query: String, key: String) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "count": 5,
        ])
        return request
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
/// Automatic provider tries DeepSeek first, then Bocha for a Chinese query,
/// then Tavily, then Brave, skipping any step whose key is missing. A step
/// that fails moves on at once, and one that stalls past `hedgeDelay` gets
/// the next step started beside it; the first text wins.
struct WebSearchRouter: WebSearchServicing {
    let deepseek: any WebSearchServicing
    let tavily: any WebSearchServicing
    let brave: any WebSearchServicing
    let bocha: any WebSearchServicing
    let exa: any WebSearchServicing
    var hasDeepSeekKey: @Sendable () -> Bool
    var hasTavilyKey: @Sendable () -> Bool
    var hasBraveKey: @Sendable () -> Bool
    var hasBochaKey: @Sendable () -> Bool
    var hasExaKey: @Sendable () -> Bool
    /// How long an Automatic step may run before the next one starts beside
    /// it. DeepSeek and Bocha answer in under half a second (measured
    /// 2026-11-06, p90 361 ms and 226 ms), so a step this slow has stalled.
    var hedgeDelay: Duration = WebSearchRouter.defaultHedgeDelay
    /// Waits out `hedgeDelay`. Tests inject their own clock here.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static let defaultHedgeDelay: Duration = .seconds(1)

    func search(_ query: String) async throws -> String {
        try await search(query, provider: .automatic)
    }

    func search(_ query: String, provider: WebSearchProvider) async throws -> String {
        switch provider.backend {
        case .deepseek:
            guard hasDeepSeekKey() else {
                throw WebSearchError.failed(Self.missingKeyMessage(for: .deepseek))
            }
            return try await deepseek.search(query)
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

    /// The Automatic chain's steps for `query`, in order, each only when its
    /// key exists.
    private func chainSteps(for query: String) -> [(name: String, run: @Sendable () async throws -> String)] {
        var steps: [(name: String, run: @Sendable () async throws -> String)] = []
        if hasDeepSeekKey() {
            steps.append(("DeepSeek", { [deepseek] in try await deepseek.search(query) }))
        }
        if WebSearchQuery.containsCJK(query), hasBochaKey() {
            steps.append(("Bocha", { [bocha] in try await bocha.search(query) }))
        }
        if hasTavilyKey() {
            steps.append(("Tavily", { [tavily] in try await tavily.search(query) }))
        }
        if hasBraveKey() {
            steps.append(("Brave", { [brave] in try await brave.search(query) }))
        }
        return steps
    }

    /// One event of the hedged chain: a step finished (its text, or nil
    /// when it failed or came back empty), or a step's hedge delay passed.
    private enum ChainEvent: Sendable {
        case finished(step: Int, text: String?)
        case hedge(step: Int)
    }

    /// Runs the chain's steps in order, hedged: a step that fails or comes
    /// back empty starts the next at once, and a step still running after
    /// `hedgeDelay` starts the next beside it. The first step with text wins
    /// and the rest are cancelled, so a stalled provider costs the hedge
    /// delay instead of its whole timeout. A cancelled search stops the
    /// chain (`attempt`).
    private func runChain(_ query: String) async throws -> String {
        let steps = chainSteps(for: query)
        let noResults = WebSearchError.failed("No results from " + steps.map(\.name).joined(separator: ", "))
        guard !steps.isEmpty else { throw noResults }
        let hedgeDelay = hedgeDelay
        let sleep = sleep

        return try await withThrowingTaskGroup(of: ChainEvent.self) { group in
            var launched = 0
            var running = 0
            func launchNext() {
                let index = launched
                launched += 1
                running += 1
                let step = steps[index]
                group.addTask { .finished(step: index, text: try await Self.attempt(step.run)) }
                if launched < steps.count {
                    group.addTask {
                        try await sleep(hedgeDelay)
                        return .hedge(step: index)
                    }
                }
            }

            launchNext()
            while let event = try await group.next() {
                switch event {
                case .finished(_, let text?):
                    group.cancelAll()
                    return text
                case .finished(let step, nil):
                    running -= 1
                    // A failed step hands on only when it is the newest or
                    // nothing else is still running: an older step failing
                    // beside a hedged one starts no third provider.
                    if launched < steps.count, step == launched - 1 || running == 0 {
                        launchNext()
                    } else if running == 0 {
                        group.cancelAll()
                        throw noResults
                    }
                case .hedge(let step):
                    // Only the newest step's delay counts: an older step
                    // that failed already started the next one.
                    if step == launched - 1, launched < steps.count {
                        launchNext()
                    }
                }
            }
            throw noResults
        }
    }

    /// One step of the chain: its text, or nil so the chain moves on. A
    /// cancelled search stops the chain instead: an Escape must not try each
    /// later backend and end on "No results from ...". URLSession reports a
    /// cancelled task as `URLError.cancelled`, so the task's own flag is
    /// checked after any failure too.
    private static func attempt(
        _ step: @Sendable () async throws -> String
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
        if provider == .deepseek {
            return "Add a DeepSeek API key in Models \u{203A} Provider."
        }
        return "Add a \(provider.title) API key in Models \u{203A} Web search."
    }
}
