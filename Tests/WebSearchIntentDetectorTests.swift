import Testing
@testable import QuickLaunch

@Suite("Web search intent detector")
struct WebSearchIntentDetectorTests {
    @Test func detectsLiveQuestions() {
        #expect(WebSearchIntentDetector.shouldSearch("when is the next NBA game?"))
        #expect(WebSearchIntentDetector.shouldSearch("latest news about Apple"))
        #expect(WebSearchIntentDetector.shouldSearch("weather in Shanghai today"))
        #expect(WebSearchIntentDetector.shouldSearch("what is the current NBA score?"))
    }

    @Test func leavesStableQuestionsForTheModel() {
        #expect(!WebSearchIntentDetector.shouldSearch("explain the NBA salary cap"))
        #expect(!WebSearchIntentDetector.shouldSearch("write an email about Spotify"))
        #expect(!WebSearchIntentDetector.shouldSearch("summarize this paragraph"))
        #expect(!WebSearchIntentDetector.shouldSearch("what is the current model?"))
        #expect(!WebSearchIntentDetector.shouldSearch("what is the next step?"))
    }

    @Test func leavesQuestionsAboutTheUserForMemory() {
        #expect(!WebSearchIntentDetector.shouldSearch("what did I work on today"))
        #expect(!WebSearchIntentDetector.shouldSearch("what's on my schedule today"))
        #expect(!WebSearchIntentDetector.shouldSearch("what did we decide today"))
        #expect(!WebSearchIntentDetector.shouldSearch("What I\u{2019}m doing tonight"))
        // Still the web: no first person, or an explicit command.
        #expect(WebSearchIntentDetector.shouldSearch("weather in Shanghai today"))
        #expect(WebSearchIntentDetector.shouldSearch("search web for my flight status"))
        #expect(WebSearchIntentDetector.shouldSearch("latest news about my bank"))
        // Words that only contain "i" or "me" are not first person.
        #expect(WebSearchIntentDetector.shouldSearch("time in Miami right now"))
    }

    // MARK: - Recency words, for a plain typed question only

    @Test func aPlainQuestionAboutSomethingRecentSearchesFirst() {
        for question in [
            "what is the latest version of Swift",
            "who won the most recent Formula 1 race",
            "what is Anthropic's newest Claude model",
            "最新的DeepSeek模型是什么",
            "上海今天天气",
            "latest news about my bank",
            "newest iPhone?",
        ] {
            #expect(WebSearchIntentDetector.shouldSearch(question, plainQuestion: true), "\(question)")
        }
    }

    @Test func recencyWordsCountOnlyForAPlainQuestion() {
        #expect(!WebSearchIntentDetector.shouldSearch("what is the latest version of Swift"))
        #expect(!WebSearchIntentDetector.shouldSearch("最新的DeepSeek模型是什么"))
    }

    @Test func recencyWordsLeaveEverythingElseAlone() {
        for input in [
            "what is Model Context Protocol",
            "what is the next step?",
            "what is the current model?",
            "my latest notes",
            "summarize the latest email I sent",
            "我最新的笔记",
            "咱们今天做什么",
            "the latestness of it",
            "rewrite this so it reads well\nit is the latest draft",
            "the latest draft fixes the login crash",
            "translate: what is the latest version",
            "翻译成英文：今天的会议改到下午三点",
            "润色最新版本修复了登录问题",
            String(repeating: "a long pasted paragraph about the latest plan ", count: 4),
        ] {
            #expect(!WebSearchIntentDetector.shouldSearch(input, plainQuestion: true), "\(input)")
        }
    }
}
