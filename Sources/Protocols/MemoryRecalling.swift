import Foundation

/// Read access to `~/memory` for the model's `recall_memory` and
/// `recall_today` tools. The app implements it with the `recall` CLI; tests
/// pass a fake.
protocol MemoryRecalling: Sendable {
    /// Ranked lines that match `query`. An empty result is not an error.
    func search(_ query: String) async throws -> MemorySearchResult
    /// Today's captures and the open tasks across projects.
    func today() async throws -> MemoryToday
}

/// Capture to Memory: the user's own ⌘K action, never a model tool.
protocol MemoryCapturing: Sendable {
    func remember(_ text: String) async throws
}

/// Opens a local file in its default app (a source under an answer).
protocol LocalFileOpening: Sendable {
    func open(_ url: URL) async throws
}
