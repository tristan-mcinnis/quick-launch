import Testing
@testable import QuickLaunch

@Suite("Web search workflow", .serialized)
@MainActor
struct WebSearchWorkflowTests {
    @Test func liveSportsQuestionUsesSearchBeforeAI() async {
        let search = FakeWebSearchService(result: """
        ## [1] NBA schedule
        URL: https://www.nba.com/schedule
        Snippet: The next preseason game is October 3, 2026.
        """)
        let ai = MockQuickService()
        await ai.setResponses([
            StreamDelta(text: "The next listed game is October 3, 2026. [NBA](https://www.nba.com/schedule)", finishReason: "stop")
        ])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, webSearchService: search)
        vm.input = "when is the next NBA game?"

        await vm.submit()

        #expect(await search.lastQuery == "when is the next NBA game?")
        #expect(await ai.lastPrompt?.contains("https://www.nba.com/schedule") == true)
        #expect(vm.output.contains("October 3, 2026"))
        #expect(vm.currentConversation?.messages.first?.content == "when is the next NBA game?")
    }

    @Test func explicitSearchAliasAlwaysUsesSearch() async {
        let search = FakeWebSearchService(result: "## [1] Result\nURL: https://example.com")
        let ai = MockQuickService()
        await ai.setResponses([StreamDelta(text: "Found it", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, webSearchService: search)
        vm.input = "/search obscure release notes"

        await vm.submit()

        #expect(await search.lastQuery == "obscure release notes")
        #expect(vm.output == "Found it")
    }

    @Test func slowModelFallsBackToLinkedSearchResults() async {
        let search = FakeWebSearchService(result: """
        ## [1] NBA Schedule
        URL: https://www.nba.com/schedule
        Snippet: Official game schedule.
        """)
        let ai = MockQuickService()
        await ai.setDelay(.seconds(1))
        await ai.setResponses([StreamDelta(text: "Too late", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, webSearchService: search)
        vm.webAnswerTimeout = .milliseconds(10)
        vm.input = "when is the next NBA game?"

        await vm.submit()

        #expect(vm.output.contains("[NBA Schedule](https://www.nba.com/schedule)"))
        #expect(vm.errorMessage?.contains("too long") == true)
        #expect(vm.isStreaming == false)
    }
}

private actor FakeWebSearchService: WebSearchServicing {
    let result: String
    var lastQuery: String?

    init(result: String) {
        self.result = result
    }

    func search(_ query: String) async throws -> String {
        lastQuery = query
        return result
    }
}
