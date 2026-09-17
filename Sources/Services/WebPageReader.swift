import Foundation

enum PageReadError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case unsupportedContentType(String)
    case failed(String)
    case timedOut
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Only http(s) pages can be read."
        case .httpStatus(let status):
            "The page returned HTTP \(status)."
        case .failed(let message):
            "Reading the page failed: \(message)"
        case .unsupportedContentType(let type):
            "Unsupported content type: \(type)"
        case .timedOut:
            "Reading the page took too long."
        case .empty:
            "No readable text found on that page."
        }
    }
}

/// Reads web pages over a direct URLSession fetch, falling back to the
/// trafilatura reader on vault-vps (same path as the ``webread`` CLI) when
/// the direct fetch fails or yields almost nothing.
actor WebPageReader: WebPageReading {
    /// Upper bound on injected page text so one long page cannot flood the
    /// model context.
    static let maxCharacters = 12_000

    private let session: URLSession
    private let vpsHost: String?
    private let requestTimeout: Duration

    init(vpsHost: String? = "vault-vps", requestTimeout: Duration = .seconds(15)) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        ]
        self.session = URLSession(configuration: configuration)
        self.vpsHost = vpsHost
        self.requestTimeout = requestTimeout
    }

    func read(_ url: URL) async throws -> String {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw PageReadError.invalidURL
        }

        var directText = ""
        do {
            directText = try await readDirect(url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            throw PageReadError.timedOut
        } catch {
            directText = ""
        }

        if directText.count >= 200 || vpsHost == nil {
            guard !directText.isEmpty else { throw PageReadError.empty }
            return Self.bounded(directText)
        }

        // Thin or failed direct fetches get one retry through the VPS
        // extractor, which also handles some JavaScript-rendered pages.
        let remoteText = try await readViaVPS(url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteText.count > directText.count {
            return Self.bounded(remoteText)
        }
        guard !directText.isEmpty else { throw PageReadError.empty }
        return Self.bounded(directText)
    }

    nonisolated static func bounded(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        let cut = text.index(text.startIndex, offsetBy: maxCharacters)
        return String(text[..<cut]) + "\n[content truncated]"
    }

    // MARK: - Direct fetch

    private func readDirect(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        return try Self.interpret(data: data, response: response).text
    }

    /// The readable text of one direct response and the raw body it came
    /// from. Throws for a non-2xx status or an unsupported content type.
    nonisolated static func interpret(data: Data, response: URLResponse) throws -> (text: String, body: Data) {
        guard let http = response as? HTTPURLResponse else {
            throw PageReadError.httpStatus(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PageReadError.httpStatus(http.statusCode)
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
            .lowercased()
        if contentType.contains("html") || contentType.contains("xml") {
            let html = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            return (HTMLTextExtractor.text(from: html), data)
        }
        if contentType.hasPrefix("text/")
            || contentType.contains("json")
            || contentType.isEmpty
        {
            return (String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self), data)
        }
        throw PageReadError.unsupportedContentType(contentType)
    }

    /// The page text and the raw body when the direct fetch won. The VPS
    /// fallback returns derived text only: no body was kept.
    func readWithBody(_ url: URL) async throws -> (text: String, body: Data?) {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw PageReadError.invalidURL
        }
        var direct: (text: String, body: Data?) = ("", nil)
        do {
            let (data, response) = try await session.data(from: url)
            let interpreted = try Self.interpret(data: data, response: response)
            direct = (interpreted.text.trimmingCharacters(in: .whitespacesAndNewlines), interpreted.body)
        } catch is CancellationError {
            throw PageReadError.timedOut
        } catch {
            direct = ("", nil)
        }
        if direct.text.count >= 200 || vpsHost == nil {
            guard !direct.text.isEmpty else { throw PageReadError.empty }
            return (Self.bounded(direct.text), direct.body)
        }
        let remoteText = try await readViaVPS(url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remoteText.count > direct.text.count {
            return (Self.bounded(remoteText), nil)
        }
        guard !direct.text.isEmpty else { throw PageReadError.empty }
        return (Self.bounded(direct.text), direct.body)
    }

    // MARK: - VPS fallback

    /// The single remote command string ssh runs on vault-vps. Pure; tests
    /// pin the quoting.
    nonisolated static func remoteCommand(for url: URL) -> [String] {
        let escaped = url.absoluteString
            .replacingOccurrences(of: "'", with: "%27")
        return ["~/search-tools/venv/bin/python ~/search-tools/read_page.py '\(escaped)'"]
    }

    /// Runs the trafilatura reader on vault-vps over SSH. Mirrors the
    /// transport of `SearXNGSearchService`: direct process execution, no
    /// local shell interpolation.
    private func readViaVPS(_ url: URL) async throws -> String {
        guard let host = vpsHost else { throw PageReadError.empty }
        let remoteCommand = Self.remoteCommand(for: url)

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let result: ProcessResult
                do {
                    result = try await SSHRunner.run(host: host, remoteCommand: remoteCommand)
                } catch let error as ProcessRunnerError {
                    throw PageReadError.failed(error.localizedDescription)
                }
                guard result.status == 0 else {
                    let message = result.stderrText
                    throw PageReadError.failed(
                        message.isEmpty ? "reader exited with \(result.status)" : message
                    )
                }
                return result.stdoutText
            }
            group.addTask { [requestTimeout] in
                try await Task.sleep(for: requestTimeout)
                throw PageReadError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw PageReadError.empty
            }
            return result
        }
    }
}

/// Finds http(s) URLs inside a submitted prompt so Quick Launch can fetch
/// their pages as context before the model answers.
enum PromptURLScanner {
    private static let pattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"'()\[\]]+"#
    )

    /// Returns up to `limit` unique URLs, ignoring trailing punctuation.
    static func urls(in text: String, limit: Int = 2) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            var candidate = String(text[matchRange])
            while let last = candidate.last, ".,:;!?".contains(last) {
                candidate.removeLast()
            }
            guard !seen.contains(candidate), let url = URL(string: candidate) else {
                continue
            }
            seen.insert(candidate)
            result.append(url)
            if result.count == limit { break }
        }
        return result
    }
}
