import Testing
import Foundation
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
        // Far beyond the 10ms timeout so scheduler starvation under a full
        // parallel test run can never deliver the answer before the
        // watchdog fires (this raced twice at 1s). Cancellation tears the
        // mock stream down, so the test still finishes in milliseconds.
        await ai.setDelay(.seconds(30))
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

    @Test func theFallbackAnswerIsPersistedInTheArchive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-fallback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let search = FakeWebSearchService(result: """
        ## [1] NBA Schedule
        URL: https://www.nba.com/schedule
        Snippet: Official game schedule.
        """)
        let ai = MockQuickService()
        await ai.setDelay(.seconds(30))
        await ai.setResponses([StreamDelta(text: "Too late", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let vm = QuickViewModel(
            settings: settings,
            service: ai,
            webSearchService: search,
            archiveRootURL: directory
        )
        vm.webAnswerTimeout = .milliseconds(10)
        vm.input = "when is the next NBA game?"

        await vm.submit()

        let archive = try #require(vm.chatArchive)
        let record = try #require(try await archive.loadAll().first)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.request?.status == .failed)
        #expect(answer.text.contains("https://www.nba.com/schedule"))
    }

    // MARK: - Recency questions search first

    @Test func aTypedRecencyQuestionSearchesBeforeTheModel() async {
        let search = FakeWebSearchService(result: "## Swift 6.2 released\nURL: https://swift.org/blog\nSnippet: Swift 6.2 is out.")
        let ai = MockQuickService()
        await ai.setResponses([StreamDelta(text: "Swift 6.2.", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, webSearchService: search)
        vm.input = "what is the latest version of Swift"

        await vm.submit()

        #expect(await search.lastQuery == "what is the latest version of Swift")
        #expect(await ai.lastPrompt?.contains("https://swift.org/blog") == true)
    }

    @Test func aRecencyQuestionAboutASelectionLeavesSearchToTheModel() async {
        let search = FakeWebSearchService(result: "## R\nURL: https://example.com")
        let ai = MockQuickService()
        await ai.setResponses([StreamDelta(text: "From the selection.", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, webSearchService: search)
        var context = CaptureContext(appName: "Claude")
        context.selectedText = "Release notes for build 42"
        vm.pendingContext = context
        vm.input = "what is the latest change here"

        await vm.submit()

        #expect(await search.lastQuery == nil, "the search would replace the prompt and drop the selection")
        #expect(await ai.lastPrompt?.contains("Release notes for build 42") == true)
    }

    @Test func aRecencyFollowUpLeavesSearchToTheModel() async {
        let search = FakeWebSearchService(result: "## R\nURL: https://example.com")
        let ai = MockQuickService()
        await ai.setResponses([StreamDelta(text: "First.", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, webSearchService: search)
        vm.input = "explain the release train"
        await vm.submit()
        await ai.setResponses([StreamDelta(text: "The newest is 42.", finishReason: "stop")])
        vm.input = "which is the newest one?"

        await vm.submit()

        #expect(await search.lastQuery == nil, "a follow-up leans on the thread")
        #expect(vm.output == "The newest is 42.")
    }

    @Test func aRecencyQuestionWithoutWebSearchGoesStraightToTheModel() async {
        let ai = MockQuickService()
        await ai.setResponses([StreamDelta(text: "Argentina.", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai)
        vm.input = "who won the most recent world cup"

        await vm.submit()

        #expect(vm.errorMessage == nil)
        #expect(vm.output == "Argentina.")
    }

    @Test func aFailedRecencySearchLeavesTheAnswerToTheModel() async {
        let search = FailingWebSearchService()
        let ai = MockQuickService()
        await ai.setResponses([StreamDelta(text: "Swift 6.2.", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, webSearchService: search)
        vm.input = "what is the latest version of Swift"

        await vm.submit()

        #expect(vm.errorMessage == nil)
        #expect(vm.output == "Swift 6.2.")
        #expect(await ai.lastPrompt == "what is the latest version of Swift")
    }

    @Test func aFailedExplicitSearchStillStopsTheAsk() async {
        let ai = MockQuickService()
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: ai, webSearchService: FailingWebSearchService())
        vm.input = "latest news about Apple"

        await vm.submit()

        #expect(vm.errorMessage != nil)
        #expect(await ai.sendCallCount == 0)
        #expect(vm.input == "latest news about Apple")
    }

    // MARK: - The search-results fallback

    @Test func theFallbackListsTheResultsTheBackendsWrite() throws {
        let bundle = try WebSearchResultText.format([
            .init(title: "Swift 6.2 released", url: "https://swift.org/blog", snippet: "Swift 6.2 is out."),
            .init(title: "Release notes", url: "https://example.com/notes", snippet: nil),
        ])

        let markdown = QuickViewModel.webSearchFallbackMarkdown(bundle)

        #expect(markdown == """
        Search results:

        - [Swift 6.2 released](https://swift.org/blog)
          Swift 6.2 is out.
        - [Release notes](https://example.com/notes)
        """)
    }

    @Test func theFallbackStillReadsNumberedHeadings() {
        let markdown = QuickViewModel.webSearchFallbackMarkdown("## [1] NBA Schedule\nURL: https://www.nba.com/schedule")
        #expect(markdown.contains("- [NBA Schedule](https://www.nba.com/schedule)"))
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

private struct FailingWebSearchService: WebSearchServicing {
    func search(_ query: String) async throws -> String {
        throw WebSearchError.failed("No results from DeepSeek")
    }
}
