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

    // MARK: - DeepSeek

    @Test func deepSeekSendsBearerKeyAndPrefersTheModelSummary() async throws {
        let recorder = RequestRecorder(status: 200, body: Data("""
        {"results":[{"title":"DS Source","url":"https://example.com/d","snippet":"short","summary":"long summary for the model","content":""}]}
        """.utf8))
        let service = DeepSeekSearchService(apiKey: { "sk-test" }, transport: recorder.transport)

        let result = try await service.search("  what is new  ")

        #expect(result.contains("## DS Source"))
        #expect(result.contains("URL: https://example.com/d"))
        #expect(result.contains("Snippet: long summary for the model"))
        let request = try #require(recorder.request)
        #expect(request.url == DeepSeekSearchService.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["query"] as? String == "what is new")
        #expect(json["count"] as? Int == 5)
    }

    @Test func deepSeekCutsTheQueryToTheAPILimitInScalars() async throws {
        let recorder = RequestRecorder(status: 200, body: Data("""
        {"results":[{"title":"T","url":"https://example.com","snippet":"only a snippet"}]}
        """.utf8))
        let service = DeepSeekSearchService(apiKey: { "k" }, transport: recorder.transport)

        // Each thumbs-up with a skin tone is one Character but two scalars.
        let result = try await service.search(String(repeating: "👍🏽", count: 200))

        let body = try #require(recorder.request?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try #require(json["query"] as? String)
        #expect(sent.unicodeScalars.count <= DeepSeekSearchService.maxQueryLength)
        #expect(sent.unicodeScalars.count >= DeepSeekSearchService.maxQueryLength - 1)
        #expect(result.contains("Snippet: only a snippet"), "no summary falls back to the snippet")
    }

    @Test func deepSeekNeverSendsABlankQuery() async {
        let recorder = RequestRecorder(status: 200, body: Data(#"{"results":[]}"#.utf8))
        let service = DeepSeekSearchService(apiKey: { "k" }, transport: recorder.transport)

        await #expect(throws: WebSearchError.self) { _ = try await service.search("  \n ") }
        #expect(recorder.request == nil)
    }

    @Test func deepSeekWithoutKeyFailsBeforeAnyRequest() async {
        let recorder = RequestRecorder(status: 200, body: Data(#"{"results":[]}"#.utf8))
        let service = DeepSeekSearchService(apiKey: { " " }, transport: recorder.transport)

        await #expect(throws: WebSearchError.self) {
            _ = try await service.search("x")
        }
        #expect(recorder.request == nil)
    }

    @Test func deepSeekBalanceErrorAndEmptyResultsThrow() async {
        let unpaid = DeepSeekSearchService(
            apiKey: { "k" },
            transport: RequestRecorder(status: 402, body: Data("{}".utf8)).transport
        )
        let error = await #expect(throws: WebSearchError.self) {
            _ = try await unpaid.search("x")
        }
        #expect(error?.errorDescription == "Web search failed: " + "DeepSeek balance is empty")
        let limited = DeepSeekSearchService(
            apiKey: { "k" },
            transport: RequestRecorder(status: 429, body: Data("{}".utf8)).transport
        )
        let limitError = await #expect(throws: WebSearchError.self) {
            _ = try await limited.search("x")
        }
        #expect(limitError?.errorDescription == "Web search failed: " + "DeepSeek search is rate-limited")

        let empty = DeepSeekSearchService(
            apiKey: { "k" },
            transport: RequestRecorder(status: 200, body: Data(#"{"results":[]}"#.utf8)).transport
        )
        await #expect(throws: WebSearchError.self) { _ = try await empty.search("x") }
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
        let tavily = RecordingStubSearch(.text("tavily result"))
        let brave = RecordingStubSearch(.text("brave result"))
        let bocha = RecordingStubSearch(.text("bocha result"))
        let exa = RecordingStubSearch(.text("exa result"))
        let router = makeRouter(
            tavily: tavily,
            brave: brave,
            bocha: bocha,
            exa: exa,
            hasTavilyKey: true,
            hasBraveKey: true,
            hasBochaKey: true,
            hasExaKey: true
        )

        #expect(try await router.search("q", provider: .tavily) == "tavily result")
        #expect(try await router.search("q", provider: .brave) == "brave result")
        #expect(try await router.search("q", provider: .bocha) == "bocha result")
        #expect(try await router.search("q", provider: .exa) == "exa result")
        #expect(await tavily.callCount() == 1)
        #expect(await brave.callCount() == 1)
        #expect(await bocha.callCount() == 1)
        #expect(await exa.callCount() == 1)
    }

    @Test func automaticIsTheDefaultAndTriesDeepSeekFirst() async throws {
        #expect(QuickSettings().webSearchProvider == .automatic)
        let deepseek = RecordingStubSearch(.text("deepseek result"))
        let bocha = RecordingStubSearch(.text("bocha result"))
        let tavily = RecordingStubSearch(.text("tavily result"))
        let router = makeRouter(
            deepseek: deepseek,
            tavily: tavily,
            bocha: bocha,
            hasDeepSeekKey: true,
            hasTavilyKey: true,
            hasBochaKey: true
        )

        #expect(try await router.search("上海咖啡", provider: .automatic) == "deepseek result")
        #expect(try await router.search("q", provider: .automatic) == "deepseek result")
        #expect(await bocha.callCount() == 0)
        #expect(await tavily.callCount() == 0)
    }

    @Test func chainFallsBackFromAFailingDeepSeekToTavily() async throws {
        let deepseek = RecordingStubSearch(.failure)
        let router = makeRouter(
            deepseek: deepseek,
            tavily: RecordingStubSearch(.text("tavily result")),
            hasDeepSeekKey: true,
            hasTavilyKey: true
        )

        #expect(try await router.search("q", provider: .automatic) == "tavily result")
        #expect(await deepseek.callCount() == 1)
    }

    @Test func choosingDeepSeekWithoutAKeyNamesWhereTheKeyLives() async {
        let deepseek = RecordingStubSearch(.text("deepseek result"))
        let router = makeRouter(deepseek: deepseek)

        let error = await #expect(throws: WebSearchError.self) {
            _ = try await router.search("q", provider: .deepseek)
        }
        #expect(error?.errorDescription == "Web search failed: " + "Add a DeepSeek API key in Models \u{203A} Provider.")
        #expect(await deepseek.callCount() == 0)
    }

    @Test func choosingDeepSeekNeverFallsBack() async {
        let tavily = RecordingStubSearch(.text("tavily result"))
        let router = makeRouter(
            deepseek: RecordingStubSearch(.failure),
            tavily: tavily,
            hasDeepSeekKey: true,
            hasTavilyKey: true
        )

        await #expect(throws: WebSearchError.self) {
            _ = try await router.search("q", provider: .deepseek)
        }
        #expect(await tavily.callCount() == 0)
    }

    @Test func chainPrefersTavilyWhenItsKeyExists() async throws {
        let tavily = RecordingStubSearch(.text("tavily result"))
        let brave = RecordingStubSearch(.text("brave result"))
        let router = makeRouter(
            tavily: tavily,
            brave: brave,
            hasTavilyKey: true,
            hasBraveKey: true
        )

        #expect(try await router.search("q", provider: .automatic) == "tavily result")
        #expect(await brave.callCount() == 0)
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
        let brave = RecordingStubSearch(.text("brave result"))
        let router = makeRouter(tavily: tavily, brave: brave, hasBraveKey: true)

        #expect(try await router.search("q", provider: .automatic) == "brave result")
        #expect(await tavily.callCount() == 0)
    }

    @Test func chainFallsThroughAnEmptyOrFailingStepToBrave() async throws {
        let emptyRouter = makeRouter(
            tavily: RecordingStubSearch(.empty),
            brave: RecordingStubSearch(.text("brave after empty")),
            hasTavilyKey: true,
            hasBraveKey: true
        )
        #expect(try await emptyRouter.search("q", provider: .automatic) == "brave after empty")

        let brave = RecordingStubSearch(.text("brave after failure"))
        let failingRouter = makeRouter(
            tavily: RecordingStubSearch(.failure),
            brave: brave,
            hasTavilyKey: true,
            hasBraveKey: true
        )
        #expect(try await failingRouter.search("q", provider: .automatic) == "brave after failure")
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

    @Test func aCancelledStepStopsTheChain() async {
        let brave = RecordingStubSearch(.text("brave result"))
        let router = makeRouter(
            tavily: RecordingStubSearch(.cancelled),
            brave: brave,
            hasTavilyKey: true,
            hasBraveKey: true
        )

        await #expect(throws: CancellationError.self) {
            _ = try await router.search("q", provider: .automatic)
        }
        #expect(await brave.callCount() == 0)
    }

    @Test func aSearchCancelledMidRequestTriesNoLaterBackend() async {
        let brave = RecordingStubSearch(.text("brave result"))
        let router = makeRouter(
            tavily: RecordingStubSearch(.cancelsTheTask),
            brave: brave,
            hasTavilyKey: true,
            hasBraveKey: true
        )

        let search = Task { try await router.search("q", provider: .automatic) }
        await #expect(throws: CancellationError.self) {
            _ = try await search.value
        }
        #expect(await brave.callCount() == 0)
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
        deepseek: RecordingStubSearch = RecordingStubSearch(.failure),
        tavily: RecordingStubSearch = RecordingStubSearch(.failure),
        brave: RecordingStubSearch = RecordingStubSearch(.failure),
        bocha: RecordingStubSearch = RecordingStubSearch(.failure),
        exa: RecordingStubSearch = RecordingStubSearch(.failure),
        hasDeepSeekKey: Bool = false,
        hasTavilyKey: Bool = false,
        hasBraveKey: Bool = false,
        hasBochaKey: Bool = false,
        hasExaKey: Bool = false
    ) -> WebSearchRouter {
        WebSearchRouter(
            deepseek: deepseek,
            tavily: tavily,
            brave: brave,
            bocha: bocha,
            exa: exa,
            hasDeepSeekKey: { hasDeepSeekKey },
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
        /// The step itself is cancelled.
        case cancelled
        /// The search task is cancelled mid-request, and the request fails
        /// the way URLSession reports it.
        case cancelsTheTask
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
        case .cancelled: throw CancellationError()
        case .cancelsTheTask:
            withUnsafeCurrentTask { $0?.cancel() }
            throw URLError(.cancelled)
        }
    }
}
