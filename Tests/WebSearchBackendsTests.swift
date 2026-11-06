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

    // MARK: - The hedged chain (an injected clock: no hedge fires unless the test fires it)

    @Test(.timeLimit(.minutes(1)))
    func aStalledStepStartsTheNextBesideItAndTheFirstTextWins() async throws {
        let deepseek = RecordingStubSearch(.stalls)
        let tavily = RecordingStubSearch(.text("tavily result"))
        let hedge = HedgeClock()
        let router = makeRouter(deepseek: deepseek, tavily: tavily, hasDeepSeekKey: true, hasTavilyKey: true, hedge: hedge)

        let search = Task { try await router.search("q", provider: .automatic) }
        await deepseek.waitUntilCalled()
        #expect(await tavily.callCount() == 0, "nothing else starts before the hedge delay")
        await hedge.fire()

        #expect(try await search.value == "tavily result")
        #expect(await deepseek.wasCancelled(), "the stalled step is cancelled once another answers")
    }

    @Test(.timeLimit(.minutes(1)))
    func aStalledStepThatAnswersFirstAfterTheHedgeStillWins() async throws {
        let deepseek = RecordingStubSearch(.waitsForRelease("deepseek result"))
        let tavily = RecordingStubSearch(.stalls)
        let hedge = HedgeClock()
        let router = makeRouter(deepseek: deepseek, tavily: tavily, hasDeepSeekKey: true, hasTavilyKey: true, hedge: hedge)

        let search = Task { try await router.search("q", provider: .automatic) }
        await deepseek.waitUntilCalled()
        await hedge.fire()
        await tavily.waitUntilCalled()
        await deepseek.release()

        #expect(try await search.value == "deepseek result")
        #expect(await tavily.wasCancelled())
    }

    @Test(.timeLimit(.minutes(1)))
    func aStepThatAnswersBeforeTheHedgeDelayStartsNothingElse() async throws {
        let tavily = RecordingStubSearch(.text("tavily result"))
        let router = makeRouter(
            deepseek: RecordingStubSearch(.text("deepseek result")),
            tavily: tavily,
            hasDeepSeekKey: true,
            hasTavilyKey: true
        )

        #expect(try await router.search("q", provider: .automatic) == "deepseek result")
        #expect(await tavily.callCount() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedStepStartsTheNextWithoutWaitingForTheHedge() async throws {
        // The hedge clock never fires here, so only the failure can move on.
        let router = makeRouter(
            deepseek: RecordingStubSearch(.failure),
            brave: RecordingStubSearch(.text("brave result")),
            bocha: RecordingStubSearch(.empty),
            hasDeepSeekKey: true,
            hasBraveKey: true,
            hasBochaKey: true
        )

        #expect(try await router.search("上海天气", provider: .automatic) == "brave result")
    }

    @Test(.timeLimit(.minutes(1)))
    func everyStepFailingAfterAHedgeStillThrowsNoResults() async throws {
        let deepseek = RecordingStubSearch(.waitsForRelease(nil))
        let tavily = RecordingStubSearch(.waitsForRelease(nil))
        let hedge = HedgeClock()
        let router = makeRouter(
            deepseek: deepseek,
            tavily: tavily,
            hasDeepSeekKey: true,
            hasTavilyKey: true,
            hedge: hedge
        )

        let search = Task { try await router.search("q", provider: .automatic) }
        await deepseek.waitUntilCalled()
        await hedge.fire()
        await tavily.waitUntilCalled()
        await deepseek.release()
        await tavily.release()

        do {
            _ = try await search.value
            Issue.record("expected no results")
        } catch let WebSearchError.failed(message) {
            #expect(message == "No results from DeepSeek, Tavily")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheSearchStopsEveryRunningStep() async throws {
        let deepseek = RecordingStubSearch(.stalls)
        let tavily = RecordingStubSearch(.stalls)
        let hedge = HedgeClock()
        let router = makeRouter(deepseek: deepseek, tavily: tavily, hasDeepSeekKey: true, hasTavilyKey: true, hedge: hedge)

        let search = Task { try await router.search("q", provider: .automatic) }
        await deepseek.waitUntilCalled()
        await hedge.fire()
        await tavily.waitUntilCalled()
        search.cancel()

        await #expect(throws: CancellationError.self) { _ = try await search.value }
        #expect(await deepseek.wasCancelled())
        #expect(await tavily.wasCancelled())
    }

    @Test(.timeLimit(.minutes(1)))
    func eachStalledStepHedgesToTheNextInOrder() async throws {
        let deepseek = RecordingStubSearch(.stalls)
        let bocha = RecordingStubSearch(.stalls)
        let tavily = RecordingStubSearch(.text("tavily result"))
        let hedge = HedgeClock()
        let router = makeRouter(
            deepseek: deepseek, tavily: tavily, bocha: bocha,
            hasDeepSeekKey: true, hasTavilyKey: true, hasBochaKey: true, hedge: hedge
        )

        let search = Task { try await router.search("上海天气", provider: .automatic) }
        await deepseek.waitUntilCalled()
        await hedge.fire()
        await bocha.waitUntilCalled()
        #expect(await tavily.callCount() == 0)
        await hedge.fire()

        #expect(try await search.value == "tavily result")
        #expect(await deepseek.wasCancelled())
        #expect(await bocha.wasCancelled())
    }

    @Test(.timeLimit(.minutes(1)))
    func anOlderStepFailingBesideAHedgedOneStartsNoThird() async throws {
        let deepseek = RecordingStubSearch(.waitsForRelease(nil))
        let tavily = RecordingStubSearch(.waitsForRelease("tavily result"))
        let brave = RecordingStubSearch(.text("brave result"))
        let hedge = HedgeClock()
        let router = makeRouter(
            deepseek: deepseek, tavily: tavily, brave: brave,
            hasDeepSeekKey: true, hasTavilyKey: true, hasBraveKey: true, hedge: hedge
        )

        let search = Task { try await router.search("q", provider: .automatic) }
        await deepseek.waitUntilCalled()
        await hedge.fire()
        await tavily.waitUntilCalled()
        await deepseek.release()
        await tavily.release()

        #expect(try await search.value == "tavily result")
        #expect(await brave.callCount() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func aLoneProviderIsWaitedForWithoutAHedge() async throws {
        let deepseek = RecordingStubSearch(.waitsForRelease("deepseek result"))
        let hedge = HedgeClock()
        let router = makeRouter(deepseek: deepseek, hasDeepSeekKey: true, hedge: hedge)

        let search = Task { try await router.search("q", provider: .automatic) }
        await deepseek.waitUntilCalled()
        await hedge.fire()
        await deepseek.release()

        #expect(try await search.value == "deepseek result")
    }

    @Test func aChosenProviderSkipsTheChain() async throws {
        let deepseek = RecordingStubSearch(.text("deepseek result"))
        let router = makeRouter(
            deepseek: deepseek,
            tavily: RecordingStubSearch(.text("tavily result")),
            hasDeepSeekKey: true,
            hasTavilyKey: true
        )

        #expect(try await router.search("q", provider: .tavily) == "tavily result")
        #expect(await deepseek.callCount() == 0)
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
        hasExaKey: Bool = false,
        hedge: HedgeClock = HedgeClock()
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
            hasExaKey: { hasExaKey },
            sleep: { _ in try await hedge.sleep() }
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
        /// Never answers until cancelled.
        case stalls
        /// Answers with this text (nil: empty) once `release()` is called.
        case waitsForRelease(String?)
    }

    private let outcome: Outcome
    private var calls: [String] = []
    private var cancelled = false
    private var calledWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func callCount() -> Int { calls.count }
    func wasCancelled() -> Bool { cancelled }

    func waitUntilCalled() async {
        if !calls.isEmpty { return }
        await withCheckedContinuation { calledWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    private func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func search(_ query: String) async throws -> String {
        calls.append(query)
        calledWaiters.forEach { $0.resume() }
        calledWaiters = []
        switch outcome {
        case .stalls:
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                cancelled = true
                throw error
            }
            throw WebSearchError.empty
        case .waitsForRelease(let text):
            await waitForRelease()
            guard let text else { throw WebSearchError.empty }
            return text
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

/// The chain's hedge clock under test: each `fire()` lets one hedge delay
/// pass (the one waiting, or the next to start), and a delay the test never
/// fires never passes.
private actor HedgeClock {
    private var credits = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []

    /// Ends when the test fires the clock or the waiting task is cancelled.
    func sleep() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if credits > 0 || Task.isCancelled {
                    if credits > 0, !Task.isCancelled { credits -= 1 }
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.wake(id) }
        }
        try Task.checkCancellation()
    }

    func fire() {
        if waiters.isEmpty {
            credits += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func wake(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }
}
