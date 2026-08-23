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
            return HTMLTextExtractor.text(from: html)
        }
        if contentType.hasPrefix("text/")
            || contentType.contains("json")
            || contentType.isEmpty
        {
            return String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
        }
        throw PageReadError.unsupportedContentType(contentType)
    }

    // MARK: - VPS fallback

    /// Runs the trafilatura reader on vault-vps over SSH. Mirrors the
    /// transport of `SearXNGSearchService`: direct process execution, no
    /// local shell interpolation.
    private func readViaVPS(_ url: URL) async throws -> String {
        guard let host = vpsHost else { throw PageReadError.empty }
        let escaped = url.absoluteString
            .replacingOccurrences(of: "'", with: "%27")
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            host,
            "~/search-tools/venv/bin/python ~/search-tools/read_page.py '\(escaped)'",
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { finished in
                        let output = stdout.fileHandleForReading.readDataToEndOfFile()
                        guard finished.terminationStatus == 0 else {
                            let message = String(
                                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                                as: UTF8.self
                            )
                            continuation.resume(throwing: PageReadError.failed(
                                message.isEmpty
                                    ? "reader exited with \(finished.terminationStatus)"
                                    : message
                            ))
                            return
                        }
                        continuation.resume(returning: String(decoding: output, as: UTF8.self))
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: PageReadError.failed(
                            error.localizedDescription
                        ))
                    }
                }
            }
            group.addTask { [requestTimeout] in
                try await Task.sleep(for: requestTimeout)
                process.terminate()
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
