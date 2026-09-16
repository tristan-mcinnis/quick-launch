import Foundation

/// Read access to `~/memory` and the canonical task backends for the model's
/// memory and task tools. The app implements it with the `recall` CLI; tests
/// pass a fake.
protocol MemoryRecalling: Sendable {
    /// Ranked lines that match `query`. An empty result is not an error.
    func search(_ query: String) async throws -> MemorySearchResult
    /// Today's captures and due, overdue, and in-progress task sections.
    func today() async throws -> MemoryToday
    /// The complete open backlog across both canonical task backends.
    func openTasks() async throws -> RecalledTaskList
}

/// Capture to Memory: the user's own ⌘K action, never a model tool.
protocol MemoryCapturing: Sendable {
    func remember(_ text: String) async throws
}

/// Opens a local file in its default app (a source under an answer).
protocol LocalFileOpening: Sendable {
    func open(_ url: URL) async throws
}
