// TranslatorParityTests: the Raycast Translator behaviours Quick Launch took
// on (docs/raycast-translator-teardown-20261017.md). "<text> in <language>"
// in root search shows a live translation row, and the Translator window
// lets the user choose the source language (or Auto detect) beside the
// target, with Swap between them.

import Foundation
import Testing
@testable import QuickLaunch

@Suite("Translator parity", .serialized)
@MainActor
struct TranslatorParityTests {

    // MARK: - Parsing "<text> in <language>"

    @Test func theLastInSplitsTextFromALanguageNameOrPrefix() throws {
        let exact = try #require(InlineTranslationQuery.parse("good morning in Japanese"))
        #expect(exact.phrase == "good morning" && exact.target == .japanese && exact.namesLanguageExactly)

        let prefix = try #require(InlineTranslationQuery.parse("good morning in jap"))
        #expect(prefix.target == .japanese && !prefix.namesLanguageExactly)

        #expect(InlineTranslationQuery.parse("hello into french")?.target == .french)
        #expect(InlineTranslationQuery.parse("what is in the box in german")?.phrase == "what is in the box")
        #expect(InlineTranslationQuery.parse("“thank you” in chinese")?.phrase == "thank you")
        #expect(InlineTranslationQuery.parse("thank you in chinese")?.target == .simplifiedChinese)
        #expect(InlineTranslationQuery.parse("HELLO IN GERMAN")?.target == .german)
    }

    @Test func shortWordsUnknownLanguagesAndBarePrefixesAreNotTranslations() {
        #expect(InlineTranslationQuery.parse("5 km in mi") == nil, "two letters are too few")
        #expect(InlineTranslationQuery.parse("weather in paris") == nil)
        #expect(InlineTranslationQuery.parse("in japanese") == nil, "no phrase")
        #expect(InlineTranslationQuery.parse("japanese") == nil)
        #expect(InlineTranslationQuery.parse("") == nil)
    }

    // MARK: - The launcher row

    private func makeLauncher(reply: String) async -> (QuickViewModel, MockQuickService, FakePasteboard, TranslatorPresenter) {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(settings: settings, service: mock, pasteboard: pasteboard)
        let presenter = TranslatorPresenter()
        vm.overlayPresenter = presenter
        return (vm, mock, pasteboard, presenter)
    }

    private func type(_ text: String, into vm: QuickViewModel) {
        vm.input = text
        vm.rootInputDidChange(text)
    }

    private func translationRow(_ vm: QuickViewModel) -> LauncherCatalogItem? {
        for result in vm.launcherMatches {
            if case .item(let item) = result, item.isInlineTranslation { return item }
        }
        return nil
    }

    @Test func aLanguageNameShowsALiveTranslationOnTopAndReturnCopiesIt() async throws {
        let (vm, mock, pasteboard, presenter) = await makeLauncher(reply: "おはようございます")
        type("good morning in japanese", into: vm)

        let pending = try #require(translationRow(vm))
        #expect(pending.title == "Translating…")
        #expect(pending.detail == "Japanese · good morning")
        #expect(pending.defaultActionTitle == "Open in Translator")
        #expect(vm.launcherMatches.first?.id == LauncherSearchResult.item(pending).id)

        await vm.inlineTranslationSettled()
        #expect(await mock.sendCallCount == 1)
        let prompt = await mock.lastPrompt ?? ""
        #expect(prompt.contains("to Japanese") && prompt.hasSuffix("good morning"))

        let ready = try #require(translationRow(vm))
        #expect(ready.title == "おはようございます" && ready.value == "おはようございます")
        #expect(ready.defaultActionTitle == "Copy")
        await vm.performLauncherItem(ready)
        #expect(pasteboard.string == "おはようございます")
        #expect(presenter.dismissals == 1)
        #expect(vm.inlineTranslation == nil)
    }

    @Test func aLanguagePrefixSitsJustUnderAskAI() async throws {
        let (vm, _, _, _) = await makeLauncher(reply: "駅はどこですか")
        type("where is the station in jap", into: vm)
        let row = try #require(translationRow(vm))
        let ids = vm.launcherMatches.map(\.id)
        let askIndex = try #require(ids.firstIndex { $0.hasPrefix("askAI") })
        let rowIndex = try #require(ids.firstIndex(of: LauncherSearchResult.item(row).id))
        #expect(askIndex < rowIndex)
        await vm.inlineTranslationSettled()
    }

    @Test func aLocalConversionWinsAndTypingAwayStopsTheRequest() async {
        let (vm, mock, _, _) = await makeLauncher(reply: "unused")
        type("5 km in miles", into: vm)
        #expect(vm.inlineTranslation == nil)

        type("hello in french", into: vm)
        #expect(vm.inlineTranslation != nil)
        type("hello", into: vm)
        #expect(vm.inlineTranslation == nil)
        #expect(translationRow(vm) == nil)
        try? await Task.sleep(for: QuickViewModel.inlineTranslationDebounce * 2)
        #expect(await mock.sendCallCount == 0, "a dropped query never reaches the model")
    }

    @Test func returnBeforeTheResultOpensTheTranslatorOnThePhraseAndLanguage() async throws {
        let (vm, _, _, presenter) = await makeLauncher(reply: "Bonjour")
        type("hello in french", into: vm)
        let pending = try #require(translationRow(vm))
        await vm.performLauncherItem(pending)
        #expect(presenter.opened?.text == "hello" && presenter.opened?.target == .french)
        #expect(vm.input.isEmpty && vm.inlineTranslation == nil)
    }

    @Test func pasteKeysOnAnUnfinishedRowNeverClearTheClipboard() async throws {
        let (vm, _, pasteboard, presenter) = await makeLauncher(reply: "Bonjour")
        pasteboard.string = "kept"
        type("hello in french", into: vm)
        let pending = try #require(translationRow(vm))
        #expect(ItemActionCatalog.actions(for: .item(pending), pasteTarget: nil).map(\.title) == ["Open in Translator"])
        #expect(await vm.copyAndPasteLauncherItem(pending))
        #expect(pasteboard.string == "kept")
        #expect(presenter.opened?.target == .french)
    }

    @Test func noRequestGoesOutWhenTheRowCannotShow() async {
        let (vm, mock, _, _) = await makeLauncher(reply: "unused")
        let long = String(repeating: "word ", count: 14) + "in french"
        #expect(long.count > 64)
        type(long, into: vm)
        #expect(vm.inlineTranslation == nil)
        type(vm.settings.savedPromptPrefix + "zh hello in french", into: vm)
        #expect(vm.inlineTranslation == nil)
        try? await Task.sleep(for: QuickViewModel.inlineTranslationDebounce * 2)
        #expect(await mock.sendCallCount == 0)
    }

    @Test func shiftReturnActsOnTheRowInItsLanguage() async throws {
        let (vm, _, pasteboard, _) = await makeLauncher(reply: "こんにちは")
        type("hello in japanese", into: vm)
        await vm.inlineTranslationSettled()
        await vm.translateInput()
        #expect(pasteboard.string == "こんにちは")
    }

    // MARK: - Choosing the source language

    private func makeWindow(reply: String = "hello") async -> (TranslatorModel, MockQuickService) {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        let model = TranslatorModel(lastTarget: .english, serviceFactory: { mock })
        model.debounce = .milliseconds(30)
        return (model, mock)
    }

    @Test func theSourceListOffersAutoDetectAndTheTargetListDoesNot() {
        let model = TranslatorModel(lastTarget: .english)
        model.toggleLanguagePicker(.source)
        #expect(model.pickerOptions.first == .auto)
        #expect(model.pickerSelection == .auto)
        model.pickerQuery = "jap"
        #expect(model.pickerOptions == [.fixed(.japanese)])

        model.toggleLanguagePicker(.target)
        #expect(model.languagePicker == .target && model.pickerQuery.isEmpty)
        #expect(!model.pickerOptions.contains(.auto))
        #expect(model.pickerSelection == .fixed(.english))
        model.toggleLanguagePicker(.target)
        #expect(model.languagePicker == nil)
    }

    @Test func aChosenSourceIsNamedInThePromptAndReplacesDetection() async {
        let (model, mock) = await makeWindow()
        model.toggleLanguagePicker(.source)
        model.choosePickerOption(.fixed(.japanese))
        #expect(model.sourceSelection == .fixed(.japanese) && model.languagePicker == nil)
        model.source = "Hello there, this is English text"
        model.translateNow()
        await model.settled()
        let prompt = await mock.lastPrompt ?? ""
        #expect(prompt.contains("from Japanese to English"))
        #expect(model.detectedSource == .japanese, "the choice wins over the recogniser")

        model.setSourceSelection(.auto)
        model.translateNow()
        await model.settled()
        #expect(await mock.lastPrompt?.contains("from ") == false)
        #expect(model.detectedSource == .english)
    }

    @Test func choosingTheTargetAsSourceOrTheSourceAsTargetFlipsThePair() {
        let model = TranslatorModel(lastTarget: .english, lastSource: .simplifiedChinese)
        model.setSourceSelection(.fixed(.english))
        #expect(model.sourceSelection == .fixed(.english))
        #expect(model.target == .simplifiedChinese)

        model.setTarget(.english)
        #expect(model.target == .english)
        #expect(model.sourceSelection == .fixed(.simplifiedChinese))
    }

    @Test func swapWithAChosenSourceSwapsBothChipsAndTheText() async {
        let (model, mock) = await makeWindow(reply: "你好")
        model.setTarget(.simplifiedChinese)
        model.setSourceSelection(.fixed(.english))
        model.source = "hello"
        model.translateNow()
        await model.settled()
        #expect(model.translation == "你好")
        model.swap()
        #expect(model.sourceSelection == .fixed(.simplifiedChinese))
        #expect(model.target == .english)
        #expect(model.source == "你好" && model.translation == "hello")
        #expect(await mock.sendCallCount == 1, "a finished translation swaps without asking again")
    }

    @Test func changingTheSourceDropsTheOldDetectionAndAHandoffTargetIsNotSaved() {
        let model = TranslatorModel(lastTarget: .english)
        model.setSourceSelection(.fixed(.french))
        model.detectedSource = .french
        model.setSourceSelection(.fixed(.german))
        #expect(model.detectedSource == .german)
        model.swap()
        #expect(model.target == .german, "Swap goes back to the chosen source, not a stale one")
        model.setSourceSelection(.auto)
        #expect(model.detectedSource == nil)

        var saves = 0
        model.onLanguagesChange = { saves += 1 }
        model.setTarget(.japanese, remember: false)
        #expect(model.target == .japanese && saves == 0)
    }

    @Test func theSourceChoiceIsRememberedAcrossLaunches() throws {
        let model = TranslatorModel(lastTarget: .english)
        var saves = 0
        model.onLanguagesChange = { saves += 1 }
        model.setSourceSelection(.fixed(.french))
        #expect(saves == 1)

        var settings = QuickSettings()
        #expect(settings.translationSourceSelection == "auto")
        settings.translationSourceSelection = model.sourceSelection.code
        let restored = try JSONDecoder().decode(QuickSettings.self, from: JSONEncoder().encode(settings))
        #expect(SourceSelection(code: restored.translationSourceSelection) == .fixed(.french))
        #expect(SourceSelection(code: "auto") == .auto && SourceSelection(code: "xx") == .auto)

        let reopened = TranslatorModel(lastTarget: .english, sourceSelection: .fixed(.french))
        #expect(reopened.sourceSelection == .fixed(.french) && reopened.sourceLanguage == .french)
        let clashing = TranslatorModel(lastTarget: .english, sourceSelection: .fixed(.english))
        #expect(clashing.sourceSelection == .auto, "a saved source equal to the target falls back to Auto")
    }
}

@MainActor
private final class TranslatorPresenter: OverlayPresenting {
    var dismissals = 0
    var opened: (text: String, target: TranslationTarget)?
    func presentOverlay() {}
    func dismissOverlay() { dismissals += 1 }
    func openSettings() {}
    func openTranslator() {}
    func openTranslator(text: String, target: TranslationTarget) { opened = (text, target) }
    func openTypeToClick() {}
}
