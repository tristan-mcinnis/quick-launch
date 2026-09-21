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

    // MARK: - Bocha

    @Test func bochaSendsBearerKeyAndFormatsResults() async throws {
        let recorder = RequestRecorder(status: 200, body: Data("""
        {"code":200,"data":{"webPages":{"value":[
          {"name":"Bocha 来源","url":"https://example.cn/b","snippet":"片段","summary":"摘要"}
        ]}}}
        """.utf8))
        let service = BochaSearchService(apiKey: { "bocha-test" }, transport: recorder.transport)

        let result = try await service.search("上海咖啡")

        #expect(result.contains("## Bocha 来源"))
        #expect(result.contains("URL: https://example.cn/b"))
        #expect(result.contains("Snippet: 摘要"), "the summary is preferred over the snippet")
        let request = try #require(recorder.request)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer bocha-test")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["query"] as? String == "上海咖啡")
    }

    @Test func bochaWithoutKeyFailsBeforeAnyRequest() async {
        let recorder = RequestRecorder(status: 200, body: Data("{}".utf8))
        let service = BochaSearchService(apiKey: { nil }, transport: recorder.transport)

        await #expect(throws: WebSearchError.self) {
            _ = try await service.search("x")
        }
        #expect(recorder.request == nil)
    }

    @Test func bochaApiErrorCodeIsReported() async {
        let recorder = RequestRecorder(status: 200, body: Data(#"{"code":403,"message":"bad key","data":null}"#.utf8))
        let service = BochaSearchService(apiKey: { "k" }, transport: recorder.transport)

        await #expect(throws: WebSearchError.self) {
            _ = try await service.search("x")
        }
    }

    // MARK: - Exa

    @Test func exaSendsApiKeyAndFormatsResults() async throws {
        let recorder = RequestRecorder(status: 200, body: Data("""
        {"results":[{"title":"Exa Source","url":"https://example.com/e","text":"Exa passage"}]}
        """.utf8))
        let service = ExaSearchService(apiKey: { "exa-test" }, transport: recorder.transport)

        let result = try await service.search("semantic question")

        #expect(result.contains("## Exa Source"))
        #expect(result.contains("Snippet: Exa passage"))
        let request = try #require(recorder.request)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "exa-test")
    }

    @Test func exaWithoutKeyFailsBeforeAnyRequest() async {
        let recorder = RequestRecorder(status: 200, body: Data("{}".utf8))
        let service = ExaSearchService(apiKey: { nil }, transport: recorder.transport)

        await #expect(throws: WebSearchError.self) {
            _ = try await service.search("x")
        }
        #expect(recorder.request == nil)
    }

    // MARK: - Router and chain

    @Test func explicitBackendsRequireTheirStoredKey() async {
        let tavily = RecordingStubSearch(.text("tavily"))
        let bocha = RecordingStubSearch(.text("bocha"))
        let exa = RecordingStubSearch(.text("exa"))

        for provider in [WebSearchProvider.tavily, .brave, .bocha, .exa] {
            let router = makeRouter(tavily: tavily, bocha: bocha, exa: exa)
            await #expect(throws: WebSearchError.self) {
                _ = try await router.search("q", provider: provider)
            }
        }
        #expect(await tavily.callCount() == 0)
        #expect(await bocha.callCount() == 0)
        #expect(await exa.callCount() == 0)
    }

    @Test func explicitBackendsRouteToTheirOwnService() async throws {
        let searxng = RecordingStubSearch(.text("searxng result"))
        let brave = RecordingStubSearch(.text("brave result"))
        let bocha = RecordingStubSearch(.text("bocha result"))
        let exa = RecordingStubSearch(.text("exa result"))
        let router = makeRouter(
            searxng: searxng,
            brave: brave,
            bocha: bocha,
            exa: exa,
            hasBraveKey: true,
            hasBochaKey: true,
            hasExaKey: true
        )

        #expect(try await router.search("q", provider: .bing) == "searxng result")
        #expect(try await router.search("q", provider: .brave) == "brave result")
        #expect(try await router.search("q", provider: .bocha) == "bocha result")
        #expect(try await router.search("q", provider: .exa) == "exa result")
        #expect(await searxng.callCount() == 1)
        #expect(await brave.callCount() == 1)
        #expect(await bocha.callCount() == 1)
        #expect(await exa.callCount() == 1)
    }

    @Test func chainPrefersTavilyWhenItsKeyExists() async throws {
        let tavily = RecordingStubSearch(.text("tavily result"))
        let searxng = RecordingStubSearch(.text("searxng result"))
        let router = makeRouter(
            searxng: searxng,
            tavily: tavily,
            hasTavilyKey: true,
            hasBraveKey: true
        )

        #expect(try await router.search("q", provider: .automatic) == "tavily result")
        #expect(await searxng.callCount() == 0)
    }

    @Test func chainPrefersBochaForAChineseQuery() async throws {
        let bocha = RecordingStubSearch(.text("bocha result"))
        let tavily = RecordingStubSearch(.text("tavily result"))
        let router = makeRouter(
            tavily: tavily,
            bocha: bocha,
            hasTavilyKey: true,
            hasBochaKey: true
        )

        #expect(try await router.search("上海咖啡推荐", provider: .automatic) == "bocha result")
        #expect(await tavily.callCount() == 0)
    }

    @Test func chainKeepsTheEnglishOrderForANonChineseQuery() async throws {
        let bocha = RecordingStubSearch(.text("bocha result"))
        let tavily = RecordingStubSearch(.text("tavily result"))
        let router = makeRouter(
            tavily: tavily,
            bocha: bocha,
            hasTavilyKey: true,
            hasBochaKey: true
        )

        #expect(try await router.search("shanghai coffee", provider: .automatic) == "tavily result")
        #expect(await bocha.callCount() == 0)
    }

    @Test func chainSkipsTavilyWithoutAKey() async throws {
        let tavily = RecordingStubSearch(.text("tavily result"))
        let searxng = RecordingStubSearch(.text("searxng result"))
        let router = makeRouter(searxng: searxng, tavily: tavily)

        #expect(try await router.search("q", provider: .automatic) == "searxng result")
        #expect(await tavily.callCount() == 0)
    }

    @Test func chainFallsThroughAnEmptyOrFailingStepToBrave() async throws {
        let searxng = RecordingStubSearch(.failure)
        let brave = RecordingStubSearch(.text("brave result"))
        let router = makeRouter(
            searxng: searxng,
            tavily: RecordingStubSearch(.empty),
            brave: brave,
            hasTavilyKey: true,
            hasBraveKey: true
        )

        #expect(try await router.search("q", provider: .automatic) == "brave result")
        #expect(await searxng.callCount() == 1)
        #expect(await brave.callCount() == 1)
    }

    @Test func chainThrowsWhenEveryStepFails() async {
        let router = makeRouter(
            hasTavilyKey: true,
            hasBraveKey: true,
            hasBochaKey: true,
            hasExaKey: true
        )

        await #expect(throws: WebSearchError.self) {
            _ = try await router.search("q", provider: .automatic)
        }
    }

    @Test func chineseLaneDetectionFollowsIdeographsOnly() {
        #expect(WebSearchQuery.containsCJK("上海咖啡"))
        #expect(WebSearchQuery.containsCJK("東京"))
        #expect(!WebSearchQuery.containsCJK("こんにちは"))
        #expect(!WebSearchQuery.containsCJK("안녕하세요"))
        #expect(!WebSearchQuery.containsCJK("shanghai"))
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

    /// A router with every backend stubbed, so each test states only the
    /// backends and keys it cares about. Unset steps are unavailable.
    private func makeRouter(
        searxng: RecordingStubSearch = RecordingStubSearch(.failure),
        tavily: RecordingStubSearch = RecordingStubSearch(.failure),
        brave: RecordingStubSearch = RecordingStubSearch(.failure),
        bocha: RecordingStubSearch = RecordingStubSearch(.failure),
        exa: RecordingStubSearch = RecordingStubSearch(.failure),
        hasTavilyKey: Bool = false,
        hasBraveKey: Bool = false,
        hasBochaKey: Bool = false,
        hasExaKey: Bool = false
    ) -> WebSearchRouter {
        WebSearchRouter(
            searxng: searxng,
            tavily: tavily,
            brave: brave,
            bocha: bocha,
            exa: exa,
            hasTavilyKey: { hasTavilyKey },
            hasBraveKey: { hasBraveKey },
            hasBochaKey: { hasBochaKey },
            hasExaKey: { hasExaKey }
        )
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
