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

    @Test func leavesQuestionsAboutTheUserForMemoryAndTheVault() {
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
}
