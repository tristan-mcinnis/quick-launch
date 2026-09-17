import Foundation

/// Reads a web page and returns its readable text content.
protocol WebPageReading: Sendable {
    func read(_ url: URL) async throws -> String
    /// The readable text and, when the reader kept it, the raw body it read,
    /// so an attached page snapshot can hold the bytes, not only the derived
    /// text. The default returns no body: an extracted-text-only reader.
    func readWithBody(_ url: URL) async throws -> (text: String, body: Data?)
}

extension WebPageReading {
    func readWithBody(_ url: URL) async throws -> (text: String, body: Data?) {
        (try await read(url), nil)
    }
}
