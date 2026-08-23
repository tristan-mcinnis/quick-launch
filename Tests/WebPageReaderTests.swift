import Foundation
import Testing
@testable import QuickLaunch

@Suite("HTML text extraction")
struct HTMLTextExtractorTests {
    @Test func stripsScriptsStylesAndTags() {
        let html = """
        <html><head><title>Example</title><style>body { color: red; }</style></head>
        <body>
        <script>trackMe();</script>
        <h1>Welcome</h1>
        <p>Hello   world.</p>
        </body></html>
        """
        let text = HTMLTextExtractor.text(from: html)
        #expect(text.contains("Welcome"))
        #expect(text.contains("Hello world."))
        #expect(!text.contains("trackMe"))
        #expect(!text.contains("color: red"))
    }

    @Test func prefersArticleBodyOverChrome() {
        let html = """
        <html><body>
        <nav>Menu Home About</nav>
        <article><h2>Real story</h2><p>Body of the story.</p></article>
        </body></html>
        """
        let text = HTMLTextExtractor.text(from: html)
        #expect(text.contains("Real story"))
        #expect(text.contains("Body of the story."))
        #expect(!text.contains("Menu Home About"))
    }

    @Test func listItemsBecomeBulletsAndEntitiesDecode() {
        let html = "<ul><li>First&nbsp;item</li><li>Tom &amp; Jerry &mdash; &#8220;quoted&#8221;</li></ul>"
        let text = HTMLTextExtractor.text(from: html)
        // &nbsp; is normalized to a plain space for model context.
        #expect(text.contains("- First item"))
        #expect(text.contains("Tom & Jerry \u{2014} \u{201C}quoted\u{201D}"))
    }

    @Test func titleIsExtractedAndDecoded() {
        #expect(HTMLTextExtractor.title(from: "<title>A &amp; B</title>") == "A & B")
        #expect(HTMLTextExtractor.title(from: "<p>no title</p>") == nil)
    }
}

@Suite("Prompt URL scanning")
struct PromptURLScannerTests {
    @Test func findsURLsAroundText() {
        let urls = PromptURLScanner.urls(
            in: "summarize https://example.com/post/1 and compare https://other.org/page?a=1."
        )
        #expect(urls.map(\.absoluteString) == [
            "https://example.com/post/1",
            "https://other.org/page?a=1",
        ])
    }

    @Test func ignoresTrailingPunctuationAndDuplicates() {
        let urls = PromptURLScanner.urls(in: "https://example.com/a, see https://example.com/a")
        #expect(urls.count == 1)
        #expect(urls[0].absoluteString == "https://example.com/a")
    }

    @Test func capsTheNumberOfFetches() {
        let input = (1...5).map { "https://example.org/\($0)" }.joined(separator: " ")
        #expect(PromptURLScanner.urls(in: input).count == 2)
    }

    @Test func plainTextYieldsNothing() {
        #expect(PromptURLScanner.urls(in: "what is the latest news today?").isEmpty)
    }
}
