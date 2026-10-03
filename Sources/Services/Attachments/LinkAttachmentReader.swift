import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Fetches a link once, when the user attaches it, and turns it into an
/// attachment: a web page's title and text, a PDF's pages, or an image for
/// the vision model.
///
/// - One GET, http or https only, at most 5 redirects, each to http(s).
///   Ephemeral session: no cookies, no cache.
/// - 15 s in all (10 s a request); the body is read as a stream and stops
///   at 5 MB whatever the server claims.
/// - A page with under 200 characters of text gets the one retry through
///   the trafilatura reader on the House server, as `WebPageReader` does, inside
///   the same 15 s.
/// - The reference keeps the final URL after redirects, and the title.
///
/// Separate from `WebPageReader`, which keeps serving the in-question page
/// read and the tools.
actor LinkAttachmentReader {
    /// Reads a page elsewhere (the VPS) and returns its text.
    typealias RemoteReader = @Sendable (URL) async throws -> String

    /// Same browser identity as `WebPageReader`, so a page that answers one
    /// answers the other.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let session: URLSession
    private let totalTimeout: Duration
    private let requestTimeout: Duration
    private let bodyLimit: Int
    private let remoteRead: RemoteReader?

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        totalTimeout: Duration = AttachmentLimits.linkTotalTimeout,
        requestTimeout: Duration = AttachmentLimits.linkRequestTimeout,
        bodyLimit: Int = AttachmentLimits.linkBodyBytes,
        remoteRead: RemoteReader? = LinkAttachmentReader.vpsReader(host: HouseServer.host)
    ) {
        // A copy, so the caller's configuration is never changed.
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.timeoutIntervalForRequest = Self.seconds(requestTimeout)
        configuration.timeoutIntervalForResource = Self.seconds(totalTimeout)
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = Self.userAgent
        configuration.httpAdditionalHeaders = headers
        self.session = URLSession(configuration: configuration)
        self.totalTimeout = totalTimeout
        self.requestTimeout = requestTimeout
        self.bodyLimit = bodyLimit
        self.remoteRead = remoteRead
    }

    /// Runs one remote command on a host: `SSHRunner.run` in the app.
    typealias SSHRunning = @Sendable (_ host: String, _ remoteCommand: [String], _ timeout: TimeInterval) async throws -> ProcessResult

    /// The trafilatura reader on the House server over SSH: `WebPageReader`'s
    /// remote command, direct argv, no local shell.
    static func vpsReader(
        host: String,
        timeout: Duration = AttachmentLimits.linkTotalTimeout,
        run: @escaping SSHRunning = { host, command, timeout in
            try await SSHRunner.run(host: host, remoteCommand: command, timeout: timeout)
        }
    ) -> RemoteReader {
        { url in
            let result = try await run(host, WebPageReader.remoteCommand(for: url), seconds(timeout))
            guard result.status == 0 else { throw AttachmentFailure.unreachable }
            return result.stdoutText
        }
    }

    // MARK: Read

    func read(
        _ url: URL,
        recognizeText: @escaping AttachmentTextRecognizer = { image in
            await ScreenshotTextIndex.recognizeText(in: image)
        },
        progress: AttachmentProgressHandler? = nil
    ) async throws -> ExtractedAttachment {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { throw AttachmentFailure.invalidLink }
        progress?(.fetching(host: host))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: totalTimeout)
        let session = self.session
        let requestTimeout = self.requestTimeout
        let bodyLimit = self.bodyLimit
        let fetched = try await AttachmentExtractor.withTimeout(totalTimeout) {
            try await Self.fetch(url, session: session, requestTimeout: requestTimeout, bodyLimit: bodyLimit)
        }
        progress?(.reading)
        let hash = AttachmentExtractor.sha256(fetched.data)
        let finalHost = fetched.finalURL.host() ?? host
        var notes: [AttachmentNote] = fetched.bodyCut ? [.linkBodyCut(limitBytes: bodyLimit)] : []

        switch Self.category(of: fetched) {
        case .image:
            guard !fetched.bodyCut else { throw AttachmentFailure.tooLarge(limit: bodyLimit) }
            let image = try AttachmentImageReader.image(from: fetched.data)
            let ref = ChatAttachmentRef(
                kind: .image,
                name: fetched.finalURL.lastPathComponent.isEmpty ? finalHost : fetched.finalURL.lastPathComponent,
                byteCount: fetched.data.count,
                pixelWidth: image.pixelWidth,
                pixelHeight: image.pixelHeight
            )
            return ExtractedAttachment(ref: ref, text: nil, image: image, kindLabel: "Image", notes: [])

        case .pdf:
            guard !fetched.bodyCut else { throw AttachmentFailure.tooLarge(limit: bodyLimit) }
            var document = try await PDFTextExtractor.extract(
                data: fetched.data,
                recognizeText: recognizeText,
                progress: progress
            )
            document.notes += notes
            let name = fetched.finalURL.lastPathComponent.isEmpty ? finalHost : fetched.finalURL.lastPathComponent
            return try Self.attachment(
                document,
                name: name,
                kindLabel: "PDF",
                fetched: fetched,
                hash: hash,
                characterCap: AttachmentLimits.charactersPerFile
            )

        case .html, .text:
            let isHTML = Self.category(of: fetched) == .html
            var title: String?
            var body: String
            if isHTML {
                let html = PlainTextReader.decodeHTML(fetched.data, declaredCharset: fetched.charset)
                title = HTMLTextExtractor.title(from: html)
                body = HTMLTextExtractor.text(from: html)
            } else {
                body = Self.decodeText(fetched.data, charset: fetched.charset)
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)

            if body.count < AttachmentLimits.thinPageCharacters, let remoteRead {
                let remaining = clock.now.duration(to: deadline)
                if remaining > .zero {
                    let finalURL = fetched.finalURL
                    let remote = try? await AttachmentExtractor.withTimeout(remaining) {
                        try await remoteRead(finalURL)
                    }
                    try Task.checkCancellation()
                    let remoteText = (remote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if remoteText.count > body.count {
                        body = remoteText
                        notes.removeAll { if case .linkBodyCut = $0 { true } else { false } }
                    }
                }
            }
            guard !body.isEmpty else { throw AttachmentFailure.empty }

            let name = title ?? finalHost
            let heading = [title, fetched.finalURL.absoluteString].compactMap { $0 }.joined(separator: "\n")
            let document = DocumentText(text: "\(heading)\n\n\(body)", notes: notes)
            return try Self.attachment(
                document,
                name: name,
                kindLabel: "Web page",
                fetched: fetched,
                hash: hash,
                characterCap: AttachmentLimits.charactersPerLink
            )

        case .other(let type):
            throw AttachmentFailure.linkContentType(type)
        }
    }

    private static func attachment(
        _ document: DocumentText,
        name: String,
        kindLabel: String,
        fetched: Fetched,
        hash: String,
        characterCap: Int
    ) throws -> ExtractedAttachment {
        let finished = try document.finished(characterCap: characterCap)
        let ref = ChatAttachmentRef(
            kind: .link,
            name: name,
            byteCount: fetched.data.count,
            pageCount: document.unitCount,
            characterCount: finished.characterCount,
            truncation: finished.truncation,
            contentHash: hash,
            extractorVersion: AttachmentExtractor.version,
            url: fetched.finalURL
        )
        return ExtractedAttachment(
            ref: ref,
            text: finished.text,
            image: nil,
            kindLabel: kindLabel,
            notes: document.notes,
            originalBytes: fetched.data
        )
    }

    // MARK: Fetch

    struct Fetched: Sendable {
        let finalURL: URL
        /// Lower-cased MIME type without parameters; empty when absent.
        let mimeType: String
        let charset: String?
        let data: Data
        /// True when the body passed the cap and the rest was not read.
        let bodyCut: Bool
    }

    static func fetch(
        _ url: URL,
        session: URLSession,
        requestTimeout: Duration,
        bodyLimit: Int
    ) async throws -> Fetched {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = seconds(requestTimeout)
        request.httpShouldHandleCookies = false

        let redirects = RedirectGuard(limit: AttachmentLimits.linkRedirects)
        let loaded: (data: Data, response: URLResponse)
        do {
            // One bounded read. Iterating `session.bytes` costs an async
            // suspension per byte, so a 5 MB page ran into the total timeout
            // instead of being cut; `AttachmentExtractor.withTimeout` still
            // cancels this request when the total deadline fires.
            loaded = try await session.data(for: request, delegate: redirects)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let refusal = redirects.refusal { throw refusal }
            throw failure(for: error)
        }
        if let refusal = redirects.refusal { throw refusal }
        guard let http = loaded.response as? HTTPURLResponse else {
            throw AttachmentFailure.unreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AttachmentFailure.httpStatus(http.statusCode)
        }

        let (mimeType, charset) = parseContentType(http.value(forHTTPHeaderField: "Content-Type"))
        let cut = loaded.data.count > bodyLimit
        return Fetched(
            finalURL: http.url ?? url,
            mimeType: mimeType,
            charset: charset,
            data: cut ? Data(loaded.data.prefix(bodyLimit)) : loaded.data,
            bodyCut: cut
        )
    }

    /// "text/html; charset=UTF-8" to ("text/html", "UTF-8").
    static func parseContentType(_ header: String?) -> (mimeType: String, charset: String?) {
        guard let header else { return ("", nil) }
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let mime = parts.first?.lowercased() ?? ""
        let charset = parts.dropFirst().first { $0.lowercased().hasPrefix("charset=") }
            .map { String($0.dropFirst("charset=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        return (mime, charset)
    }

    private static func failure(for error: Error) -> Error {
        if error is CancellationError || error is AttachmentFailure { return error }
        guard let urlError = error as? URLError else { return AttachmentFailure.unreachable }
        switch urlError.code {
        case .timedOut: return AttachmentFailure.timedOut
        case .cancelled: return Task.isCancelled ? CancellationError() : AttachmentFailure.unreachable
        case .httpTooManyRedirects, .redirectToNonExistentLocation: return AttachmentFailure.tooManyRedirects
        case .unsupportedURL: return AttachmentFailure.redirectRefused
        default: return AttachmentFailure.unreachable
        }
    }

    // MARK: Content type

    enum Category: Equatable, Sendable {
        case html
        case text
        case pdf
        case image
        /// Carries the short type name the chip uses ("ZIP").
        case other(String)
    }

    /// The server's type decides; a missing or generic type is sniffed.
    static func category(of fetched: Fetched) -> Category {
        let mime = fetched.mimeType
        switch mime {
        case "text/html", "application/xhtml+xml": return .html
        case "application/pdf": return .pdf
        default: break
        }
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("text/") || mime.contains("json") || mime.hasSuffix("+xml") || mime == "application/xml" {
            return .text
        }
        if mime.isEmpty || mime == "application/octet-stream" || mime == "binary/octet-stream" {
            return sniff(fetched.data) ?? .other(shortName(for: mime))
        }
        return .other(shortName(for: mime))
    }

    private static func sniff(_ data: Data) -> Category? {
        if data.prefix(1_024).range(of: Data("%PDF-".utf8)) != nil { return .pdf }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0 {
            return .image
        }
        guard !PlainTextReader.hasNULByte(data, within: AttachmentLimits.binaryCheckBytes) else { return nil }
        let head = String(decoding: data.prefix(1_024), as: UTF8.self).lowercased()
        return head.contains("<html") || head.contains("<!doctype html") ? .html : .text
    }

    /// "application/zip" to "ZIP", else the subtype.
    private static func shortName(for mime: String) -> String {
        if let ext = UTType(mimeType: mime)?.preferredFilenameExtension { return ext.uppercased() }
        let subtype = mime.split(separator: "/").last.map(String.init) ?? ""
        return subtype.isEmpty ? "binary" : subtype
    }

    private static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = PlainTextReader.encoding(forCharset: charset),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        return (try? PlainTextReader.decode(data)) ?? String(decoding: data, as: UTF8.self)
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Counts redirects and refuses the sixth, and any that leaves http(s).
/// The one delegate of one fetch; the `Mutex` guards its state.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private struct State {
        var count = 0
        var refusal: AttachmentFailure?
    }

    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = limit
    }

    var refusal: AttachmentFailure? { state.withLock { $0.refusal } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        let scheme = request.url?.scheme?.lowercased()
        let allowed = state.withLock { state -> Bool in
            state.count += 1
            if state.count > limit {
                state.refusal = .tooManyRedirects
                return false
            }
            guard scheme == "http" || scheme == "https" else {
                state.refusal = .redirectRefused
                return false
            }
            return true
        }
        return allowed ? request : nil
    }
}
