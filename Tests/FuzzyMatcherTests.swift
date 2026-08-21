import Testing
@testable import apfel_quick

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test func matchesSubsequence() {
        #expect(FuzzyMatcher.score(query: "smrz", candidate: "Summarize") != nil)
        #expect(FuzzyMatcher.score(query: "eml", candidate: "Rewrite as Email") != nil)
    }

    @Test func rejectsMissingCharacters() {
        #expect(FuzzyMatcher.score(query: "xyz", candidate: "Summarize") == nil)
    }

    @Test func emptyQueryShowsEverything() {
        #expect(FuzzyMatcher.score(query: "", candidate: "Summarize") == 0)
    }
}
