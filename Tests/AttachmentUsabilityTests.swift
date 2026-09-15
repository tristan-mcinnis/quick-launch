import Foundation
import Testing
@testable import QuickLaunch

@Suite("Attachment usability", .serialized)
@MainActor
struct AttachmentUsabilityTests {
    private func settings() -> QuickSettings {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        return settings
    }

    @Test func aSelectedTextSnapshotMovesWithTheQuickChatDraft() async throws {
        let selection = AttachmentSelectionService(text: "The original selected passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "An answer", finishReason: "stop")])
        let launcher = QuickViewModel(settings: settings(), service: service, selectedTextService: selection)
        let chat = QuickViewModel(store: launcher.store, service: service)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        launcher.aiChatOpener = { handoff in window.open(handoff: handoff) }
        launcher.rememberSelectionTarget(SelectionTarget(processIdentifier: 42, applicationName: "Editor"))
        launcher.captureLaunchSelection()
        launcher.openQuickAI()
        launcher.input = "Explain this"
        launcher.continueInAIChat()
        #expect(chat.launchSelection?.text == "The original selected passage")
        #expect(chat.launchSelection?.appName == "Editor")
        #expect(launcher.launchSelection == nil)
        #expect(chat.input == "Explain this")
        await chat.submit()
        #expect(await service.lastPrompt?.contains("The original selected passage") == true)
        #expect(chat.launchSelection == nil)
        chat.input = "One more question"
        await chat.submit()
        #expect(await service.lastPrompt == "One more question")
    }

    @Test func attachingSelectedTextKeepsTheAlreadyAttachedScreenshotAndDraft() async {
        let selection = AttachmentSelectionService(text: "A useful passage")
        let vm = QuickViewModel(settings: settings(), service: MockQuickService(), selectedTextService: selection)
        vm.rememberSelectionTarget(SelectionTarget(processIdentifier: 42, applicationName: "Editor"))
        vm.openQuickAI()
        let image = QuickImageAttachment(data: Data([1, 2, 3]), mimeType: "image/png", pixelWidth: 2, pixelHeight: 2)
        vm.pendingImages = [image]
        vm.input = "Compare the image and this text"
        await vm.addContext(.selectedText)
        #expect(vm.pendingImages == [image])
        #expect(vm.pendingContext?.selectedText == "A useful passage")
        #expect(vm.input == "Compare the image and this text")
    }

    @Test func failedAttachmentStopsSendUntilItIsRemoved() async throws {
        let extractor = FakeAttachmentExtractor()
        await extractor.set(.failure("The file could not be read"), for: "missing.pdf")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "An answer", finishReason: "stop")])
        let vm = QuickViewModel(settings: settings(), service: service, attachmentExtractor: extractor)
        vm.openQuickAI()
        let failedID = try #require(vm.attachmentTray.add(.file(URL(fileURLWithPath: "/tmp/missing.pdf"))))
        vm.attachmentTray.add(.file(URL(fileURLWithPath: "/tmp/notes.txt")))
        await vm.attachmentTray.waitUntilRead()
        vm.input = "Summarize these files"
        await vm.submit()
        #expect(await service.sendCallCount == 0)
        #expect(vm.input == "Summarize these files")
        #expect(vm.attachmentTray.items.count == 2)
        #expect(vm.errorMessage?.contains("Retry or remove") == true)
        vm.attachmentTray.remove(failedID)
        await vm.submit()
        #expect(await service.sendCallCount == 1)
        #expect(await service.lastPrompt?.contains("Text of notes.txt.") == true)
    }
    @Test func retryUsesOnlyTheOldTurnAndKeepsEveryDraftAttachment() async throws {
        let extractor = FakeAttachmentExtractor()
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "First answer", finishReason: "stop")])
        let vm = QuickViewModel(settings: settings(), service: service, attachmentExtractor: extractor)
        vm.openQuickAI()
        vm.input = "First question"
        await vm.submit()
        let image = QuickImageAttachment(data: Data([7, 8, 9]), mimeType: "image/png", pixelWidth: 2, pixelHeight: 2)
        vm.pendingImages = [image]
        var context = CaptureContext(appName: "Editor")
        context.selectedText = "New draft context"
        vm.pendingContext = context
        vm.launchSelection = QuickViewModel.LaunchSelection(text: "New draft selection", appName: "Notes")
        vm.input = "A new question waiting"
        await extractor.set(.failure("Unreadable"), for: "future.pdf")
        let chipID = try #require(vm.attachmentTray.add(.file(URL(fileURLWithPath: "/tmp/future.pdf"))))
        await vm.attachmentTray.waitUntilRead()
        await vm.regenerateLastAnswer()
        #expect(await service.sendCallCount == 2)
        #expect(await service.lastPrompt == "First question")
        #expect(vm.input == "A new question waiting")
        #expect(vm.pendingImages == [image])
        #expect(vm.pendingContext == context)
        #expect(vm.launchSelection?.text == "New draft selection")
        #expect(vm.attachmentTray.items.map(\.id) == [chipID])
        #expect(vm.attachmentTray.items.first?.isFailed == true)
    }

    @Test func theSameSelectionInWindowContextAndLaunchSnapshotIsSentOnce() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Answer", finishReason: "stop")])
        let vm = QuickViewModel(settings: settings(), service: service)
        vm.openQuickAI()
        var context = CaptureContext(appName: "Editor")
        context.selectedText = "One unique selected passage"
        vm.pendingContext = context
        vm.launchSelection = QuickViewModel.LaunchSelection(text: "One unique selected passage", appName: "Editor")
        vm.input = "Explain it"
        await vm.submit()
        let prompt = await service.lastPrompt ?? ""
        #expect(prompt.components(separatedBy: "One unique selected passage").count == 2)
    }

    @Test func aFailedChipCanRetryFromTheKeyboardWithoutChangingItsPosition() async throws {
        let extractor = FakeAttachmentExtractor()
        let tray = AttachmentTray(extractor: extractor)
        await extractor.set(.failure("Try again"), for: "retry.pdf")
        let id = try #require(tray.add(.file(URL(fileURLWithPath: "/tmp/retry.pdf"))))
        await tray.waitUntilRead()
        #expect(tray.enterStrip())
        await extractor.set(.content(FakeAttachmentExtractor.madeUpContent(for: .file(URL(fileURLWithPath: "/tmp/retry.pdf")))), for: "retry.pdf")
        #expect(tray.retryFocusedFailure())
        await tray.waitUntilRead()
        #expect(tray.items.map(\.id) == [id])
        #expect(tray.items.first?.content != nil)
        #expect(tray.focusedItemID == id)
    }

    @Test func aLongSelectionReachesTheRequestWholeWhileAmbientTextIsBounded() async throws {
        let selected = String(repeating: "Selected detail. ", count: 900) + "SELECTION END"
        var context = CaptureContext(appName: "Editor")
        context.appText = String(repeating: "ambient ", count: 2_000)
        context.selectedText = selected
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Answer", finishReason: "stop")])
        let vm = QuickViewModel(settings: settings(), service: service)
        vm.openQuickAI()
        vm.pendingContext = context
        vm.input = "Explain the selection"
        await vm.submit()
        let prompt = try #require(await service.lastPrompt)
        #expect(prompt.contains(selected))
        #expect(!prompt.contains(context.appText!))
    }

    @Test func attachingContextAfterAnAnswerAsksForAQuestionInsteadOfCopyingTheOldAnswer() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "The old answer", finishReason: "stop")])
        let vm = QuickViewModel(settings: settings(), service: service)
        vm.openQuickAI()
        vm.input = "First question"
        await vm.submit()
        var context = CaptureContext(appName: "Editor")
        context.selectedText = "New selected text"
        vm.pendingContext = context
        #expect(vm.quickAIComposerAction.label == "Ask")
        #expect(vm.quickAIComposerPlaceholder == "Ask about the attached context…")
        await vm.submitResolvingFuzzyAlias()
        #expect(await service.sendCallCount == 1)
        #expect(vm.pasteboard.readString() == nil)
        #expect(vm.pendingContext == context)
        #expect(vm.errorMessage == "Ask a question about the attached context.")
    }

}

@MainActor
private final class AttachmentSelectionService: SelectedTextServicing {
    let text: String
    var isAccessibilityTrusted: Bool { true }
    init(text: String) { self.text = text }
    func currentExternalTarget() -> SelectionTarget? { nil }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        SelectedTextContext(target: target, text: text)
    }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { false }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { false }
    func openAccessibilitySettings() {}
}
