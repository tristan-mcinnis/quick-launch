import Foundation

/// The harness with a short memory for the plate. Reading the plate fans out
/// to Todoist, GitHub, Slack and Outlook and takes 15 to 20 s, so a second
/// "what's on my plate" a few minutes later reuses the first read, stamped
/// with when it was read. Any write through this harness (a Todoist add, a
/// change, its undo) forgets the copy, so the next read shows the change.
/// One instance is shared by Quick AI and AI Chat.
actor CachedHarness: HarnessScripting {
    static let plateMaxAge: TimeInterval = 5 * 60

    private let inner: any HarnessScripting
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var last: PlateSnapshot?
    private var reading: Task<PlateSnapshot, Error>?
    private var generation = 0

    init(
        _ inner: any HarnessScripting,
        maxAge: TimeInterval = CachedHarness.plateMaxAge,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.inner = inner
        self.maxAge = maxAge
        self.now = now
    }

    /// The shared harness when the scripts are on this Mac, else nil.
    @MainActor static let installed: CachedHarness? = HarnessScripts.installed().map { CachedHarness($0) }

    func plate() async throws -> PlateSnapshot { try await plate(fresh: false) }

    func plate(fresh: Bool) async throws -> PlateSnapshot {
        if !fresh, let last, let readAt = last.readAt, now().timeIntervalSince(readAt) < maxAge {
            return last
        }
        // Two asks at once share one read.
        if let reading { return try await reading.value }
        let inner = self.inner
        let now = self.now
        let task = Task { () throws -> PlateSnapshot in
            var snapshot = try await inner.plate()
            snapshot.readAt = now()
            return snapshot
        }
        reading = task
        let started = generation
        defer { reading = nil }
        let snapshot = try await task.value
        // A write that landed while the plate was read makes this read old.
        if started == generation { last = snapshot }
        return snapshot
    }

    func calendar(_ arguments: [String]) async throws -> String { try await inner.calendar(arguments) }
    func findTasks(_ words: String) async throws -> [TaskMatch] { try await inner.findTasks(words) }
    func findEvents(_ words: String) async throws -> [EventMatch] { try await inner.findEvents(words) }

    func addTodoist(_ proposal: TodoistProposal) async throws -> TodoistAdded {
        forget()
        return try await inner.addTodoist(proposal)
    }

    func apply(_ change: ChangeProposal) async throws {
        forget()
        try await inner.apply(change)
    }

    private func forget() {
        last = nil
        generation += 1
    }
}
