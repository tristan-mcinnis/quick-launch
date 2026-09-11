import Foundation
import Synchronization
import Testing
@testable import QuickLaunch

/// Serves canned responses by URL. Each test uses its own host, so tests
/// running at once never share a route.
private final class LinkStub: URLProtocol {
    struct Route: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"]
        var body = Data()
        var redirect: URL?
        /// Never answers: the timeout test.
        var hangs = false
    }

    private static let routes = Mutex<[String: Route]>([:])
    private static let requests = Mutex<[URLRequest]>([])

    static func serve(_ url: URL, _ route: Route) {
        routes.withLock { $0[url.absoluteString] = route }
    }

    static func requests(to host: String) -> [URLRequest] {
        requests.withLock { $0.filter { $0.url?.host() == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        guard let url = request.url, let route = Self.routes.withLock({ $0[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if route.hangs { return }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers)!
        if let target = route.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < route.body.count {
            let end = min(offset + 256 * 1_024, route.body.count)
            client?.urlProtocol(self, didLoad: route.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Remembers what the VPS reader was asked for.
private final class RemoteLog: Sendable {
    private let urls = Mutex<[URL]>([])
    let reply: String

    init(reply: String) { self.reply = reply }

    var asked: [URL] { urls.withLock { $0 } }

    var reader: LinkAttachmentReader.RemoteReader {
        { [self] url in
            urls.withLock { $0.append(url) }
            return reply
        }
    }
}

@Suite("Link attachment reader")
struct LinkAttachmentReaderTests {
    private let host = "t-\(UUID().uuidString.lowercased()).example"

    private func url(_ path: String, scheme: String = "https") -> URL {
        URL(string: "\(scheme)://\(host)\(path)")!
    }

    private func reader(
        totalTimeout: Duration = AttachmentLimits.linkTotalTimeout,
        remote: LinkAttachmentReader.RemoteReader? = nil
    ) -> LinkAttachmentReader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkStub.self]
        return LinkAttachmentReader(configuration: configuration, totalTimeout: totalTimeout, remoteRead: remote)
    }

    private func failure(_ url: URL, _ reader: LinkAttachmentReader) async -> AttachmentFailure? {
        do {
            _ = try await reader.read(url)
            return nil
        } catch let failure as AttachmentFailure {
            return failure
        } catch {
            Issue.record("Unexpected error \(error)")
            return nil
        }
    }

    private static let article = String(repeating: "The pricing page lists three plans with monthly and yearly terms. ", count: 6)

    @Test("An HTML page gives its title, its URL, and its readable text")
    func htmlPage() async throws {
        let page = url("/pricing")
        let html = """
        <html><head><title>Pricing | Example</title><script>track()</script></head>
        <body><nav>Home Blog</nav><main><h1>Plans</h1><p>\(Self.article)</p></main></body></html>
        """
        LinkStub.serve(page, .init(body: Data(html.utf8)))
        let result = try await reader().read(page)
        let text = try #require(result.text)

        #expect(text.hasPrefix("Pricing | Example\n\(page.absoluteString)\n\nPlans\n"))
        #expect(!text.contains("track()"))
        #expect(!text.contains("Home Blog"))
        #expect(result.ref.kind == .link)
        #expect(result.ref.name == "Pricing | Example")
        #expect(result.ref.url == page)
        #expect(result.ref.path == nil)
        #expect(result.ref.contentHash == AttachmentExtractor.sha256(Data(html.utf8)))
        #expect(result.ref.byteCount == Data(html.utf8).count)
        #expect(result.kindLabel == "Web page")
        #expect(result.notes.isEmpty)

        let sent = try #require(LinkStub.requests(to: host).first)
        #expect(sent.value(forHTTPHeaderField: "User-Agent") == LinkAttachmentReader.userAgent)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("A page with no title is named by its host; the charset header decodes it")
    func charsetAndHost() async throws {
        let page = url("/cn")
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let body = "<html><body><p>季度收入增长。\(Self.article)</p></body></html>"
        LinkStub.serve(page, .init(headers: ["Content-Type": "text/html; charset=gb2312"], body: body.data(using: gb)!))
        let result = try await reader().read(page)
        #expect(result.ref.name == host)
        #expect(result.text?.contains("季度收入增长。") == true)
    }

    @Test("A PDF link reads through the PDF extractor")
    func pdfLink() async throws {
        let link = url("/files/report.pdf")
        let pdf = AttachmentFixtures.textPDF(pages: ["\(AttachmentFixtures.english)", "Second page words, long enough to count"])
        LinkStub.serve(link, .init(headers: ["Content-Type": "application/pdf"], body: pdf))
        let result = try await reader().read(link)
        #expect(result.text?.hasPrefix("--- Page 1 ---\n\(AttachmentFixtures.english)") == true)
        #expect(result.ref.pageCount == 2)
        #expect(result.ref.name == "report.pdf")
        #expect(result.kindLabel == "PDF")
        #expect(result.ref.url == link)
    }

    @Test("An image link becomes an image for the vision model, with no source kept")
    func imageLink() async throws {
        let link = url("/chart.png")
        let png = AttachmentFixtures.png(AttachmentFixtures.textImage("Chart", width: 800, height: 400))
        LinkStub.serve(link, .init(headers: ["Content-Type": "image/png"], body: png))
        let result = try await reader().read(link)
        #expect(result.image?.pixelWidth == 800)
        #expect(result.text == nil)
        #expect(result.ref.kind == .image)
        #expect(result.ref.url == nil)
    }

    @Test("The 5 MB body cap stops the read")
    func bodyCap() async throws {
        let big = url("/big")
        let filler = "<p>" + String(repeating: "word ", count: 200) + "</p>"
        let html = "<html><head><title>Big</title></head><body>"
            + String(repeating: filler, count: (6 * 1_024 * 1_024) / filler.utf8.count) + "</body></html>"
        LinkStub.serve(big, .init(body: Data(html.utf8)))
        let result = try await reader().read(big)
        #expect(result.ref.byteCount == AttachmentLimits.linkBodyBytes)
        #expect(result.notes == [.linkBodyCut(limitBytes: AttachmentLimits.linkBodyBytes)])
        #expect(result.chipNotes.contains("first 5 MB of the page"))
        #expect(result.ref.truncation?.keptCharacters == AttachmentLimits.charactersPerLink)

        let pdf = url("/big.pdf")
        LinkStub.serve(pdf, .init(headers: ["Content-Type": "application/pdf"], body: Data(repeating: 0x25, count: 6 * 1_024 * 1_024)))
        #expect(await failure(pdf, reader()) == .tooLarge(limit: AttachmentLimits.linkBodyBytes))
    }

    @Test("A link that does not answer stops at the total timeout")
    func timeout() async throws {
        #expect(AttachmentLimits.linkTotalTimeout == .seconds(15))
        #expect(AttachmentLimits.linkRequestTimeout == .seconds(10))
        let slow = url("/slow")
        LinkStub.serve(slow, .init(hangs: true))
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await failure(slow, reader(totalTimeout: .milliseconds(300))) == .timedOut)
        #expect(start.duration(to: clock.now) < .seconds(5))
    }

    @Test("Only http and https links are read")
    func schemes() async throws {
        let reader = reader()
        #expect(await failure(URL(string: "ftp://\(host)/file.txt")!, reader) == .invalidLink)
        #expect(await failure(URL(fileURLWithPath: "/etc/hosts"), reader) == .invalidLink)
        #expect(await failure(URL(string: "javascript:alert(1)")!, reader) == .invalidLink)
        #expect(AttachmentFailure.invalidLink.chipLine == "Only http and https links can be read")
    }

    @Test("A redirect to file: is refused; http redirects are followed to the final URL")
    func redirects() async throws {
        let sneaky = url("/sneaky")
        LinkStub.serve(sneaky, .init(status: 302, headers: ["Location": "file:///etc/passwd"], redirect: URL(fileURLWithPath: "/etc/passwd")))
        #expect(await failure(sneaky, reader()) == .redirectRefused)

        let first = url("/old")
        let final = url("/new")
        LinkStub.serve(first, .init(status: 301, headers: ["Location": final.absoluteString], redirect: final))
        LinkStub.serve(final, .init(body: Data("<html><head><title>New</title></head><body><p>\(Self.article)</p></body></html>".utf8)))
        let result = try await reader().read(first)
        #expect(result.ref.url == final)
        #expect(result.ref.name == "New")
    }

    @Test("More than five redirects are refused")
    func redirectLimit() async throws {
        let hops = (0...6).map { url("/hop\($0)") }
        for index in 0..<6 {
            LinkStub.serve(hops[index], .init(status: 302, headers: ["Location": hops[index + 1].absoluteString], redirect: hops[index + 1]))
        }
        LinkStub.serve(hops[6], .init(body: Data("<p>\(Self.article)</p>".utf8)))
        #expect(await failure(hops[0], reader()) == .tooManyRedirects)
    }

    @Test("A thin page takes the one VPS retry, with the final URL")
    func thinPageRetry() async throws {
        let thin = url("/app")
        LinkStub.serve(thin, .init(body: Data("<html><head><title>App</title></head><body><div id=root>Loading</div></body></html>".utf8)))
        let remote = RemoteLog(reply: "Rendered by the reader on the VPS. " + Self.article)
        let result = try await reader(remote: remote.reader).read(thin)
        #expect(remote.asked == [thin])
        #expect(result.text?.contains("Rendered by the reader on the VPS.") == true)
        #expect(result.ref.name == "App")

        let full = url("/full")
        LinkStub.serve(full, .init(body: Data("<p>\(Self.article)</p>".utf8)))
        let untouched = RemoteLog(reply: "never used")
        _ = try await reader(remote: untouched.reader).read(full)
        #expect(untouched.asked.isEmpty)

        let empty = url("/empty")
        LinkStub.serve(empty, .init(body: Data("<html><body></body></html>".utf8)))
        #expect(await failure(empty, reader()) == .empty)
    }

    @Test("The VPS reader runs WebPageReader's remote command over SSH")
    func vpsCommand() async throws {
        let calls = Mutex<[(String, [String])]>([])
        let page = url("/it's")
        let reader = LinkAttachmentReader.vpsReader(host: "vault-vps") { host, command, timeout in
            calls.withLock { $0.append((host, command)) }
            #expect(timeout == 15)
            return ProcessResult(stdout: Data("remote text".utf8), stderr: Data(), status: 0)
        }
        #expect(try await reader(page) == "remote text")
        let call = try #require(calls.withLock { $0.first })
        #expect(call.0 == "vault-vps")
        #expect(call.1 == WebPageReader.remoteCommand(for: page))

        let failing = LinkAttachmentReader.vpsReader(host: "vault-vps") { _, _, _ in
            ProcessResult(stdout: Data(), stderr: Data("no route".utf8), status: 255)
        }
        await #expect(throws: AttachmentFailure.unreachable) { try await failing(page) }
    }

    @Test("An HTTP error and a file type that is not read each say so")
    func statusAndType() async throws {
        let missing = url("/missing")
        LinkStub.serve(missing, .init(status: 404, body: Data("not found".utf8)))
        #expect(await failure(missing, reader()) == .httpStatus(404))
        #expect(AttachmentFailure.httpStatus(404).chipLine == "The page returned HTTP 404")

        let archive = url("/bundle.zip")
        LinkStub.serve(archive, .init(headers: ["Content-Type": "application/zip"], body: Data([0x50, 0x4B, 3, 4])))
        #expect(await failure(archive, reader()) == .linkContentType("ZIP"))
        #expect(AttachmentFailure.linkContentType("ZIP").chipLine == "This link is a ZIP file; download it and attach the file.")
    }

    @Test("Content-Type parsing")
    func contentType() {
        #expect(LinkAttachmentReader.parseContentType("text/html; charset=\"UTF-8\"") == ("text/html", "UTF-8"))
        #expect(LinkAttachmentReader.parseContentType("Application/PDF") == ("application/pdf", nil))
        #expect(LinkAttachmentReader.parseContentType(nil) == ("", nil))
    }
}
