import AppKit
import Foundation
import Testing
@testable import QuickLaunch

// MARK: - A. House command refresh keeps the newest request

/// A status source whose first read waits on a gate, so a test can request a
/// second refresh while the first is in flight. Each read returns the status
/// current when the read began; nothing sleeps.
private actor GatedStatusDispatcher: HouseCommandDispatching {
    private var recording = false
    private var gate: CheckedContinuation<Void, Never>?
    private var blockedWaiter: CheckedContinuation<Void, Never>?
    private var firstReadBlocked = false
    private var released = false
    private(set) var reads = 0

    func setRecording(_ value: Bool) { recording = value }

    func status(for manifest: HouseCommandManifest) async throws -> HouseCommandStatus? {
        reads += 1
        let snapshot = HouseCommandStatus(flags: ["recording": recording], detail: nil)
        if reads == 1 && !released {
            firstReadBlocked = true
            blockedWaiter?.resume()
            blockedWaiter = nil
            await withCheckedContinuation { gate = $0 }
        }
        return snapshot
    }

    func waitUntilFirstReadBlocked() async {
        if firstReadBlocked { return }
        await withCheckedContinuation { blockedWaiter = $0 }
    }

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }

    func run(_ command: HouseCommand, argument: String?, in manifest: HouseCommandManifest) async throws -> HouseCommandOutcome {
        .completed("ok")
    }

    func choices(for command: HouseCommand, in manifest: HouseCommandManifest) async throws -> [HouseCommandChoice] { [] }
}

private let staleRTIManifest = """
{
  "schema": 1, "app": "rti", "name": "RTI", "transport": "socket",
  "endpoint": "/Users/fixture/.config/rti/control.sock", "status": "status",
  "commands": [
    {"id": "record.start", "title": "Start Recording", "verb": "start", "needs": null, "unavailableWhen": "recording"},
    {"id": "record.stop", "title": "Stop Recording", "verb": "stop", "needs": null, "unavailableWhen": "!recording"}
  ]
}
"""

// MARK: - B. Inline translation: a late older reply never shows

/// Answers by phrase. A phrase listed in `held` waits for `release(_:)`, so a
/// test can make an older request finish after a newer one. Waits are on
/// continuations, never on the clock.
private actor ReplyDesk {
    private var held: Set<String>
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var requested: [String] = []
    private var requestWaiters: [(count: Int, cont: CheckedContinuation<Void, Never>)] = []
    private var delivered: Set<String> = []
    private var deliveredWaiters: [String: CheckedContinuation<Void, Never>] = [:]

    init(held: Set<String>) { self.held = held }

    func begin(_ phrase: String) async {
        requested.append(phrase)
        for waiter in requestWaiters where requested.count >= waiter.count { waiter.cont.resume() }
        requestWaiters.removeAll { requested.count >= $0.count }
        if held.contains(phrase) {
            await withCheckedContinuation { gates[phrase] = $0 }
        }
    }

    func finish(_ phrase: String) {
        delivered.insert(phrase)
        deliveredWaiters.removeValue(forKey: phrase)?.resume()
    }

    func waitForRequests(_ count: Int) async {
        if requested.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func release(_ phrase: String) {
        held.remove(phrase)
        gates.removeValue(forKey: phrase)?.resume()
    }

    func waitUntilDelivered(_ phrase: String) async {
        if delivered.contains(phrase) { return }
        await withCheckedContinuation { deliveredWaiters[phrase] = $0 }
    }
}

private struct DeskService: QuickService {
    let desk: ReplyDesk
    let replies: [String: String]

    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        let prompt = messages.last?.content ?? ""
        let phrase = replies.keys.first { prompt.hasSuffix($0) } ?? ""
        let reply = replies[phrase] ?? ""
        return AsyncThrowingStream { continuation in
            let producer = Task {
                await desk.begin(phrase)
                continuation.yield(StreamDelta(text: reply, finishReason: "stop"))
                continuation.finish()
                await desk.finish(phrase)
            }
            continuation.onTermination = { _ in _ = producer }
        }
    }

    func send(messages: [QuickMessage], images: [QuickImageAttachment]) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: messages)
    }

    func send(
        messages: [QuickMessage],
        images: [QuickImageAttachment],
        turnImages: [UUID: [QuickImageAttachment]]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: messages)
    }

    func healthCheck() async throws -> Bool { true }
}

@Suite("Stale results", .serialized)
@MainActor
struct StaleResultTests {

    @Test func aRefreshRequestedDuringARefreshStillRunsAndTheNewestRowsWin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try staleRTIManifest.write(to: root.appendingPathComponent("rti.json"), atomically: true, encoding: .utf8)

        let dispatcher = GatedStatusDispatcher()
        // A clock that never moves: both reads fall inside the 2 s freshness
        // window, so only a forced follow-up can see the new status.
        let catalog = HouseCommandCatalog(
            directory: HouseCommandDirectory(root: root, socketExists: { _ in true }),
            dispatcher: dispatcher,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let vm = QuickViewModel(service: MockQuickService(), houseCommandCatalog: catalog)

        vm.refreshHouseCommands()
        await dispatcher.waitUntilFirstReadBlocked()

        // The app's state changes, and a second refresh is asked for while
        // the first is still waiting on the old read.
        await dispatcher.setRecording(true)
        vm.refreshHouseCommands()
        await dispatcher.release()
        await vm.waitForHouseCommandRefreshForTesting()

        #expect(vm.houseCommandItems.map(\.title) == ["Stop Recording"])
        #expect(await dispatcher.reads == 2, "exactly one follow-up refresh, no overlap")
    }

    @Test func aLateReplyToAnOlderQueryNeverReplacesTheNewerTranslation() async throws {
        let desk = ReplyDesk(held: ["good morning"])
        let service = DeskService(desk: desk, replies: ["good morning": "OLD-ja", "good night": "NEW-fr"])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: service, pasteboard: FakePasteboard())

        vm.input = "good morning in japanese"
        vm.rootInputDidChange(vm.input)
        await desk.waitForRequests(1)        // A's reply is now held
        let olderTask = try #require(vm.inlineTranslationTaskForTesting)

        vm.input = "good night in french"
        vm.rootInputDidChange(vm.input)
        await desk.waitForRequests(2)
        await vm.inlineTranslationSettled()  // B's reply arrives first
        #expect(vm.inlineTranslation?.text == "NEW-fr")
        #expect(vm.inlineTranslation?.status == .ready)

        await desk.release("good morning")   // A arrives late
        await desk.waitUntilDelivered("good morning")
        await olderTask.value                // A's handler has run to its end

        #expect(vm.inlineTranslation?.query.phrase == "good night")
        #expect(vm.inlineTranslation?.text == "NEW-fr")
        #expect(vm.inlineTranslation?.status == .ready)
    }

    // MARK: - C. A corrupt screenshot text index recovers

    private func corruptIndexFixture(_ bytes: Data) throws -> (folder: URL, store: URL, item: LauncherCatalogItem) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-stale-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        try rep.representation(using: .png, properties: [:])!
            .write(to: folder.appendingPathComponent("Screenshot 2026-01-02 at 03.04.05.png"))
        let store = folder.appendingPathComponent("screenshot-text-index.json")
        try bytes.write(to: store)
        let item = try #require(ScreenshotLibrary.items(inFolders: [folder]).first)
        return (folder, store, item)
    }

    @Test(arguments: [
        Data("not json at all \u{0}\u{1}garbage".utf8),
        Data(#"{"/tmp/a.png":{"text":"hel"#.utf8),
        Data(),
    ])
    func aCorruptTextIndexLoadsEmptyAndRefreshRebuildsIt(bytes: Data) async throws {
        let (folder, store, item) = try corruptIndexFixture(bytes)
        defer { try? FileManager.default.removeItem(at: folder) }

        let index = ScreenshotTextIndex(storeURL: store)
        #expect(index.indexedCount == 0, "a corrupt file is an empty index, not a crash")
        #expect(index.text(for: item) == nil)

        index.refresh(for: [item])
        await index.waitForIndexing()
        index.waitForPendingWrites()
        #expect(index.indexedCount == 1, "the refresh rebuilds the entry")

        let reloaded = ScreenshotTextIndex(storeURL: store)
        #expect(reloaded.indexedCount == 1, "the rebuilt file on disk is valid again")
    }
}
