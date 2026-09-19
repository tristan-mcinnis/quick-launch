import AppKit
import Foundation
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import QuickLaunch

/// A real native drag provider whose payload is held behind a deterministic
/// gate. The lock protects its callback, which AppKit may request on any queue.
private final class GatedDropData: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Data?, (any Error)?) -> Void)?
    private var data: Data?
    private var requested = false
    private var delivered = false

    var hasRequest: Bool { lock.withLock { requested } }

    func register(_ callback: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        let ready = lock.withLock { () -> Data? in
            requested = true
            self.callback = callback
            guard let data, !delivered else { return nil }
            delivered = true
            return data
        }
        if let ready { callback(ready, nil) }
    }

    func release(_ data: Data) {
        let callback = lock.withLock { () -> (@Sendable (Data?, (any Error)?) -> Void)? in
            self.data = data
            guard let callback = self.callback, !delivered else { return nil }
            delivered = true
            return callback
        }
        callback?(data, nil)
    }
}

@Suite("Attachment drop continuity", .serialized)
@MainActor
struct AttachmentDropContinuityTests {
    private func gatedFile(_ name: String) -> (NSItemProvider, GatedDropData, Data) {
        let gate = GatedDropData()
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            gate.register(completion)
            return Progress(totalUnitCount: 1)
        }
        let data = URL(fileURLWithPath: "/tmp/quick-launch-gated-drop/\(name)").dataRepresentation
        return (provider, gate, data)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        // Generous on purpose: the full suite runs thousands of tests in
        // parallel, and a MainActor state change can be starved past a short
        // deadline under load. A real failure still fails, just later.
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func model(service: MockQuickService, extractor: FakeAttachmentExtractor) -> QuickViewModel {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: service, attachmentExtractor: extractor)
        vm.overlayPresenter = RecordingPresenter()
        vm.openQuickAI()
        return vm
    }

    @Test func sendWaitsForTheNativeDropBeforeSendingItsFile() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Read it.", finishReason: "stop")])
        let vm = model(service: service, extractor: FakeAttachmentExtractor())
        let (provider, gate, data) = gatedFile("report.pdf")
        vm.attachmentTray.acceptDrop([provider])
        #expect(vm.attachmentTray.items.count == 1)
        #expect(vm.attachmentTray.isReading, "a dropped file is visibly pending before AppKit resolves it")
        vm.input = "Summarise this file"
        let send = Task { await vm.submit() }
        #expect(await eventually { gate.hasRequest && vm.isWaitingForAttachments })
        #expect(await service.sendCallCount == 0)
        gate.release(data)
        await send.value
        #expect(await service.sendCallCount == 1)
        #expect(await service.lastPrompt?.contains("Text of report.pdf.") == true)
        #expect(vm.conversationMessages.first?.attachmentRefs.map(\.name) == ["report.pdf"])
    }

    @Test func openingFullChatTransfersAnUnresolvedNativeDrop() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Read it.", finishReason: "stop")])
        let extractor = FakeAttachmentExtractor()
        let quick = model(service: service, extractor: extractor)
        let full = model(service: service, extractor: extractor)
        let (provider, gate, data) = gatedFile("handoff.txt")
        quick.attachmentTray.acceptDrop([provider])
        quick.input = "Read the attached file"
        #expect(await eventually { gate.hasRequest })
        quick.aiChatOpener = { handoff in
            if let handoff { full.adoptAIChatHandoff(handoff) }
        }
        quick.continueInAIChat()
        #expect(quick.attachmentTray.isEmpty)
        #expect(full.attachmentTray.isReading)
        let send = Task { await full.submit() }
        #expect(await eventually { full.isWaitingForAttachments })
        #expect(await service.sendCallCount == 0)
        gate.release(data)
        await send.value
        #expect(await service.lastPrompt?.contains("Text of handoff.txt.") == true)
        #expect(await extractor.requested == ["handoff.txt"], "handoff continues the same provider read")
    }

    @Test func consecutiveDropsKeepBothPendingFilesInOrder() async {
        let tray = AttachmentTray(extractor: FakeAttachmentExtractor())
        let (first, firstGate, firstData) = gatedFile("first.txt")
        let (second, secondGate, secondData) = gatedFile("second.txt")
        tray.acceptDrop([first])
        tray.acceptDrop([second])
        #expect(tray.items.count == 2)
        #expect(await eventually { firstGate.hasRequest && secondGate.hasRequest })
        secondGate.release(secondData)
        firstGate.release(firstData)
        await tray.waitForDrop()
        #expect(tray.readyContents.map(\.ref.name) == ["first.txt", "second.txt"])
    }

    @Test func duplicateDroppedFilesBecomeOneAttachment() async {
        let tray = AttachmentTray(extractor: FakeAttachmentExtractor())
        let (first, firstGate, firstData) = gatedFile("repeat.txt")
        let (second, secondGate, secondData) = gatedFile("repeat.txt")
        tray.acceptDrop([first, second])
        #expect(await eventually { firstGate.hasRequest && secondGate.hasRequest })
        firstGate.release(firstData)
        #expect(await eventually { tray.readyContents.count == 1 })
        secondGate.release(secondData)
        await tray.waitForDrop()
        #expect(tray.items.count == 1)
        #expect(tray.readyContents.map(\.ref.name) == ["repeat.txt"])
        #expect(tray.notice == "repeat.txt is already attached.")
    }

    @Test func escapeCancelsThePendingDropAndKeepsTheDraft() async {
        let service = MockQuickService()
        let vm = model(service: service, extractor: FakeAttachmentExtractor())
        let (provider, gate, data) = gatedFile("cancelled.txt")
        vm.attachmentTray.acceptDrop([provider])
        vm.input = "Keep this draft"
        let finished = Mutex(false)
        let send = Task {
            await vm.submit()
            finished.withLock { $0 = true }
        }
        #expect(await eventually { gate.hasRequest && vm.isWaitingForAttachments })
        vm.cancel()
        #expect(await eventually { finished.withLock { $0 } }, "cancellation cannot wait for the provider callback")
        #expect(vm.input == "Keep this draft")
        #expect(vm.attachmentTray.isEmpty)
        gate.release(data)
        await send.value
        #expect(await service.sendCallCount == 0)
        #expect(vm.attachmentTray.isEmpty, "a late callback never resurrects a removed drop")
    }
}
