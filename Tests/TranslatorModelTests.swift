import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Translator window", .serialized)
@MainActor
struct TranslatorModelTests {
    private func makeModel(reply: String = "你好") async -> (TranslatorModel, MockQuickService, PasteSpy) {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        let spy = PasteSpy()
        let model = TranslatorModel(lastTarget: .simplifiedChinese, serviceFactory: { mock }, selectedTextService: spy)
        model.debounce = .milliseconds(30)
        return (model, mock, spy)
    }

    /// Suites run in parallel; wait for the request instead of sleeping a fixed time.
    private func settle(_ model: TranslatorModel, timeout: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if !model.isTranslating, !model.translation.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func directionRuleAndRecognition() {
        #expect(LanguageDetection.target(for: "你好，世界", lastTarget: .simplifiedChinese) == .english)
        #expect(LanguageDetection.target(for: "hello world", lastTarget: .simplifiedChinese) == .simplifiedChinese)
        #expect(LanguageDetection.target(for: "hello world", lastTarget: .french) == .french)
        #expect(LanguageDetection.recognize("This is clearly an English sentence about the weather today.") == .english)
        #expect(Pinyin.romanize("你好") == "nǐ hǎo")
        #expect(Pinyin.romanize("hello") == nil)
        #expect(TranslationTarget.named("zh-Hant")?.title == "Chinese (Traditional)")
        #expect(TranslationTarget.all.first == .english)
    }

    @Test func typingRetranslatesAfterADebounceWithOneRequest() async {
        let (model, mock, _) = await makeModel()
        model.source = "h"
        model.sourceChanged()
        model.source = "he"
        model.sourceChanged()
        model.source = "hello"
        model.sourceChanged()
        #expect(model.target == .simplifiedChinese)
        await settle(model)
        #expect(await mock.sendCallCount == 1)
        #expect(model.translation == "你好")
        #expect(model.pinyin == "nǐ hǎo")
        #expect(!model.isTranslating)
        let sent = await mock.lastPrompt ?? ""
        #expect(sent.contains("to Chinese (Simplified)") && sent.hasSuffix("hello"))

        model.source = ""
        model.sourceChanged()
        #expect(model.translation.isEmpty && model.pinyin == nil)
    }

    @Test func openingWithASelectionTranslatesAtOnceAndPasteGoesBack() async {
        let (model, mock, spy) = await makeModel(reply: "Guten Tag")
        model.setTarget(.german)
        let target = SelectionTarget(processIdentifier: 7, applicationName: "Mail")
        model.prepare(target: target, selectedText: "Good day")
        await settle(model)
        #expect(await mock.sendCallCount == 1)
        #expect(model.translation == "Guten Tag")
        #expect(await model.pasteBack())
        #expect(spy.pasted == "Guten Tag" && spy.pastedTo == target)
    }

    @Test func copyWhileTranslatingWaitsForTheResult() async {
        let (model, mock, _) = await makeModel(reply: "Hola")
        await mock.setDelay(.milliseconds(80))
        model.setTarget(.spanish)
        model.source = "Hello"
        model.translateNow()
        #expect(model.isTranslating)
        model.copyTranslation()
        #expect(model.pendingCommit == .copy)
        #expect(model.message == "Copying when ready…")
        await settle(model)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.pendingCommit == nil)
        #expect(model.message == "Copied translation")
    }

    @Test func swapRoundTripsWithoutReguessingTheLanguage() async {
        let (model, _, _) = await makeModel()
        model.source = "hello"
        model.translation = "你好"
        model.detectedSource = .english
        model.target = .simplifiedChinese
        model.swap()
        #expect(model.source == "你好" && model.translation == "hello")
        #expect(model.target == .english)
        model.swap()
        #expect(model.source == "hello" && model.translation == "你好")
        #expect(model.target == .simplifiedChinese)

        let empty = TranslatorModel(lastTarget: .simplifiedChinese)
        empty.swap()
        #expect(empty.target == .english)
        #expect(empty.message == "Direction flipped")
    }

    @Test func committedTranslationsAreRecordedAndBounded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-translations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("translation-history.json")
        for index in 0..<3 {
            TranslationHistoryStore.append(TranslationRecord(source: "s\(index)", translation: "t\(index)", target: "en"), to: url, limit: 2)
        }
        let records = TranslationHistoryStore.load(from: url)
        #expect(records.map(\.source) == ["s2", "s1"])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func targetPickerFiltersAndTheSettingRemembersTheTarget() {
        var settings = QuickSettings()
        #expect(settings.translatorHotkey == ActionHotkey(keyCode: 17, modifiers: 1_048_576 | 131_072))
        #expect(settings.lastTranslationTarget == "zh-Hans")
        #expect(settings.translatorHotkeyConflict() == nil)
        settings.translatorHotkey = settings.clipboardHistoryHotkey
        #expect(settings.translatorHotkeyConflict()?.contains("Clipboard History") == true)

        let model = TranslatorModel(lastTarget: .english)
        var remembered: TranslationTarget?
        model.onTargetChange = { remembered = $0 }
        model.targetQuery = "jap"
        #expect(model.filteredTargets.map(\.code) == ["ja"])
        model.setTarget(model.filteredTargets[0])
        #expect(remembered == .japanese)
        #expect(!model.isTargetPickerPresented && model.targetQuery.isEmpty)
    }

    @Test func retainedLaunchSelectionIsImportedOnlyOnExplicitClick() async {
        let (model, mock, _) = await makeModel()
        let target = SelectionTarget(processIdentifier: 9, applicationName: "Notes")

        // Open with a launch snapshot retained but no fresh selection: the
        // source stays empty (nothing is invented) and the button is available.
        model.prepare(target: target, selectedText: nil, retainedSelection: "hello world")
        #expect(model.hasRetainedSelection)
        #expect(model.source.isEmpty)
        #expect(await mock.sendCallCount == 0)

        // The explicit button imports the retained snapshot.
        model.useRetainedSelection()
        #expect(model.source == "hello world")

        // A fresh actual selection on open still auto-captures as before,
        // and never erases manual typing without the explicit click.
        model.source = "manual"
        model.sourceChanged()
        model.prepare(target: target, selectedText: "fresh selection", retainedSelection: "hello world")
        #expect(model.source == "fresh selection")
    }

    @Test func retainLaunchSelectionImportsWhenWindowAlreadyOpen() async {
        let (model, _, _) = await makeModel()
        model.setTarget(.simplifiedChinese)
        model.source = "manual"
        model.sourceChanged()
        model.retainLaunchSelection("原文")
        #expect(model.source == "原文")
        #expect(model.hasRetainedSelection)
    }
}

@MainActor
private final class PasteSpy: SelectedTextServicing {
    private(set) var pasted: String?
    private(set) var pastedTo: SelectionTarget?
    var isAccessibilityTrusted: Bool { true }
    func currentExternalTarget() -> SelectionTarget? { nil }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? { nil }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        pasted = text
        pastedTo = target
        return true
    }
    func openAccessibilitySettings() {}
}
