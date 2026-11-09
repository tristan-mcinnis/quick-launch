import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screenshot index lifecycle", .timeLimit(.minutes(1)))
@MainActor
struct ScreenshotIndexLifecycleTests {
    @Test func cancelledOCRCannotPublishOrFinishItsReplacement() async {
        let reader = ControlledOCR()
        let index = ScreenshotTextIndex(storeURL: nil) { path, mode in
            await reader.read(path, mode)
        }
        let item = screenshot("replacement")
        index.refresh(for: [item], mode: .accurate)
        await reader.waitForCalls(1)
        let oldPass = await waitingForCurrentPass(index)

        index.cancel()
        #expect(!index.progress.isRunning)
        index.refresh(for: [item], mode: .fast)
        await reader.waitForCalls(2)
        let replacementPass = await waitingForCurrentPass(index)
        await reader.complete(0, with: "stale")
        await oldPass.value
        #expect(index.text(for: item) == nil)
        #expect(index.progress == .init(completed: 0, total: 1))

        // Old cleanup must leave the replacement able to publish its result.
        await reader.complete(1, with: "current")
        await replacementPass.value
        #expect(await reader.callCount == 2)
        #expect(index.text(for: item) == "current")
        #expect(index.progress == .init(completed: 1, total: 1))
    }

    @Test func cancelledOCRCannotRepopulateClearedCatalog() async {
        let reader = ControlledOCR()
        let index = ScreenshotTextIndex(storeURL: nil) { path, mode in
            await reader.read(path, mode)
        }
        let item = screenshot("removed")
        index.refresh(for: [item])
        await reader.waitForCalls(1)
        let oldPass = await waitingForCurrentPass(index)
        index.cancel()
        index.refresh(for: [])
        await reader.complete(0, with: "removed image text")
        await oldPass.value
        #expect(index.indexedCount == 0)
        #expect(index.progress == .init())
        #expect(index.text(for: item) == nil)
    }

    private func screenshot(_ name: String) -> LauncherCatalogItem {
        LauncherCatalogItem(
            kind: .screenshot, itemID: name, title: name, detail: "",
            value: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    }

    /// Capture the old pass's completion before cancel drops its handle.
    /// Both the signal and wait start on MainActor before the caller resumes.
    private func waitingForCurrentPass(_ index: ScreenshotTextIndex) async -> Task<Void, Never> {
        let started = StartSignal()
        let task = Task { @MainActor in
            started.signal()
            await index.waitForIndexing()
        }
        await started.wait()
        return task
    }
}

@MainActor
private final class StartSignal {
    private var signalled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func signal() {
        signalled = true
        continuation?.resume()
        continuation = nil
    }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor ControlledOCR {
    private var requests: [CheckedContinuation<String, Never>?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var callCount: Int { requests.count }

    func read(_ path: String, _ mode: ClipboardOCRMode) async -> String {
        await withCheckedContinuation { continuation in
            requests.append(continuation)
            let ready = waiters.filter { $0.0 <= requests.count }
            waiters.removeAll { $0.0 <= requests.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForCalls(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, with text: String) {
        requests[index]?.resume(returning: text)
        requests[index] = nil
    }
}
