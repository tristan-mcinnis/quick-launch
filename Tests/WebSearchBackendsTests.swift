import Foundation
import Testing
@testable import QuickLaunch

@Suite("Web search backends")
struct WebSearchBackendsTests {

    // MARK: - Tavily

    @Test func tavilySendsBearerKeyAndFormatsResults() async throws {
        let recorder = RequestRecorder(status: 200, body: Data("""
        {"results":[{"title":"Tavily Source","url":"https://example.com/t","content":"Tavily snippet"}]}
        """.utf8))
        let service = TavilySearchService(apiKey: { "tvly-test" }, transport: recorder.transport)

        let result = try await service.search("what is new")

        #expect(result.contains("## Tavily Source"))
        #expect(result.contains("URL: https://example.com/t"))
        #expect(result.contains("Snippet: Tavily snippet"))
        let request = try #require(recorder.request)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tvly-test")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["query"] as? String == "what is new")
    }

    @Test func tavilyWithoutKeyFailsBeforeAnyRequest() async {
        let recorder = RequestRecorder(status: 200, body: Data(#"{"results":[]}"#.utf8))
        let service = TavilySearchService(apiKey: { nil }, transport: recorder.transport)

        await #expect(throws: WebSearchError.self) {
            _ = try await service.search("x")
        }
        #expect(recorder.request == nil)
    }

    @Test func tavilyHTTPErrorIsReported() async {
        let recorder = RequestRecorder(status: 429, body: Data("{}".utf8))
        let service = TavilySearchService(apiKey: { "k" }, transport: recorder.transport)

        await #expect(throws: WebSearchError.self) {
            _ = try await service.search("x")
        }
    }

    @Test func tavilyEmptyResultsAreEmpty() async {
        let recorder = RequestRecorder(status: 200, body: Data(#"{"results":[]}"#.utf8))
        let service = TavilySearchService(apiKey: { "k" }, transport: recorder.transport)

        await #expect(throws: WebSearchError.self) {
            _ = try await service.search("x")
        }
    }

    // MARK: - Brave

    @Test func braveSendsSubscriptionTokenAndFormatsResults() async throws {
        let recorder = RequestRecorder(status: 200, body: Data("""
        {"web":{"results":[{"title":"Brave Source","url":"https://example.com/b","description":"Brave snippet"}]}}
        """.utf8))
        let service = BraveSearchService(apiKey: { "brave-test" }, transport: recorder.transport)

        let result = try await service.search("query words")

        #expect(result.contains("## Brave Source"))
        #expect(result.contains("Snippet: Brave snippet"))
        let request = try #require(recorder.request)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == "brave-test")
        #expect(request.url?.query?.contains("q=query") == true)
    }

    @Test func braveWithoutKeyFailsBeforeAnyRequest() async {
        let recorder = RequestRecorder(status: 200, body: Data("{}".utf8))
        let service = BraveSearchService(apiKey: { "" }, transport: recorder.transport)

        await #expect(throws: WebSearchError.self) {
            _ = try await service.search("x")
        }
        #expect(recorder.request == nil)
    }

    // MARK: - Router and chain

    @Test func explicitTavilyRequiresAStoredKey() async {
        let tavily = RecordingStubSearch(.text("tavily"))
        let router = WebSearchRouter(
            searxng: RecordingStubSearch(.text("searxng")),
            tavily: tavily,
            brave: RecordingStubSearch(.text("brave")),
            hasTavilyKey: { false },
            hasBraveKey: { false }
        )

        await #expect(throws: WebSearchError.self) {
            _ = try await router.search("q", provider: .tavily)
        }
        #expect(await tavily.callCount() == 0)
    }

    @Test func explicitSearXNGAndBraveRouteToTheirBackend() async throws {
        let searxng = RecordingStubSearch(.text("searxng result"))
        let brave = RecordingStubSearch(.text("brave result"))
        let router = WebSearchRouter(
            searxng: searxng,
            tavily: RecordingStubSearch(.failure),
            brave: brave,
            hasTavilyKey: { false },
            hasBraveKey: { true }
        )

        #expect(try await router.search("q", provider: .bing) == "searxng result")
        #expect(try await router.search("q", provider: .brave) == "brave result")
        #expect(await searxng.callCount() == 1)
        #expect(await brave.callCount() == 1)
    }

    @Test func chainPrefersTavilyWhenItsKeyExists() async throws {
        let tavily = RecordingStubSearch(.text("tavily result"))
        let searxng = RecordingStubSearch(.text("searxng result"))
        let router = WebSearchRouter(
            searxng: searxng,
            tavily: tavily,
            brave: RecordingStubSearch(.text("brave result")),
            hasTavilyKey: { true },
            hasBraveKey: { true }
        )

        #expect(try await router.search("q", provider: .automatic) == "tavily result")
        #expect(await searxng.callCount() == 0)
    }

    @Test func chainSkipsTavilyWithoutAKey() async throws {
        let tavily = RecordingStubSearch(.text("tavily result"))
        let searxng = RecordingStubSearch(.text("searxng result"))
        let router = WebSearchRouter(
            searxng: searxng,
            tavily: tavily,
            brave: RecordingStubSearch(.text("brave result")),
            hasTavilyKey: { false },
            hasBraveKey: { false }
        )

        #expect(try await router.search("q", provider: .automatic) == "searxng result")
        #expect(await tavily.callCount() == 0)
    }

    @Test func chainFallsThroughAnEmptyOrFailingStepToBrave() async throws {
        let searxng = RecordingStubSearch(.failure)
        let brave = RecordingStubSearch(.text("brave result"))
        let router = WebSearchRouter(
            searxng: searxng,
            tavily: RecordingStubSearch(.empty),
            brave: brave,
            hasTavilyKey: { true },
            hasBraveKey: { true }
        )

        #expect(try await router.search("q", provider: .automatic) == "brave result")
        #expect(await searxng.callCount() == 1)
        #expect(await brave.callCount() == 1)
    }

    @Test func chainThrowsWhenEveryStepFails() async {
        let router = WebSearchRouter(
            searxng: RecordingStubSearch(.failure),
            tavily: RecordingStubSearch(.empty),
            brave: RecordingStubSearch(.failure),
            hasTavilyKey: { true },
            hasBraveKey: { true }
        )

        await #expect(throws: WebSearchError.self) {
            _ = try await router.search("q", provider: .automatic)
        }
    }

    // MARK: - Shared formatting

    @Test func resultTextKeepsFiveRowsAndSkipsIncompleteOnes() throws {
        let rows = (0..<7).map {
            WebSearchResultText.Row(title: "T\($0)", url: "https://example.com/\($0)", snippet: "S\($0)")
        } + [WebSearchResultText.Row(title: nil, url: "https://example.com/x", snippet: nil)]

        let text = try WebSearchResultText.format(rows)

        #expect(text.contains("## T4"))
        #expect(!text.contains("## T5"))
        #expect(!text.contains("https://example.com/x"))
    }
}

/// Records the last request a direct API transport saw.
private final class RequestRecorder: @unchecked Sendable {
    private let state = RequestRecorderState()
    let transport: WebSearchHTTPTransport

    init(status: Int, body: Data) {
        let state = self.state
        transport = { request in
            state.record(request)
            return (body, status)
        }
    }

    var request: URLRequest? { state.request }
}

/// Lock-protected slot for the last request.
private final class RequestRecorderState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?

    func record(_ request: URLRequest) {
        lock.withLock { value = request }
    }

    var request: URLRequest? {
        lock.withLock { value }
    }
}

/// A WebSearchServicing stub with one fixed outcome and a call count.
private actor RecordingStubSearch: WebSearchServicing {
    enum Outcome: Sendable {
        case text(String)
        case empty
        case failure
    }

    private let outcome: Outcome
    private var calls: [String] = []

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func callCount() -> Int { calls.count }

    func search(_ query: String) async throws -> String {
        calls.append(query)
        switch outcome {
        case .text(let value): return value
        case .empty: throw WebSearchError.empty
        case .failure: throw WebSearchError.failed("stub failure")
        }
    }
}
