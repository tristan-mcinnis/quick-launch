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

    @Test func refreshDuringOCRReconcilesTheLatestCatalogWithoutAnotherRefresh() async {
        let reader = FirstGatedOCR()
        let index = ScreenshotTextIndex(storeURL: nil) { path, mode in
            await reader.read(path, mode)
        }
        let removed = screenshot("removed")
        let added = screenshot("added")
        index.refresh(for: [removed])
        await reader.waitUntilHolding()
        index.refresh(for: [added])
        await reader.release()
        await index.waitForIndexing()
        #expect(index.text(for: removed) == nil)
        #expect(index.text(for: added) == "current")
        #expect(index.indexedCount == 1)
        #expect(await reader.callCount == 2)
        #expect(index.progress == .init(completed: 1, total: 1))
    }

    @Test func repeatedRefreshPreservesUnchangedOCRAndDrainsAddedItems() async {
        let reader = FirstGatedOCR(firstResult: "original")
        let index = ScreenshotTextIndex(storeURL: nil) { path, mode in
            await reader.read(path, mode)
        }
        let original = screenshot("original")
        let added = screenshot("added")
        index.refresh(for: [original])
        await reader.waitUntilHolding()
        index.refresh(for: [original])
        index.refresh(for: [added, original, original])
        #expect(index.progress == .init(completed: 0, total: 2))
        await reader.release()
        await index.waitForIndexing()
        #expect(index.text(for: original) == "original")
        #expect(index.text(for: added) == "current")
        #expect(await reader.callCount == 2)
        #expect(index.progress == .init(completed: 2, total: 2))
    }

    @Test(arguments: [false, true])
    func refreshRejectsChangedMetadataOrMode(changeMode: Bool) async {
        let reader = FirstGatedOCR()
        let index = ScreenshotTextIndex(storeURL: nil) { path, mode in
            await reader.read(path, mode)
        }
        let original = screenshot("changed")
        var latest = original
        if !changeMode { latest.capturedAt = Date(timeIntervalSince1970: 20) }
        index.refresh(for: [original])
        await reader.waitUntilHolding()
        index.refresh(for: [latest], mode: changeMode ? .fast : .accurate)
        await reader.release()
        await index.waitForIndexing()
        #expect(index.text(for: latest) == "current")
        #expect(await reader.callCount == 2)
        #expect(index.progress == .init(completed: 1, total: 1))
    }

    @Test func refreshToEmptyRejectsAnInFlightResultWithoutCancel() async {
        let reader = FirstGatedOCR()
        let index = ScreenshotTextIndex(storeURL: nil) { path, mode in
            await reader.read(path, mode)
        }
        let removed = screenshot("removed")
        index.refresh(for: [removed])
        await reader.waitUntilHolding()
        index.refresh(for: [])
        #expect(index.progress == .init())
        await reader.release()
        await index.waitForIndexing()
        #expect(index.indexedCount == 0)
        #expect(await reader.callCount == 1)
    }

    @Test func completionCallbackCanAddWorkWithoutOrphaningIt() async {
        let reader = FirstGatedOCR(firstResult: "original")
        let index = ScreenshotTextIndex(storeURL: nil) { path, mode in
            await reader.read(path, mode)
        }
        let original = screenshot("original")
        let added = screenshot("added")
        var requestedMore = false
        index.onProgress = { progress in
            if progress == .init(completed: 1, total: 1), !requestedMore {
                requestedMore = true
                index.refresh(for: [original, added])
            }
        }
        index.refresh(for: [original])
        await reader.waitUntilHolding()
        await reader.release()
        await index.waitForIndexing()
        #expect(requestedMore)
        #expect(index.text(for: added) == "current")
        #expect(await reader.callCount == 2)
        #expect(index.progress == .init(completed: 2, total: 2))
        index.onProgress = nil
    }

    @Test func initialProgressCallbackCanCancelAndNextRefreshRecovers() async {
        let reader = FirstGatedOCR(firstResult: "recovered")
        let index = ScreenshotTextIndex(storeURL: nil) { path, mode in
            await reader.read(path, mode)
        }
        let item = screenshot("cancelled")
        index.onProgress = { progress in
            if progress.isRunning { index.cancel() }
        }
        index.refresh(for: [item])
        await index.waitForIndexing()
        #expect(index.progress == .init())
        #expect(await reader.callCount == 0)
        index.onProgress = nil
        index.refresh(for: [item])
        await reader.waitUntilHolding()
        await reader.release()
        await index.waitForIndexing()
        #expect(index.text(for: item) == "recovered")
        #expect(await reader.callCount == 1)
    }

    @Test func emptyOCRCompletesWithoutRetryAndNewItemsStillRun() async {
        let reader = FirstGatedOCR(firstResult: "")
        let index = ScreenshotTextIndex(storeURL: nil) { path, mode in
            await reader.read(path, mode)
        }
        let unreadable = screenshot("unreadable")
        let added = screenshot("added")
        index.refresh(for: [unreadable])
        await reader.waitUntilHolding()
        await reader.release()
        await index.waitForIndexing()
        #expect(index.text(for: unreadable) == "")
        #expect(!index.progress.isRunning)
        index.refresh(for: [unreadable])
        await index.waitForIndexing()
        #expect(await reader.callCount == 1)
        index.refresh(for: [unreadable, added])
        #expect(index.progress == .init(completed: 1, total: 2))
        await index.waitForIndexing()
        #expect(index.text(for: added) == "current")
        #expect(await reader.callCount == 2)
    }

    @Test func completedOCRKeepsTheByteCountCapturedBeforeItStarted() async throws {
        let reader = FirstGatedOCR()
        let index = ScreenshotTextIndex(storeURL: nil) { path, mode in
            await reader.read(path, mode)
        }
        let item = screenshot("changed-bytes")
        let url = URL(fileURLWithPath: item.value)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)
        index.refresh(for: [item])
        await reader.waitUntilHolding()
        try Data([1, 2]).write(to: url)
        await reader.release()
        await index.waitForIndexing()
        // The old text cannot be stamped with the replacement's byte count.
        #expect(index.text(for: item) == nil)
        index.refresh(for: [item])
        await index.waitForIndexing()
        #expect(index.text(for: item) == "current")
        #expect(await reader.callCount == 2)
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

/// Only the first read suspends. Missing follow-up work makes assertions
/// fail rather than leaving a test waiting for a call that never arrives.
private actor FirstGatedOCR {
    private let firstResult: String

    init(firstResult: String = "obsolete") { self.firstResult = firstResult }

    private var held: CheckedContinuation<String, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0

    func read(_ path: String, _ mode: ClipboardOCRMode) async -> String {
        callCount += 1
        guard callCount == 1 else { return "current" }
        return await withCheckedContinuation { continuation in
            held = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilHolding() async {
        if held != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        held?.resume(returning: firstResult)
        held = nil
    }
}
