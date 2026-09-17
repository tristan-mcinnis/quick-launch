import Foundation
import Testing
@testable import QuickLaunch

@Suite("Attachment image lifecycle", .serialized)
@MainActor
struct AttachmentImageLifecycleTests {
    @Test func deletingAnOCRImageReleasesItsTextWithoutPixels() {
        let store = AttachmentSessionStore()
        let ref = ChatAttachmentRef(kind: .image, name: "Invoice")
        store.storeText(.init(text: "INVOICE 42", kindLabel: nil, notes: []), for: ref)
        #expect(store.imageCount == 0)
        store.remove([ref], keeping: [])
        #expect(store.text(for: ref) == nil)
        #expect(store.characterCount == 0)
        #expect(!store.isLoaded(ref))
    }

    @Test(arguments: [false, true])
    func sharedImageOCRSurvivesUntilItsFinalOwnerIsDeleted(withPixels: Bool) {
        let store = AttachmentSessionStore()
        let ref = ChatAttachmentRef(kind: .screenshot, name: "Shared screenshot")
        store.storeText(.init(text: "Shared words", kindLabel: nil, notes: []), for: ref)
        if withPixels { store.storeImage(AttachmentFlowTests.image, for: ref) }
        store.remove([ref], keeping: [ref])
        #expect(store.text(for: ref)?.text == "Shared words")
        #expect(store.imageCount == (withPixels ? 1 : 0))
        store.remove([ref], keeping: [])
        #expect(store.characterCount == 0)
        #expect(store.imageByteCount == 0)
        #expect(!store.isLoaded(ref))
    }

    @Test func unavailableImagesAreNamedOnTheirOriginalAndRetriedTurns() {
        let ref = ChatAttachmentRef(kind: .image, name: "Receipt.png")
        let messages = [
            QuickMessage(role: .user, content: "read the total", attachments: [ref]),
            QuickMessage(role: .assistant, content: "Earlier answer"),
            QuickMessage(role: .user, content: "read the total again", attachments: [ref]),
        ]
        let result = AttachmentRequestComposer.compose(messages: messages, text: { _ in nil }, share: .max)
        for index in [0, 2] {
            #expect(result.messages[index].content.contains("Receipt.png"))
            #expect(result.messages[index].content.contains("image and extracted text are unavailable"))
            #expect(result.messages[index].content.contains("attached again"))
        }
    }

    private func make() async -> (QuickViewModel, MockQuickService) {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        // The chat answers on a model the app knows nothing about, and the
        // configured image route names it too. This test is about what
        // happens when that route is taken away; a model the catalogue knows
        // reads images would keep the route on its own.
        if let index = settings.providers.firstIndex(where: { $0.id == InferenceProvider.deepSeekID }) {
            settings.providers[index].selectedModel = "vision-test"
        }
        settings.visionProviderID = InferenceProvider.deepSeekID
        settings.visionModel = "vision-test"
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Answer.", finishReason: "stop")])
        let vm = QuickViewModel(
            settings: settings, service: service, pasteboard: FakePasteboard(),
            workspace: FakeWorkspace(), attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.overlayPresenter = RecordingPresenter()
        vm.openQuickAI()
        vm.attachmentTray.add(.image(AttachmentFlowTests.image, name: "Receipt.png", kind: .image))
        await vm.attachmentTray.waitUntilRead()
        vm.input = "read the receipt"
        await vm.submit()
        return (vm, service)
    }

    private func removeVisionRoute(_ vm: QuickViewModel) {
        vm.settings.visionProviderID = InferenceProvider.mlxVisionID
        vm.settings.visionModel = ""
        if let index = vm.settings.providers.firstIndex(where: { $0.id == InferenceProvider.mlxVisionID }) {
            vm.settings.providers[index].selectedModel = ""
        }
    }

    @Test(arguments: [false, true])
    func earlierImageUsesOCRWhenVisionBecomesUnavailable(retry: Bool) async throws {
        let (vm, service) = await make()
        #expect(await service.lastImages == [AttachmentFlowTests.image])
        let original = try #require(vm.conversationMessages.first)
        let ref = try #require(original.attachmentRefs.first)
        #expect(vm.attachmentStore.text(for: ref) == nil)
        vm.recognizeImageText = { _ in "RECEIPT TOTAL 42" }
        removeVisionRoute(vm)
        #expect(!vm.resolveChatRoute(hasImages: true).canSendImages)
        if retry {
            await vm.regenerateLastAnswer()
        } else {
            vm.input = "what was the total?"
            await vm.submit()
        }
        #expect(await service.lastImages.isEmpty)
        let sent = await service.lastMessages
        #expect(sent.contains { $0.role == .user && $0.content.contains("RECEIPT TOTAL 42") })
        #expect(vm.attachmentStore.text(for: ref)?.text == "RECEIPT TOTAL 42")
    }

    @Test(arguments: [false, true])
    func missingEarlierImageProducesARequestNotice(retry: Bool) async throws {
        let (vm, service) = await make()
        vm.attachmentStore.removeAll() // Relaunch/eviction: references remain, pixels do not.
        vm.recognizeImageText = { _ in
            Issue.record("Missing pixels must not trigger OCR")
            return ""
        }
        if retry {
            await vm.regenerateLastAnswer()
        } else {
            vm.input = "what was the total?"
            await vm.submit()
        }
        #expect(await service.lastImages.isEmpty)
        let sent = await service.lastMessages
        #expect(sent.contains {
            $0.role == .user && $0.content.contains("Receipt.png")
                && $0.content.contains("image and extracted text are unavailable")
        })
    }
}
