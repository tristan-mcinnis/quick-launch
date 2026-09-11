import Testing
import Foundation
import AppKit
@testable import QuickLaunch

// These tests are written in the RED phase — QuickViewModel does not yet exist.
// They define the intended API and will compile once QuickViewModel is implemented.

@MainActor
@Suite("QuickViewModel", .serialized)
struct QuickViewModelTests {

    // MARK: - 1. Streaming output accumulates correctly

    @Test func testSubmitStreamsOutput() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "Hello", finishReason: nil),
            StreamDelta(text: " world", finishReason: nil),
            StreamDelta(text: "!", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "Say hello"
        await vm.submit()
        #expect(vm.output == "Hello world!")
    }

    // MARK: - 2. Error is cleared before streaming starts

    @Test func testSubmitClearsErrorBeforeStreaming() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "ok", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "prompt"
        // Pre-seed an error
        vm.errorMessage = "previous error"
        await vm.submit()
        #expect(vm.errorMessage == nil)
    }

    // MARK: - 3. Output is cleared before a new stream starts

    @Test func testSubmitClearsOutputBeforeNewStream() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "fresh", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "first"
        vm.output = "stale result from previous run"
        await vm.submit()
        #expect(vm.output == "fresh")
    }

    // MARK: - 4. isStreaming is true during stream

    @Test func testIsStreamingTrueDuringStream() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "chunk", finishReason: nil),
            StreamDelta(text: " more", finishReason: nil),
        ])
        await service.setDelay(.milliseconds(200))

        let vm = QuickViewModel(service: service)
        vm.input = "long prompt"

        let submitTask = Task { await vm.submit() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isStreaming == true)
        await submitTask.value
    }

    // MARK: - 5. isStreaming is false after stream finishes

    @Test func testIsStreamingFalseAfterStream() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "done", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "prompt"
        await vm.submit()
        #expect(vm.isStreaming == false)
    }

    // MARK: - 6. Auto-copy enabled writes to clipboard on completion

    @Test func testAutoCopyOnCompletionWhenEnabled() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "Copied text", finishReason: .some("stop")),
        ])
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(service: service, pasteboard: pasteboard)
        vm.settings.autoCopy = true
        vm.input = "Give me something to copy"
        await vm.submit()
        #expect(pasteboard.string == "Copied text")
    }

    // MARK: - 7. Auto-copy disabled leaves clipboard untouched

    @Test func testAutoCopyDisabledSkipsClipboard() async throws {
        let pasteboard = FakePasteboard(string: "sentinel")

        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "Should not be copied", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service, pasteboard: pasteboard)
        vm.settings.autoCopy = false
        vm.input = "Don't copy this"
        await vm.submit()

        #expect(pasteboard.string == "sentinel")
        #expect(pasteboard.writeCount == 0)
    }

    // MARK: - 8. cancel() stops isStreaming

    @Test func testCancelStopsStreaming() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "chunk one", finishReason: nil),
            StreamDelta(text: "chunk two", finishReason: nil),
        ])
        await service.setDelay(.milliseconds(200))

        let vm = QuickViewModel(service: service)
        vm.input = "Long running prompt"

        let submitTask = Task { await vm.submit() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(vm.isStreaming == true)

        vm.cancel()
        await submitTask.value

        #expect(vm.isStreaming == false)
    }

    // MARK: - 9. cancel() clears output

    @Test func testCancelClearsOutput() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "partial", finishReason: nil),
            StreamDelta(text: " more", finishReason: nil),
        ])
        await service.setDelay(.milliseconds(200))

        let vm = QuickViewModel(service: service)
        vm.input = "prompt"

        let submitTask = Task { await vm.submit() }
        try await Task.sleep(for: .milliseconds(50))
        vm.cancel()
        await submitTask.value

        #expect(vm.output == "")
    }

    // MARK: - 10. Service error surfaces in errorMessage

    @Test func testServiceErrorSetsErrorMessage() async throws {
        let service = MockQuickService()
        await service.setShouldThrow(true)

        let vm = QuickViewModel(service: service)
        vm.input = "This will fail"
        await vm.submit()

        // A provider error belongs to the turn it failed, not the bottom line.
        let question = try #require(vm.conversationMessages.last)
        #expect(vm.threadError?.messageID == question.id)
        #expect(vm.threadError?.message.isEmpty == false)
        #expect(vm.errorMessage == nil)
        #expect(vm.isStreaming == false)
    }

    // MARK: - 11. A cloud provider without an API key fails fast, offline

    @Test func testMissingAPIKeyFailsBeforeAnyRequest() async throws {
        let vm = QuickViewModel(service: nil as (any QuickService)?)
        vm.apiKeyProvider = { _ in nil }
        vm.input = "hello"
        await vm.submit()

        let msg = vm.errorMessage ?? ""
        #expect(msg.contains("needs an API key"))
        #expect(msg.contains("Settings"))
        #expect(vm.isStreaming == false)
        #expect(vm.input == "hello")
        #expect(vm.currentConversation == nil)
    }

    @Test func testUnusableEndpointRollsBackTheSubmission() async throws {
        let vm = QuickViewModel(service: nil as (any QuickService)?)
        vm.apiKeyProvider = { _ in "test-key" }
        let index = try #require(vm.settings.providers.firstIndex { $0.id == vm.settings.selectedProviderID })
        vm.settings.providers[index].baseURL = ""
        vm.input = "hello"
        await vm.submit()

        #expect(vm.errorMessage?.contains("not available") == true)
        #expect(vm.isStreaming == false)
        #expect(vm.input == "hello")
        #expect(vm.currentConversation?.messages.isEmpty == true)
    }

    // MARK: - 12. Empty input does not call service

    @Test func testEmptyInputDoesNotSubmit() async throws {
        let service = MockQuickService()
        let vm = QuickViewModel(service: service)
        vm.input = ""
        await vm.submit()
        let callCount = await service.sendCallCount
        #expect(callCount == 0)
    }

    @Test func screenshotRoutesToTheVisionProviderWithDefaultPrompt() async throws {
        let vision = MockQuickService()
        await vision.setResponses([
            StreamDelta(text: "A settings window", finishReason: "stop")
        ])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: vision)
        let attachment = QuickImageAttachment(
            data: Data([1, 2, 3]),
            mimeType: "image/png",
            pixelWidth: 10,
            pixelHeight: 20
        )
        vm.pendingImage = attachment

        await vm.submitResolvingFuzzyAlias()

        #expect(vm.output == "A settings window")
        #expect(await vision.lastImage == attachment)
        #expect(await vision.lastPrompt?.contains("Describe this screenshot") == true)
        #expect(vm.currentConversation?.providerID == InferenceProvider.deepSeekID)
        #expect(vm.pendingImage == nil)
    }

    // MARK: - 13. clearOutput() resets output and errorMessage

    @Test func testClearOutputResetsState() async throws {
        let vm = QuickViewModel(service: MockQuickService())
        vm.output = "some result"
        vm.errorMessage = "some error"
        vm.clearOutput()
        #expect(vm.output == "")
        #expect(vm.errorMessage == nil)
    }

    // MARK: - 14. copyOutput() writes to clipboard

    @Test func testCopyOutputWritesToClipboard() async throws {
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(service: MockQuickService(), pasteboard: pasteboard)
        vm.output = "content to copy"
        vm.copyOutput()
        #expect(pasteboard.string == "content to copy")
    }

    // MARK: - 15. copyOutput() with empty output is a no-op

    @Test func testCopyOutputEmptyStringIsNoOp() async throws {
        let pasteboard = FakePasteboard(string: "existing clipboard")

        let vm = QuickViewModel(service: MockQuickService(), pasteboard: pasteboard)
        vm.output = ""
        vm.copyOutput()

        #expect(pasteboard.string == "existing clipboard")
        #expect(pasteboard.writeCount == 0)
    }

    // MARK: - 16. Newer remote version sets .updateAvailable

    @Test func testHandleUpdateCheckNewerVersionSetsAvailable() async throws {
        let vm = QuickViewModel(service: MockQuickService(), currentVersion: "1.0.0")
        await vm.handleUpdateCheck(remoteVersion: "1.0.1")
        #expect(vm.updateState == .updateAvailable(newVersion: "1.0.1"))
    }

    // MARK: - 17. Same version sets .upToDate

    @Test func testHandleUpdateCheckSameVersionSetsUpToDate() async throws {
        let vm = QuickViewModel(service: MockQuickService(), currentVersion: "1.0.0")
        await vm.handleUpdateCheck(remoteVersion: "1.0.0")
        #expect(vm.updateState == .upToDate)
    }

    // MARK: - 18. Older remote version sets .upToDate

    @Test func testHandleUpdateCheckOlderVersionSetsUpToDate() async throws {
        let vm = QuickViewModel(service: MockQuickService(), currentVersion: "1.0.1")
        await vm.handleUpdateCheck(remoteVersion: "1.0.0")
        #expect(vm.updateState == .upToDate)
    }

    // MARK: - 19. Major version bump detected as update

    @Test func testHandleUpdateCheckMajorVersionComparison() async throws {
        let vm = QuickViewModel(service: MockQuickService(), currentVersion: "1.9.9")
        await vm.handleUpdateCheck(remoteVersion: "2.0.0")
        #expect(vm.updateState == .updateAvailable(newVersion: "2.0.0"))
    }

    // MARK: - 20. Minor version bump detected as update

    @Test func testHandleUpdateCheckMinorVersionComparison() async throws {
        let vm = QuickViewModel(service: MockQuickService(), currentVersion: "1.0.9")
        await vm.handleUpdateCheck(remoteVersion: "1.1.0")
        #expect(vm.updateState == .updateAvailable(newVersion: "1.1.0"))
    }

    // MARK: - 21. delta with finishReason ends stream, text-nil delta not appended

    @Test func testFinishReasonStopsStream() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "first", finishReason: nil),
            StreamDelta(text: nil, finishReason: "stop"),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "prompt"
        await vm.submit()
        #expect(vm.isStreaming == false)
        #expect(vm.output == "first")
    }

    // MARK: - 22. delta with nil text is ignored (output unchanged)

    @Test func testOutputWithNilTextDeltasIgnored() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "real text", finishReason: nil),
            StreamDelta(text: nil, finishReason: nil),
            StreamDelta(text: nil, finishReason: "stop"),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "prompt"
        await vm.submit()
        #expect(vm.output == "real text")
    }

    // MARK: - 23z. Auto-copy sets a "just copied" flag briefly

    @Test func testAutoCopySetsJustCopiedFlag() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "result", finishReason: "stop"),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = true
        vm.input = "hello"
        await vm.submit()
        #expect(vm.justCopied == true)
        #expect(vm.output == "result")
    }

    @Test func testAutoCopyDisabledDoesNotSetJustCopiedFlag() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "result", finishReason: "stop"),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "hello"
        await vm.submit()
        #expect(vm.justCopied == false)
    }

    @Test func testJustCopiedClearsAfterTimeout() async throws {
        let vm = QuickViewModel(service: nil)
        vm.justCopiedTimeout = .milliseconds(50)
        vm.markJustCopied()
        #expect(vm.justCopied == true)
        try await Task.sleep(for: .milliseconds(120))
        #expect(vm.justCopied == false)
    }

    // MARK: - 23a. The injected service is used without any key or network

    @Test func testSubmitUsesTheInjectedServiceWithoutTouchingTheKeychain() async throws {
        let vm = QuickViewModel(service: nil)
        vm.settings.autoCopy = false
        var keychainReads = 0
        vm.apiKeyProvider = { _ in keychainReads += 1; return nil }
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Paris", finishReason: "stop")])
        vm.service = service
        vm.input = "what is the capital of france"

        await vm.submit()
        #expect(vm.output == "Paris")
        #expect(vm.errorMessage == nil)
        #expect(keychainReads == 0)
    }

    @Test func testMissingKeyMessageNamesTheProvider() async throws {
        let vm = QuickViewModel(service: nil)
        vm.apiKeyProvider = { _ in "" }
        vm.settings.autoCopy = false
        vm.input = "hi"
        await vm.submit()
        let msg = vm.errorMessage ?? ""
        #expect(msg.hasPrefix("DeepSeek API needs an API key"))
    }

    // MARK: - 23. Math expressions are evaluated locally

    @Test func testMathExpressionIsEvaluatedLocally() async throws {
        // No service connected — must still work
        let vm = QuickViewModel(service: nil)
        vm.settings.autoCopy = false
        vm.input = "2+2"
        await vm.submit()
        #expect(vm.rootAnswer?.answer == "4")
        #expect(vm.output.isEmpty, "a local answer is not a Quick AI answer")
        #expect(!vm.isQuickAIPresented)
        #expect(vm.errorMessage == nil)
    }

    @Test func testMathExpressionDoesNotUseService() async throws {
        let service = MockQuickService()
        await service.setShouldThrow(true)  // any real AI call would throw
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "3*7"
        await vm.submit()
        #expect(vm.rootAnswer?.answer == "21")
        #expect(vm.output.isEmpty, "a local answer is not a Quick AI answer")
        #expect(!vm.isQuickAIPresented)
        #expect(vm.errorMessage == nil)
    }

    @Test func testMathExpressionAutoCopyEnabled() async throws {
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(service: nil, pasteboard: pasteboard)
        vm.settings.autoCopy = true
        vm.input = "10/2"
        await vm.submit()
        #expect(vm.rootAnswer?.answer == "5")
        #expect(vm.output.isEmpty, "a local answer is not a Quick AI answer")
        #expect(!vm.isQuickAIPresented)
        #expect(pasteboard.string == "5")
    }

    @Test func testMathExpressionAutoCopyDisabled() async throws {
        let pasteboard = FakePasteboard(string: "before")
        let vm = QuickViewModel(service: nil, pasteboard: pasteboard)
        vm.settings.autoCopy = false
        vm.input = "4+4"
        await vm.submit()
        #expect(vm.rootAnswer?.answer == "8")
        #expect(vm.output.isEmpty, "a local answer is not a Quick AI answer")
        #expect(!vm.isQuickAIPresented)
        // Clipboard must NOT have changed
        #expect(pasteboard.string == "before")
        #expect(pasteboard.writeCount == 0)
    }

    @Test func testMathExpressionDoesNotSetIsStreaming() async throws {
        let vm = QuickViewModel(service: nil)
        vm.settings.autoCopy = false
        vm.input = "100-1"
        await vm.submit()
        #expect(vm.isStreaming == false)
    }

    @Test func testMathExpressionEuropeanDecimal() async throws {
        let vm = QuickViewModel(service: nil)
        vm.settings.autoCopy = false
        vm.input = "54,34*6"
        await vm.submit()
        // 54.34 * 6 = 326.04
        #expect(vm.rootAnswer?.answer == "326.04")
        #expect(vm.output.isEmpty, "a local answer is not a Quick AI answer")
        #expect(!vm.isQuickAIPresented)
        #expect(vm.errorMessage == nil)
    }

    // MARK: - 24. Local system facts do not require an AI provider

    @Test func testCurrentDateAndTimeIsAnsweredLocally() async throws {
        let service = MockQuickService()
        await service.setShouldThrow(true)
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "what's the current date and time?"

        await vm.submit()

        #expect(vm.rootAnswer?.answer.contains(String(Calendar.current.component(.year, from: Date()))) == true)
        #expect(!vm.isQuickAIPresented)
        #expect(vm.errorMessage == nil)
        #expect(await service.sendCallCount == 0)
    }

    @Test func testMathDivisionByZeroSetsError() async throws {
        let vm = QuickViewModel(service: nil)
        vm.settings.autoCopy = false
        vm.input = "1/0"
        await vm.submit()
        #expect(vm.output == "")
        #expect(vm.errorMessage != nil)
    }

    @Test func testNaturalLanguageStillGoesToService() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "42", finishReason: "stop"),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.input = "what is 6 times 7"   // natural language → AI
        await vm.submit()
        #expect(vm.output == "42")
    }

    @Test func testFollowUpIncludesShortConversationContext() async throws {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "First answer", finishReason: "stop")])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.settings.historyEnabled = false
        vm.input = "First question"
        await vm.submit()

        await service.setResponses([StreamDelta(text: "Second answer", finishReason: "stop")])
        vm.input = "What about the other one?"
        await vm.submit()

        let messages = await service.lastMessages
        #expect(messages.map(\.role) == [.user, .assistant, .user])
        #expect(messages.map(\.content) == [
            "First question",
            "First answer",
            "What about the other one?",
        ])
    }

    @Test func testConversationCanBeShownWithoutBecomingAChatWorkspace() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "First answer", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: service)
        vm.input = "First question"
        await vm.submit()

        vm.toggleConversationHistory()

        #expect(vm.isConversationHistoryPresented)
        #expect(vm.conversationMessages.map(\.content) == ["First question", "First answer"])
        vm.clearTransientDisplay()
        #expect(!vm.isConversationHistoryPresented)
        #expect(vm.output.isEmpty)
        #expect(vm.currentConversation?.messages.count == 2)
    }

    @Test func testSelectingModelChangesProviderImmediately() {
        let vm = QuickViewModel(service: MockQuickService())

        vm.selectModel(
            providerID: InferenceProvider.deepSeekID,
            model: "deepseek-v4-pro"
        )

        #expect(vm.settings.selectedProviderID == InferenceProvider.deepSeekID)
        #expect(vm.settings.selectedModel == "deepseek-v4-pro")
        #expect(vm.activeModelID == "deepseek-v4-pro")
        #expect(vm.activeModelDisplay == "DeepSeek V4 Pro")
    }

    @Test func testSavedActionStartsFreshThread() async throws {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "answer", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        settings.savedPrompts = [
            SavedPrompt(
                alias: "clean",
                prompt: "Clean this up.",
                providerID: InferenceProvider.deepSeekID,
                model: "apple-foundationmodel"
            )
        ]
        let vm = QuickViewModel(settings: settings, service: service)
        vm.input = "First question"
        await vm.submit()

        vm.input = "/clean rough text"
        await vm.submit()

        let messages = await service.lastMessages
        #expect(messages.count == 1)
        #expect(messages.first?.content == "Clean this up.\n\nrough text")
    }

    // MARK: - Legacy: original test kept for compatibility

    @Test func testUpdateAvailableDetected() async throws {
        let vm = QuickViewModel(
            service: MockQuickService(),
            currentVersion: "1.0.0"
        )
        await vm.handleUpdateCheck(remoteVersion: "1.1.0")
        #expect(vm.updateState == .updateAvailable(newVersion: "1.1.0"))
    }
}

// MARK: - MockQuickService helpers (actor-isolated setters, called with await)

extension MockQuickService {
    func setResponses(_ value: [StreamDelta]) {
        responses = value
    }
    func setShouldThrow(_ value: Bool) {
        shouldThrow = value
    }
    func setDelay(_ value: Duration) {
        delay = value
    }
}
