import Testing
@testable import HouseChatCore

@Suite("Context policy")
struct ContextPolicyTests {
    private let policy = ContextPolicy.standard

    private func request(
        source: Bool = true,
        history: Int = 0,
        historySources: Bool = false,
        question: String,
        override: ContextOverride? = nil
    ) -> ContextRequest {
        ContextRequest(
            hasCurrentSource: source,
            currentSourceCount: source ? 1 : 0,
            historyTurnCount: history,
            historyHasSources: historySources,
            question: question,
            override: override
        )
    }

    @Test("A source with a neutral question is source-first and only offers history")
    func sourceFirst() {
        let decision = policy.resolve(request(history: 3, historySources: true, question: "What does the report say about revenue?"))

        #expect(decision.execution == .currentSource)
        #expect(decision.sourceFirst)
        #expect(decision.includesHistory == false)
        #expect(decision.offered == [.history, .currentSourceAndHistory])
        #expect(decision.intent.asksForBroadSummary == false)
        #expect(decision.rationale.contains("source-first"))
    }

    @Test("An explicit history question widens to the current source and history")
    func englishHistoryQuestion() {
        let decision = policy.resolve(request(history: 2, historySources: true, question: "Compare this with the earlier file"))

        #expect(decision.execution == .currentSourceAndHistory)
        #expect(decision.includesHistory)
        #expect(decision.sourceFirst)
        #expect(decision.offered.isEmpty)
        #expect(decision.intent.asksAboutHistory)
        #expect(decision.intent.asksForComparison)
    }

    @Test("A CJK history question widens the same way")
    func cjkHistoryQuestion() {
        let decision = policy.resolve(request(history: 4, historySources: true, question: "和上次对比一下，哪个更好"))

        #expect(decision.execution == .currentSourceAndHistory)
        #expect(decision.intent.asksAboutHistory)
        #expect(decision.intent.asksForComparison)
        #expect(decision.intent.matchedTerms.contains("上次"))
        #expect(decision.intent.matchedTerms.contains("对比"))
    }

    @Test("A broad summary question widens, in English and in Chinese")
    func broadSummary() {
        let english = policy.resolve(request(history: 1, question: "Summarize everything we discussed"))
        #expect(english.execution == .currentSourceAndHistory)
        #expect(english.intent.asksForBroadSummary)

        let chinese = policy.resolve(request(history: 1, question: "总结一下全部内容"))
        #expect(chinese.execution == .currentSourceAndHistory)
        #expect(chinese.intent.asksForBroadSummary)
    }

    @Test("An explicit source-only override beats a history question")
    func sourceOnlyOverrideWins() {
        let decision = policy.resolve(request(
            history: 5,
            historySources: true,
            question: "Compare this with the earlier file",
            override: .sourceOnly
        ))

        #expect(decision.execution == .currentSource)
        #expect(decision.includesHistory == false)
        #expect(decision.offered.isEmpty)
        #expect(decision.override == .sourceOnly)
    }

    @Test("An explicit broader override looks at both corpora even for a neutral question")
    func broaderOverride() {
        let decision = policy.resolve(request(history: 2, question: "What does it say?", override: .broader))
        #expect(decision.execution == .currentSourceAndHistory)
        #expect(decision.includesHistory)
        #expect(decision.sourceFirst == false)
    }

    @Test("An explicit history override without a source stays in history")
    func historyOverrideWithoutSource() {
        let decision = policy.resolve(request(source: false, history: 2, question: "anything", override: .history))
        #expect(decision.execution == .history)
    }

    @Test("With no current source, history is the only corpus")
    func historyOnly() {
        let decision = policy.resolve(request(source: false, history: 2, question: "What did we conclude?"))
        #expect(decision.execution == .history)
        #expect(decision.includesHistory)
        #expect(decision.sourceFirst == false)
    }

    @Test("With neither corpus, nothing is allowed")
    func nothingAvailable() {
        let decision = policy.resolve(request(source: false, history: 0, question: "What did we conclude?"))
        #expect(decision.execution == .none)
        #expect(decision.includesHistory == false)
        #expect(decision.offered.isEmpty)
    }

    @Test("A source-only override with no source allows nothing")
    func sourceOnlyWithoutSource() {
        let decision = policy.resolve(request(source: false, history: 3, question: "anything", override: .sourceOnly))
        #expect(decision.execution == .none)
        #expect(decision.includesHistory == false)
    }

    @Test("Ordinary chat with no grounding allows the app's existing tools")
    func externalAllowedForOrdinaryChat() {
        let decision = policy.resolve(request(source: false, history: 0, question: "What is the weather in Shanghai?"))
        #expect(decision.execution == .none)
        #expect(decision.allowsExternalRetrieval)

        // Earlier turns with no attachments are still ordinary chat.
        let textHistory = policy.resolve(request(source: false, history: 3, question: "What did you say?"))
        #expect(textHistory.execution == .history)
        #expect(textHistory.allowsExternalRetrieval)
    }

    @Test("A current source withholds external retrieval, follow-ups included")
    func externalWithheldWhenGrounded() {
        let first = policy.resolve(request(history: 0, question: "Summarize this file"))
        #expect(first.allowsExternalRetrieval == false)

        let followUp = policy.resolve(request(history: 2, question: "What about the second section?"))
        #expect(followUp.allowsExternalRetrieval == false)

        let withHistorySources = policy.resolve(request(
            source: false,
            history: 2,
            historySources: true,
            question: "What did that report say?"
        ))
        #expect(withHistorySources.allowsExternalRetrieval == false)
    }

    @Test("A broad summary never widens external retrieval on its own")
    func summaryDoesNotWidenExternal() {
        let decision = policy.resolve(request(history: 1, historySources: true, question: "Summarize everything we discussed"))
        #expect(decision.execution == .currentSourceAndHistory)
        #expect(decision.allowsExternalRetrieval == false)
    }

    @Test("Comparing two attached documents never widens external retrieval")
    func comparisonDoesNotWidenExternal() {
        let decision = policy.resolve(request(history: 0, question: "Compare the two documents"))
        #expect(decision.intent.asksForComparison)
        #expect(decision.allowsExternalRetrieval == false)
    }

    @Test("Explicit external intent allows external retrieval despite a source")
    func explicitExternalIntent() {
        let decision = policy.resolve(request(history: 1, question: "Search the web for the latest numbers"))
        #expect(decision.intent.asksForExternalSearch)
        #expect(decision.allowsExternalRetrieval)
        // The internal scope stays source-first.
        #expect(decision.execution == .currentSource)

        let chinese = policy.resolve(request(history: 1, question: "上网查一下最新消息"))
        #expect(chinese.allowsExternalRetrieval)
        #expect(chinese.intent.asksForExternalSearch)
    }

    @Test("Overrides decide external retrieval: broader and history allow, source-only refuses")
    func externalOverrides() {
        #expect(policy.resolve(request(history: 1, question: "anything", override: .broader)).allowsExternalRetrieval)
        #expect(policy.resolve(request(history: 1, question: "anything", override: .history)).allowsExternalRetrieval)
        #expect(policy.resolve(request(history: 1, question: "anything", override: .compareHistory)).allowsExternalRetrieval == false)

        let narrowed = policy.resolve(request(history: 1, question: "search the web", override: .sourceOnly))
        #expect(narrowed.allowsExternalRetrieval == false)
    }

    @Test("The same request always resolves the same way")
    func deterministic() {
        let input = request(history: 3, historySources: true, question: "Why did that change?")
        #expect(policy.resolve(input) == policy.resolve(input))
        #expect(policy.resolve(input).execution == .currentSource)
    }

    @Test("Intent classification is lexical and stable")
    func classification() {
        #expect(policy.classify("Summarize the earlier discussion").asksForBroadSummary)
        #expect(policy.classify("Summarize the earlier discussion").asksAboutHistory)
        #expect(policy.classify("What is in this file?").asksAboutCurrentSource)
        #expect(policy.classify("Total revenue?").matchedTerms.isEmpty)
        #expect(policy.classify("对比一下").asksForComparison)
        #expect(policy.classify("").matchedTerms.isEmpty)
    }

    @Test("A custom configuration can add a term")
    func customConfiguration() {
        var configuration = ContextPolicy.Configuration.default
        configuration.historyTerms.insert("earlier turn")
        let custom = ContextPolicy(configuration: configuration)
        #expect(custom.classify("look at the earlier turn").asksAboutHistory)
    }
}
