import Testing
@testable import apfel_quick

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
}
