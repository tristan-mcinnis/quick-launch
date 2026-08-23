import Foundation
import Testing
@testable import QuickLaunch

@Suite("URL tools")
struct URLToolsTests {
    // MARK: - URLCleaner

    @Test func removesUTMParametersAndKeepsTheRest() {
        let input = "https://example.com/article?id=42&utm_source=newsletter&utm_medium=email&page=2"
        #expect(URLCleaner.clean(input) == "https://example.com/article?id=42&page=2")
        #expect(URLCleaner.hasTrackingParameters(input))
    }

    @Test func removesClickIdentifiers() {
        #expect(URLCleaner.clean("https://shop.example.com/item?fbclid=abc&color=red") == "https://shop.example.com/item?color=red")
        #expect(URLCleaner.clean("https://shop.example.com/item?gclid=abc") == "https://shop.example.com/item")
        #expect(URLCleaner.clean("https://shop.example.com/item?q=1&msclkid=x&mc_cid=y&mc_eid=z") == "https://shop.example.com/item?q=1")
    }

    @Test func matchesParameterNamesCaseInsensitively() {
        #expect(URLCleaner.clean("https://example.com/?UTM_Source=a&Q=1") == "https://example.com/?Q=1")
        #expect(URLCleaner.clean("https://example.com/?hsCtaTracking=abc&x=y") == "https://example.com/?x=y")
    }

    @Test func keepsOriginalParameterOrder() {
        let input = "https://example.com/?b=2&utm_campaign=c&a=1&ref=home&c=3"
        #expect(URLCleaner.clean(input) == "https://example.com/?b=2&a=1&c=3")
    }

    @Test func collapsesAmazonProductURLToASIN() {
        let input = "https://www.amazon.com/Some-Product-Name/dp/B08N5WRWNW/ref=sr_1_3?keywords=widget&qid=1700000000&sr=8-3"
        #expect(URLCleaner.clean(input) == "https://www.amazon.com/dp/B08N5WRWNW")
        #expect(URLCleaner.hasTrackingParameters(input))
    }

    @Test func collapsesAmazonGPProductURLOnAnyAmazonDomain() {
        let input = "https://www.amazon.co.uk/gp/product/B0CHX3QBCH?pf_rd_r=ABC&th=1"
        #expect(URLCleaner.clean(input) == "https://www.amazon.co.uk/dp/B0CHX3QBCH")
    }

    @Test func leavesAmazonSearchURLsAlone() {
        let input = "https://www.amazon.com/s?k=headphones&ref=nb_sb_noss"
        #expect(URLCleaner.clean(input) == "https://www.amazon.com/s?k=headphones")
    }

    @Test func removesYouTubeShortLinkShareIdentifier() {
        let input = "https://youtu.be/dQw4w9WgXcQ?si=AbC123xyz"
        #expect(URLCleaner.clean(input) == "https://youtu.be/dQw4w9WgXcQ")
    }

    @Test func removesYouTubeShareFeatureButKeepsVideoAndTime() {
        let input = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=share&t=42s&si=zzz"
        #expect(URLCleaner.clean(input) == "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s")
    }

    @Test func keepsYouTubeFeatureWhenNotShare() {
        let input = "https://www.youtube.com/watch?v=abc&feature=youtu.be"
        #expect(URLCleaner.clean(input) == input)
    }

    @Test func removesSpotifyShareIdentifier() {
        let input = "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=9f1d2e3a4b5c6d7e"
        #expect(URLCleaner.clean(input) == "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT")
    }

    @Test func keepsShareIdentifierOnOtherHosts() {
        let input = "https://example.com/page?si=keepme"
        #expect(URLCleaner.clean(input) == input)
        #expect(!URLCleaner.hasTrackingParameters(input))
    }

    @Test func removesSPMOnlyOnTaobaoAndAliExpress() {
        #expect(URLCleaner.clean("https://item.taobao.com/item.htm?id=123&spm=a1z10.1-c") == "https://item.taobao.com/item.htm?id=123")
        #expect(URLCleaner.clean("https://www.aliexpress.com/item/100.html?spm=a2g0o.home&gatewayAdapt=glo2usa") == "https://www.aliexpress.com/item/100.html?gatewayAdapt=glo2usa")
        let other = "https://example.com/?spm=keep"
        #expect(URLCleaner.clean(other) == other)
    }

    @Test func removesTextFragment() {
        let input = "https://en.wikipedia.org/wiki/URL#:~:text=Uniform%20Resource%20Locator"
        #expect(URLCleaner.clean(input) == "https://en.wikipedia.org/wiki/URL")
        #expect(URLCleaner.hasTrackingParameters(input))
    }

    @Test func keepsNormalFragment() {
        let input = "https://example.com/docs?v=2#installation"
        #expect(URLCleaner.clean(input) == input)
    }

    @Test func unchangedURLReturnsSameString() {
        let input = "https://example.com/path?q=swift&page=3"
        #expect(URLCleaner.clean(input) == input)
        #expect(!URLCleaner.hasTrackingParameters(input))
    }

    @Test func preservesPercentEncoding() {
        let input = "https://example.com/search?q=caf%C3%A9%20au%20lait&utm_source=x&path=%2Fa%2Fb"
        #expect(URLCleaner.clean(input) == "https://example.com/search?q=caf%C3%A9%20au%20lait&path=%2Fa%2Fb")
    }

    @Test func nonURLReturnsNil() {
        #expect(URLCleaner.clean("hello world") == nil)
        #expect(URLCleaner.clean("utm_source=abc") == nil)
        #expect(URLCleaner.clean("ftp://example.com/file?utm_source=x") == nil)
        #expect(URLCleaner.clean("mailto:someone@example.com?utm_source=x") == nil)
        #expect(URLCleaner.clean("") == nil)
        #expect(!URLCleaner.hasTrackingParameters("not a url"))
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(URLCleaner.clean("  https://example.com/?utm_source=a \n") == "https://example.com/")
    }

    // MARK: - TypedURLDetector

    @Test func acceptsBareDomains() {
        #expect(TypedURLDetector.url(from: "apple.com")?.absoluteString == "https://apple.com")
        #expect(TypedURLDetector.url(from: "www.bbc.co.uk/news")?.absoluteString == "https://www.bbc.co.uk/news")
        #expect(TypedURLDetector.url(from: "example.com/path?q=1")?.absoluteString == "https://example.com/path?q=1")
    }

    @Test func keepsExplicitScheme() {
        #expect(TypedURLDetector.url(from: "https://x.y")?.absoluteString == "https://x.y")
        #expect(TypedURLDetector.url(from: "http://example.com/a")?.absoluteString == "http://example.com/a")
    }

    @Test func localhostAndPrivateAddressesGetHTTP() {
        #expect(TypedURLDetector.url(from: "localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(TypedURLDetector.url(from: "localhost")?.absoluteString == "http://localhost")
        #expect(TypedURLDetector.url(from: "192.168.1.1")?.absoluteString == "http://192.168.1.1")
        #expect(TypedURLDetector.url(from: "10.0.0.5:8080/admin")?.absoluteString == "http://10.0.0.5:8080/admin")
        #expect(TypedURLDetector.url(from: "127.0.0.1")?.absoluteString == "http://127.0.0.1")
    }

    @Test func publicAddressesGetHTTPS() {
        #expect(TypedURLDetector.url(from: "8.8.8.8")?.absoluteString == "https://8.8.8.8")
        #expect(TypedURLDetector.url(from: "1.2.3") == nil)
        #expect(TypedURLDetector.url(from: "300.1.1.1") == nil)
    }

    @Test func rejectsWordsAndSentences() {
        #expect(TypedURLDetector.url(from: "hi") == nil)
        #expect(TypedURLDetector.url(from: "what is") == nil)
        #expect(TypedURLDetector.url(from: "hello") == nil)
        #expect(TypedURLDetector.url(from: "what is apple.com") == nil)
        #expect(TypedURLDetector.url(from: "") == nil)
        #expect(TypedURLDetector.url(from: "   ") == nil)
    }

    @Test func rejectsUnknownSuffixes() {
        #expect(TypedURLDetector.url(from: "file.txt") == nil)
        #expect(TypedURLDetector.url(from: "v1.2") == nil)
        #expect(TypedURLDetector.url(from: "notes.md") == nil)
        #expect(TypedURLDetector.url(from: "build.sh") == nil)
        #expect(TypedURLDetector.url(from: "main.py") == nil)
        #expect(TypedURLDetector.url(from: "apple.com.") == nil)
        #expect(TypedURLDetector.url(from: "a..com") == nil)
    }

    @Test func rejectsEmailsAndFilePaths() {
        #expect(TypedURLDetector.url(from: "someone@example.com") == nil)
        #expect(TypedURLDetector.url(from: "/Users/me/file.com") == nil)
        #expect(TypedURLDetector.url(from: "~/Documents/site.com") == nil)
        #expect(TypedURLDetector.url(from: "./build.sh") == nil)
        #expect(TypedURLDetector.url(from: "file:///tmp/a.com") == nil)
    }

    @Test func rejectsBadPorts() {
        #expect(TypedURLDetector.url(from: "localhost:abc") == nil)
        #expect(TypedURLDetector.url(from: "example.com:99999") == nil)
        #expect(TypedURLDetector.url(from: "example.com:8443/x")?.absoluteString == "https://example.com:8443/x")
    }

    @Test func ignoresHostCase() {
        #expect(TypedURLDetector.url(from: "Apple.COM")?.absoluteString == "https://Apple.COM")
    }
}
