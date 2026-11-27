import Foundation
import Testing
@testable import QuickLaunch

@Suite("Clipboard text kinds")
struct ClipboardTextKindTests {

    @Test(arguments: [
        ("https://example.com/a?b=1", ClipboardTextKind.link),
        ("www.example.com", .link),
        ("someone@example.com", .email),
        ("mailto:someone@example.co.uk", .email),
        ("#ff8800", .color),
        ("#F80", .color),
        ("#ff880080", .color),
        ("rgb(255, 136, 0)", .color),
        ("rgba(0,0,0,0.5)", .color),
    ])
    func classifiesASingleValue(text: String, kind: ClipboardTextKind) {
        #expect(ClipboardTextKind.classify("  \(text)\n") == kind)
    }

    @Test(arguments: [
        "see https://example.com for more",
        "ftp://example.com",
        "file:///etc/hosts",
        "#hashtag",
        "#12345",
        "rgb(300, 0, 0)",
        "not@an address",
        "line one\nhttps://example.com",
        "",
    ])
    func leavesEverythingElse(text: String) {
        #expect(ClipboardTextKind.classify(text) == nil)
    }

    @Test func hexAndRGBReadTheSameColour() {
        #expect(ClipboardColor("#ff8800") == ClipboardColor(red: 1, green: 136.0 / 255, blue: 0))
        #expect(ClipboardColor("rgb(255,136,0)") == ClipboardColor("#F80"))
        #expect(ClipboardColor("#00000080")?.alpha == 128.0 / 255)
    }

    @Test func queryGrammarNarrowsByTextKind() {
        let query = ClipboardFilterQuery.parse("kind:link kind:colour invoice")
        #expect(query.textKinds == [.link, .color])
        #expect(query.kinds.isEmpty)
        #expect(query.needle == "invoice")
        #expect(ClipboardFilterQuery.parse("kind:image").textKinds.isEmpty)
    }

    private static func item(_ text: String, kind: ClipboardPayloadKind = .text) -> LauncherCatalogItem {
        var item = LauncherCatalogItem(kind: .clipboard, itemID: UUID().uuidString, title: text, detail: "", value: text, keywords: "")
        item.clipboardPayload = ClipboardPayload(kind: kind, text: text)
        return item
    }

    @Test func filterKeepsOnlyMatchingTextCopies() {
        let filter = ClipboardCatalogFilter(textKinds: [.email])
        #expect(filter.isActive)
        #expect(filter.matches(Self.item("a@b.io")))
        #expect(!filter.matches(Self.item("https://b.io")))
        // An image whose OCR text is an address is still an image.
        #expect(!filter.matches(Self.item("a@b.io", kind: .image)))
    }
}
