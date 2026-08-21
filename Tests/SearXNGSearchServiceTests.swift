import Foundation
import Testing
@testable import apfel_quick

@Suite("SearXNG search service")
struct SearXNGSearchServiceTests {
    @Test func formatsOnlySmallRankedSnippetBundle() throws {
        let data = Data("""
        {
          "results": [
            {
              "title": "NBA Schedule",
              "content": "Official schedule and game times.",
              "url": "https://www.nba.com/schedule"
            },
            {
              "title": "ESPN Schedule",
              "content": "The complete NBA schedule.",
              "url": "https://www.espn.com/nba/schedule"
            }
          ]
        }
        """.utf8)

        let result = try SearXNGSearchService.formatResults(data)

        #expect(result.contains("## NBA Schedule"))
        #expect(result.contains("URL: https://www.nba.com/schedule"))
        #expect(result.contains("Snippet: Official schedule and game times."))
        #expect(!result.contains("full text"))
    }

    @Test func rejectsEmptyResults() {
        #expect(throws: WebSearchError.self) {
            try SearXNGSearchService.formatResults(Data("{\"results\":[]}".utf8))
        }
    }
}
