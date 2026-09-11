// AttachmentPrivacyTests: what attaching keeps, and where (spec 3.8, with
// WP-D's session-only change). Chat history keeps a reference (name, kind,
// size, hash, path or URL), never the text and never a picture's pixels;
// the text lives in memory for the app session, bounded; the disk cache is
// built but off; and no attach path writes the pasteboard.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Attachment privacy", .serialized)
@MainActor
struct AttachmentPrivacyTests {
    private static let sentinel = "SENTINEL-7f3a9c-the-quarterly-numbers-are-confidential"

    private func historyFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-privacy-\(UUID().uuidString).json")
    }

    private func make(historyFileURL: URL, extractor: FakeAttachmentExtractor) -> (QuickViewModel, MockQuickService, FakePasteboard) {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let service = MockQuickService()
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            pasteboard: pasteboard,
            historyFileURL: historyFileURL,
            workspace: FakeWorkspace(),
            attachmentExtractor: extractor
        )
        vm.overlayPresenter = RecordingPresenter()
        return (vm, service, pasteboard)
    }

    @Test func theHistoryFileKeepsTheReferenceAndNeverTheText() async throws {
        let file = historyFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let extractor = FakeAttachmentExtractor()
        let text = String(repeating: Self.sentinel + " ", count: 1_000)
        #expect(text.count > 50_000)
        await extractor.set(.content(AttachmentFlowTests.document("Board pack.pdf", text: text, pages: 12)), for: "Board pack.pdf")
        let (vm, service, _) = make(historyFileURL: file, extractor: extractor)
        await service.setResponses([StreamDelta(text: "Noted.", finishReason: "stop")])
        vm.openQuickAI()
        vm.attachmentTray.add(.file(AttachmentFlowTests.file("Board pack.pdf")))
        await vm.attachmentTray.waitUntilRead()
        vm.input = "summarise the pack"
        await vm.submit()
        #expect(await service.lastPrompt?.contains(Self.sentinel) == true, "the model got the text")

        QuickHistoryStore.waitForPendingWrites()
        let json = try String(contentsOf: file, encoding: .utf8)
        #expect(!json.contains(Self.sentinel), "no extracted text in the history JSON")
        #expect(json.contains("Board pack.pdf"))
        #expect(json.contains("contentHash"))
        #expect(json.utf8.count < 4_000, "a reference, not a document: \(json.utf8.count) bytes")
        #expect(!json.contains("untrusted_attachment"), "the saved question is what was typed")
    }

    @Test func aPictureLeavesNoPixelsPathOrHashInTheHistory() async throws {
        let file = historyFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let (vm, service, _) = make(historyFileURL: file, extractor: FakeAttachmentExtractor())
        await service.setResponses([StreamDelta(text: "A window.", finishReason: "stop")])
        vm.openQuickAI()
        vm.attachmentTray.add(.image(AttachmentFlowTests.image, name: "Pasted image", kind: .image))
        vm.pendingImage = AttachmentRenderProofTests.screenshot(width: 20, height: 20)
        await vm.attachmentTray.waitUntilRead()
        vm.input = "what is this"
        await vm.submit()

        QuickHistoryStore.waitForPendingWrites()
        let json = try String(contentsOf: file, encoding: .utf8)
        let base64 = AttachmentFlowTests.image.data.base64EncodedString()
        #expect(!json.contains(String(base64.prefix(40))))
        #expect(!json.contains("base64"))
        let saved = try #require(QuickHistoryStore.load(from: file, migratingFrom: nil).first)
        let refs = saved.messages.flatMap(\.attachmentRefs)
        #expect(refs.map(\.kind) == [.screenshot, .image])
        #expect(refs.allSatisfy { $0.path == nil && $0.contentHash == nil && $0.url == nil })
        #expect(refs.map(\.pixelWidth) == [20, 40])
    }

    @Test func theDiskCacheIsBuiltButOff() {
        #expect(AttachmentSessionStore.attachmentCacheEnabled == false)
    }

    @Test func theSessionStoreIsBoundedAndLetsTheOldestGoFirst() {
        let store = AttachmentSessionStore(characterLimit: 100, imageByteLimit: 10)
        let refs = (0..<3).map { index in
            ChatAttachmentRef(kind: .text, name: "\(index).txt", contentHash: "hash\(index)", extractorVersion: 1)
        }
        for ref in refs {
            store.storeText(AttachmentSessionStore.Text(text: String(repeating: "x", count: 40), kindLabel: nil, notes: []), for: ref)
        }
        #expect(store.characterCount <= 100)
        #expect(!store.isLoaded(refs[0]), "the oldest went")
        #expect(store.isLoaded(refs[1]) && store.isLoaded(refs[2]))

        // A use keeps an entry: the one read last stays.
        _ = store.text(for: refs[1])
        store.storeText(AttachmentSessionStore.Text(text: String(repeating: "y", count: 40), kindLabel: nil, notes: []), for: refs[0])
        #expect(store.isLoaded(refs[1]))
        #expect(!store.isLoaded(refs[2]))

        // The same file attached twice shares one entry.
        let again = ChatAttachmentRef(kind: .text, name: "copy.txt", contentHash: "hash1", extractorVersion: 1)
        #expect(store.isLoaded(again))
    }

    @Test func picturesAreBoundedToo() {
        let store = AttachmentSessionStore(characterLimit: 100, imageByteLimit: 5)
        let first = ChatAttachmentRef(kind: .image, name: "a")
        let second = ChatAttachmentRef(kind: .image, name: "b")
        store.storeImage(QuickImageAttachment(data: Data([1, 2, 3, 4]), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1), for: first)
        store.storeImage(QuickImageAttachment(data: Data([5, 6, 7, 8]), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1), for: second)
        #expect(store.image(for: first) == nil)
        #expect(store.image(for: second) != nil)
    }

    @Test func noAttachPathWritesThePasteboard() async {
        let extractor = FakeAttachmentExtractor()
        let file = historyFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let (vm, service, pasteboard) = make(historyFileURL: file, extractor: extractor)
        pasteboard.string = "https://example.com/page"
        await service.setResponses([StreamDelta(text: "ok", finishReason: "stop")])
        vm.openQuickAI()
        vm.attachFinderSelection()
        vm.openAddContextMenu()
        vm.runAddContextRow(.link)
        vm.submitAttachmentLink()
        vm.attachmentTray.add(.file(AttachmentFlowTests.file("a.txt")))
        vm.attachmentTray.add(.image(AttachmentFlowTests.image, name: "Pasted image", kind: .image))
        vm.attachmentTray.add(.selection("picked words", appName: "Notes"))
        _ = vm.attachmentTray.paste(AttachmentPasteboardContents(string: "https://example.com/b"), composerText: "")
        await vm.attachmentTray.waitUntilRead()
        vm.input = "go"
        await vm.submit()
        // The view model's pasteboard seam saw no write. (The system
        // pasteboard's change count is shared with every other app and test,
        // so it is not measured here; `AttachmentTrayTests` checks it for the
        // one path that reads it.)
        #expect(pasteboard.writeCount == 0)
    }
}
