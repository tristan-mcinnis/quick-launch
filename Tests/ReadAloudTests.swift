import Foundation
import Testing
@testable import QuickLaunch

/// Minimal selection stand-in for these tests; `QuickActionWorkflowTests`
/// keeps its own private `FakeSelectedTextService` for a wider surface.
private final class ReadAloudFakeSelection: SelectedTextServicing {
    var isAccessibilityTrusted = true
    var selectedText: String?

    init(text: String?) { selectedText = text }

    func currentExternalTarget() -> SelectionTarget? { nil }

    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        guard let selectedText, !selectedText.isEmpty else { return nil }
        return SelectedTextContext(target: target, text: selectedText)
    }

    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { false }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { false }
    func openAccessibilitySettings() {}
}

@Suite("Read Aloud", .serialized)
@MainActor
struct ReadAloudTests {
    private let target = SelectionTarget(processIdentifier: 99, applicationName: "Notes")

    private func make(
        selection: String? = nil,
        clipboard: String? = nil,
        speech: FakeLocalSpeechService = FakeLocalSpeechService()
    ) -> (QuickViewModel, RecordingPresenter) {
        let vm = QuickViewModel(
            selectedTextService: ReadAloudFakeSelection(text: selection),
            localSpeechService: speech,
            pasteboard: FakePasteboard(string: clipboard)
        )
        let presenter = RecordingPresenter()
        vm.overlayPresenter = presenter
        if selection != nil {
            vm.rememberSelectionTarget(target)
        }
        return (vm, presenter)
    }

    // MARK: - Row detail priority

    @Test func detailPrefersTheSelectionOverEverythingElse() {
        let (vm, _) = make(selection: "Highlighted passage", clipboard: "Clipboard text")
        vm.output = "Last answer"
        #expect(vm.speechReadAloudRow.detail == "the selected text")
    }

    @Test func detailFallsBackToTheClipboardWithNoSelection() {
        let (vm, _) = make(clipboard: "Clipboard text")
        vm.output = "Last answer"
        #expect(vm.speechReadAloudRow.detail == "the clipboard")
    }

    @Test func detailFallsBackToTheLastAnswerWithNoSelectionOrClipboard() {
        let (vm, _) = make()
        vm.output = "Last answer"
        #expect(vm.speechReadAloudRow.detail == "the last answer")
    }

    @Test func detailNudgesToSelectSomethingWhenNothingIsAvailable() {
        let (vm, _) = make()
        #expect(vm.speechReadAloudRow.detail == "Select some text first")
    }

    @Test func rowCarriesTheExpectedIdentityAndKeywords() {
        let (vm, _) = make()
        let row = vm.speechReadAloudRow
        #expect(row.itemID == "speech.readAloud")
        #expect(row.title == "Read Aloud")
        #expect(row.value == "speech.readAloud")
        #expect(row.keywords.contains("tts"))
        #expect(row.systemImage == "speaker.wave.2")
    }

    @Test func rowIsInTheCommandsCatalogAndMatchesTheTtsKeyword() {
        let (vm, _) = make()
        #expect(vm.systemCommands.map(\.itemID).contains("speech.readAloud"))
        vm.input = "tts"
        #expect(vm.launcherMatches.first?.id == "command:speech.readAloud")
    }

    // MARK: - Return: health, then speak

    @Test func returnSpeaksTheSelectionWhenHealthy() async {
        let speech = FakeLocalSpeechService(healthy: true)
        let (vm, presenter) = make(selection: "Read this aloud", speech: speech)
        await vm.performReadAloud()
        // The speak() Task is fired-and-not-awaited by design; poll for it
        // rather than a fixed sleep, so this stays reliable under load.
        await Self.waitUntil { await !speech.spoken.isEmpty }
        #expect(await speech.spoken == ["Read this aloud"])
        #expect(presenter.dismissals == 1)
        #expect(vm.errorMessage == nil)
    }

    @Test func returnReportsWhenLocalTTSIsDown() async {
        let speech = FakeLocalSpeechService(healthy: false)
        let (vm, presenter) = make(selection: "Read this aloud", speech: speech)
        await vm.performReadAloud()
        #expect(vm.errorMessage == "Local TTS is not running")
        #expect(await speech.spoken.isEmpty)
        #expect(presenter.dismissals == 0, "the panel stays open to show the error")
    }

    @Test func returnWithNothingToReadShowsTheNudgeAsAnError() async {
        let speech = FakeLocalSpeechService(healthy: true)
        let (vm, presenter) = make(speech: speech)
        await vm.performReadAloud()
        #expect(vm.errorMessage == "Select some text first.")
        #expect(presenter.dismissals == 0)
    }

    @Test func explicitTextBypassesSelectionAndDoesNotDismissTheOverlay() async {
        let speech = FakeLocalSpeechService(healthy: true)
        let (vm, presenter) = make(selection: "Selection wins normally", speech: speech)
        await vm.performReadAloud(text: "The answer on screen")
        await Self.waitUntil { await !speech.spoken.isEmpty }
        #expect(await speech.spoken == ["The answer on screen"])
        #expect(presenter.dismissals == 0, "the ⌘K answer action leaves the answer on screen")
    }

    @Test func stopReadingCallsStopOnTheService() async {
        let speech = FakeLocalSpeechService(healthy: true)
        let (vm, _) = make(speech: speech)
        await vm.stopReadAloud()
        #expect(await speech.stopCount == 1)
    }

    // MARK: - The Stop Reading row

    @Test func stopReadingRowOnlyAppearsWhileSpeaking() {
        let (vm, _) = make()
        #expect(vm.speechStopRow == nil)
        #expect(!vm.systemCommands.map(\.itemID).contains("speech.stop"))
        vm.isSpeaking = true
        #expect(vm.speechStopRow?.itemID == "speech.stop")
        #expect(vm.speechStopRow?.statusLight == .on)
        #expect(vm.systemCommands.map(\.itemID).contains("speech.stop"))
    }

    // MARK: - The ⌘K answer action

    @Test func readAloudAppearsAmongResultActionsWithAnAnswerOnScreen() {
        let (vm, _) = make()
        vm.output = "Here is the answer"
        #expect(vm.resultActions.contains(.readAloud))
    }

    @Test func readAloudIsAbsentWithNoAnswerOnScreen() {
        let (vm, _) = make()
        #expect(vm.resultActions.isEmpty)
    }

    @Test func performResultActionReadAloudSpeaksTheOutputAndClosesThePalette() async {
        let speech = FakeLocalSpeechService(healthy: true)
        let (vm, _) = make(speech: speech)
        vm.output = "The streamed answer"
        vm.isActionPalettePresented = true
        await vm.performResultAction(.readAloud)
        await Self.waitUntil { await !speech.spoken.isEmpty }
        #expect(await speech.spoken == ["The streamed answer"])
        #expect(!vm.isActionPalettePresented)
    }

    // MARK: - Request body

    @Test func speechRequestBodyMatchesTheLocalTTSContract() throws {
        let request = try LocalSpeechService.speechRequest(for: "Hello there", voice: "vctk-p225.wav")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://127.0.0.1:8081/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(LocalSpeechRequestBody.self, from: body)
        #expect(decoded == LocalSpeechRequestBody(input: "Hello there", voice: "vctk-p225.wav", responseFormat: "wav"))
        let raw = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(raw["response_format"] == "wav", "the wire key is snake_case, matching local-tts")
    }

    @Test func speechRequestDefaultsToTheHouseVoice() throws {
        let request = try LocalSpeechService.speechRequest(for: "Hi")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(LocalSpeechRequestBody.self, from: body)
        #expect(decoded.voice == "vctk-p225.wav")
    }

    /// Polls `condition` instead of a fixed sleep, so a check on the
    /// fire-and-forget speak `Task` stays reliable under load.
    private static func waitUntil(
        timeout: Duration = .seconds(15),
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if await condition() { return }
        Issue.record("the read-aloud wait timed out after \(timeout)")
    }
}
