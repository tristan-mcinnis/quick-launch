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

/// Reads web pages over a direct URLSession fetch.
actor WebPageReader: WebPageReading {
    /// Upper bound on injected page text so one long page cannot flood the
    /// model context.
    static let maxCharacters = 12_000

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        ]
        self.session = URLSession(configuration: configuration)
    }

    func read(_ url: URL) async throws -> String {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw PageReadError.invalidURL
        }

        let text: String
        do {
            text = try await readDirect(url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            throw PageReadError.timedOut
        } catch let error as URLError where error.code == .timedOut {
            throw PageReadError.timedOut
        }
        guard !text.isEmpty else { throw PageReadError.empty }
        return Self.bounded(text)
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

    /// The page text and the raw body it came from.
    func readWithBody(_ url: URL) async throws -> (text: String, body: Data?) {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw PageReadError.invalidURL
        }
        let text: String
        let body: Data
        do {
            let (data, response) = try await session.data(from: url)
            let interpreted = try Self.interpret(data: data, response: response)
            text = interpreted.text.trimmingCharacters(in: .whitespacesAndNewlines)
            body = interpreted.body
        } catch is CancellationError {
            throw PageReadError.timedOut
        } catch let error as URLError where error.code == .timedOut {
            throw PageReadError.timedOut
        }
        guard !text.isEmpty else { throw PageReadError.empty }
        return (Self.bounded(text), body)
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
