import Foundation

/// Reads a web page and returns its readable text content.
protocol WebPageReading: Sendable {
    func read(_ url: URL) async throws -> String
}
