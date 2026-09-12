import AppKit
import Testing
import Foundation
@testable import QuickLaunch

/// End-to-end: QuickViewModel.submit must expand a saved-prompt input
/// before handing it to the service, and never send the raw `/alias`
/// form to the model.

@Suite("Saved prompts + QuickViewModel")
@MainActor
struct SavedPromptIntegrationTests {

    private func makeViewModel(_ settings: QuickSettings = QuickSettings()) -> (QuickViewModel, CapturingService) {
        let service = CapturingService()
        let vm = QuickViewModel(settings: settings, service: service)
        return (vm, service)
    }

    @Test func testBareAliasExpandsSelectedTextBeforeSend() async {
        // A bare alias whose prompt uses {selection} reads the selected text
        // from the app behind the overlay and sends the expanded prompt.
        let (vm, service) = makeViewModel()
        let target = SelectionTarget(processIdentifier: 4242, applicationName: "Notes")
        vm.selectedTextService = StubSelectedTextService(text: "Bonjour le monde", target: target)
        vm.rememberSelectionTarget(target)
        vm.input = "/translate"
        await vm.submit()
        #expect(vm.errorMessage == nil)
        let sent = await service.waitForPrompt()
        #expect(sent?.hasPrefix("Translate") == true)
        #expect(sent?.contains("Bonjour le monde") == true)
        #expect(sent?.contains("/translate") == false)
        #expect(sent?.contains("{selection}") == false)
    }

    @Test func testBareAliasWithoutSelectionExplainsInsteadOfSending() async {
        let (vm, service) = makeViewModel()
        vm.input = "/translate"
        await vm.submit()
        #expect(vm.errorMessage == "This action needs selected text.")
        let sent = await service.waitForPrompt(timeoutMs: 50, expectingNone: true)
        #expect(sent == nil)
    }

    @Test func testAliasWithContextAppends() async {
        let (vm, service) = makeViewModel()
        vm.input = "/translate hello world"
        await vm.submit()
        let sent = await service.waitForPrompt()
        #expect(sent?.contains("Translate") == true)
        #expect(sent?.contains("hello world") == true)
    }

    @Test func testUnknownAliasIsSentAsRawText() async {
        let (vm, service) = makeViewModel()
        vm.input = "/unknown"
        await vm.submit()
        let sent = await service.waitForPrompt()
        #expect(sent == "/unknown")
    }

    @Test func testNonAliasInputIsSentVerbatim() async {
        let (vm, service) = makeViewModel()
        vm.input = "hello there"
        await vm.submit()
        let sent = await service.waitForPrompt()
        #expect(sent == "hello there")
    }

    @Test func testCustomPrefixFromSettings() async {
        var s = QuickSettings()
        s.savedPromptPrefix = ";"
        let (vm, service) = makeViewModel(s)
        vm.input = ";translate hi"
        await vm.submit()
        let sent = await service.waitForPrompt()
        #expect(sent?.contains("Translate") == true)
        #expect(sent?.contains("hi") == true)
    }

    @Test func testPromptMatchesExposedForAutocomplete() {
        let (vm, _) = makeViewModel()
        vm.input = "/t"
        let aliases = vm.savedPromptMatches.map(\.alias)
        #expect(aliases.contains("translate"))
        #expect(aliases.contains("tldr"))
    }

    @Test func testPromptMatchesEmptyWhenNoPrefix() {
        let (vm, _) = makeViewModel()
        vm.input = "hello"
        #expect(vm.savedPromptMatches.isEmpty)
    }

    @Test func testCompleteSelectedAliasReplacesInput() {
        let (vm, _) = makeViewModel()
        vm.input = "/t"
        let translate = vm.settings.savedPrompts.first(where: { $0.alias == "translate" })!
        vm.complete(savedPrompt: translate)
        #expect(vm.input == "/translate ")
    }
}

// Captures the prompt passed into send() so the test can assert what was sent.
actor CapturingService: QuickService {
    private var _lastPrompt: String?

    nonisolated func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        let prompt = messages.last(where: { $0.role == .user })?.content ?? ""
        return AsyncThrowingStream { continuation in
            Task { await self.record(prompt) }
            continuation.yield(StreamDelta(text: "ok", finishReason: nil))
            continuation.finish()
        }
    }

    /// Polls so tests don't race against the detached Task in send(). The
    /// budget is generous because the wait crosses a task boundary on a
    /// machine that may be running other suites; a test expecting no prompt
    /// passes `expectingNone` and keeps its short budget.
    func waitForPrompt(timeoutMs: Int = 15_000, expectingNone: Bool = false) async -> String? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if let p = _lastPrompt { return p }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if _lastPrompt == nil, !expectingNone {
            Issue.record("no prompt reached the service within \(timeoutMs) ms")
        }
        return _lastPrompt
    }

    private func record(_ prompt: String) {
        _lastPrompt = prompt
    }

    nonisolated func healthCheck() async throws -> Bool { true }
}

/// Hands back fixed selected text without touching Accessibility.
@MainActor
private final class StubSelectedTextService: SelectedTextServicing {
    let text: String
    let target: SelectionTarget
    var isAccessibilityTrusted: Bool { true }

    init(text: String, target: SelectionTarget) {
        self.text = text
        self.target = target
    }

    func currentExternalTarget() -> SelectionTarget? { target }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        SelectedTextContext(target: target, text: text)
    }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { true }
    func openAccessibilitySettings() {}
}
