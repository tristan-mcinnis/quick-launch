import Foundation
@testable import QuickLaunch

/// In-memory pasteboard. Tests read `string` instead of the real clipboard.
@MainActor
final class FakePasteboard: PasteboardWriting {
    var string: String?
    /// Every write, kept or transient.
    private(set) var writeCount = 0
    /// Writes marked transient: AI answers the Clipboard History skips.
    private(set) var transientWriteCount = 0
    /// Whether the string on the pasteboard now came from a transient write.
    private(set) var isTransient = false

    init(string: String? = nil) {
        self.string = string
    }

    func readString() -> String? { string }

    func writeString(_ text: String) {
        string = text
        writeCount += 1
        isTransient = false
    }

    func writeTransientString(_ text: String) {
        string = text
        writeCount += 1
        transientWriteCount += 1
        isTransient = true
    }
}

/// Records every open and reveal; never launches anything.
@MainActor
final class FakeWorkspace: WorkspaceOpening {
    private(set) var openedURLs: [URL] = []
    private(set) var openedWithApplication: [(url: URL, applicationURL: URL, activating: Bool)] = []
    private(set) var revealedURLs: [URL] = []
    var applicationURLsByBundleIdentifier: [String: URL] = [:]
    var applicationsThatOpenURLs: [URL] = []

    init() {}

    func open(_ url: URL) {
        openedURLs.append(url)
    }

    func open(_ url: URL, withApplicationAt applicationURL: URL, activating: Bool) {
        openedWithApplication.append((url, applicationURL, activating))
    }

    func revealInFileViewer(_ urls: [URL]) {
        revealedURLs.append(contentsOf: urls)
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        applicationURLsByBundleIdentifier[bundleIdentifier]
    }

    func applicationURLs(toOpen url: URL) -> [URL] {
        applicationsThatOpenURLs
    }
}

@MainActor
final class FakeRunningApplication: RunningApplicationControlling {
    var isTerminated = false
    private(set) var hideCount = 0
    private(set) var terminateCount = 0
    private(set) var forceTerminateCount = 0

    init() {}

    func hide() -> Bool {
        hideCount += 1
        return true
    }

    func terminate() -> Bool {
        terminateCount += 1
        isTerminated = true
        return true
    }

    func forceTerminate() -> Bool {
        forceTerminateCount += 1
        isTerminated = true
        return true
    }
}

@MainActor
final class FakeRunningApplications: RunningApplicationsQuerying {
    /// pid → terminated. Unknown pids answer `nil`.
    var terminatedByPID: [pid_t: Bool] = [:]
    var runningByBundleIdentifier: [String: FakeRunningApplication] = [:]
    var runningByBundleURL: [URL: FakeRunningApplication] = [:]

    init() {}

    func isTerminated(processIdentifier: pid_t) -> Bool? {
        terminatedByPID[processIdentifier]
    }

    func runningApplication(bundleIdentifier: String?, bundleURL: URL) -> (any RunningApplicationControlling)? {
        if let bundleIdentifier, let running = runningByBundleIdentifier[bundleIdentifier] {
            return running
        }
        return runningByBundleURL[bundleURL]
    }
}

@MainActor
final class FakeScreenGeometry: ScreenGeometryProviding {
    var screenCount: Int

    init(screenCount: Int = 1) {
        self.screenCount = screenCount
    }
}

/// Controllable local-tts stand-in. An actor, like `MockQuickService`, since
/// `LocalSpeechServicing` requires `Sendable` and the real implementation is
/// an actor too. Tests set `healthy`/`speakError` and read back `spoken` and
/// `stopCount` with `await`.
actor FakeLocalSpeechService: LocalSpeechServicing {
    var healthy: Bool
    var speakError: Error?
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0

    init(healthy: Bool = true) {
        self.healthy = healthy
    }

    func isHealthy() async -> Bool { healthy }

    func speak(_ text: String) async throws {
        if let speakError { throw speakError }
        spoken.append(text)
    }

    func stop() async {
        stopCount += 1
    }
}

/// A web search that does not answer until the test lets it: holds every
/// `search` on a continuation so a test can look at, or stop, the ask
/// while its search phase is still running.
actor GatedWebSearchService: WebSearchServicing {
    let result: String
    private(set) var searchCount = 0
    private(set) var lastQuery: String?
    private var pending: [CheckedContinuation<String, any Error>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: String) {
        self.result = result
    }

    func search(_ query: String) async throws -> String {
        searchCount += 1
        lastQuery = query
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    /// Returns once a search is being held; after a `release()` it waits
    /// for the next one.
    func waitUntilSearching() async {
        guard pending.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Lets every held search return its result.
    func release() {
        let held = pending
        pending.removeAll()
        for continuation in held { continuation.resume(returning: result) }
    }
}
