import Foundation
import Testing
@testable import QuickLaunch

/// The Translator's ⌘K list: its actions, and Translation History, searched
/// across both languages and reopened without asking the model again.
@Suite("Translator: actions and history")
@MainActor
struct TranslatorHistoryTests {
    private static let records = [
        TranslationRecord(source: "早上好", translation: "Good morning", target: "en"),
        TranslationRecord(source: "The guide is ready", translation: "指南已经准备好了", target: "zh-Hans"),
        TranslationRecord(source: "Thank you", translation: "谢谢", target: "zh-Hans"),
    ]

    private func model() -> TranslatorModel {
        let model = TranslatorModel(lastTarget: .simplifiedChinese)
        model.historyLoader = { Self.records }
        return model
    }

    @Test func commandKOpensAndClosesTheActionList() {
        let model = model()
        model.toggleActionList()
        #expect(model.list == .actions)
        #expect(model.actionOptions.first?.title == "Translation History")
        model.toggleActionList()
        #expect(model.list == nil)
    }

    @Test func historyReadsTheFileAndSearchesBothLanguages() {
        let model = model()
        model.toggleActionList()
        model.chooseAction(TranslatorAction.all[0])
        #expect(model.list == .history)
        #expect(model.historyOptions.count == 3)
        model.listQuery = "guide"
        #expect(model.historyOptions.map(\.translation) == ["指南已经准备好了"])
        model.listQuery = "谢谢"
        #expect(model.historyOptions.map(\.source) == ["Thank you"])
    }

    @Test func historyShowsTheNewestFifty() {
        let model = TranslatorModel(lastTarget: .english)
        model.historyLoader = { (1...80).map { TranslationRecord(source: "s\($0)", translation: "t\($0)", target: "en") } }
        model.openHistory()
        #expect(model.historyOptions.count == TranslatorModel.historyShown)
        #expect(model.historyOptions.first?.source == "s1")
    }

    @Test func reopeningPutsTheOldTranslationBackWithoutAModelCall() async {
        let model = model()
        let mock = MockQuickService()
        model.serviceFactory = { mock }
        model.openHistory()
        model.reopen(Self.records[0])
        await model.settled()
        #expect(model.list == nil)
        #expect(model.source == "早上好")
        #expect(model.translation == "Good morning")
        #expect(model.target == .english, "the record's own target")
        #expect(await mock.sendCallCount == 0)
    }

    @Test func anActionRowRunsItsKey() {
        let model = model()
        var ran: [TranslatorKey] = []
        model.performKey = { ran.append($0) }
        model.toggleActionList()
        let swap = try! #require(model.actionOptions.first { $0.title == "Swap Languages" })
        model.chooseAction(swap)
        #expect(ran == [.swap])
        #expect(model.list == nil)
    }

    @Test func commandKIsInTheKeyTable() {
        #expect(TranslatorKey.matching(characters: "k", keyCode: 40, modifiers: [.command]) == .actions)
        #expect(model().footerHints.contains { $0.label == "Actions" })
    }
}

@Suite("Settings: Features")
struct FeatureDefaultsTests {
    @Test func typeToClickIsOffUntilChosen() throws {
        #expect(!QuickSettings().typeToClickHotkeyEnabled)
        var on = QuickSettings()
        on.typeToClickHotkeyEnabled = true
        let back = try JSONDecoder().decode(QuickSettings.self, from: JSONEncoder().encode(on))
        #expect(back.typeToClickHotkeyEnabled, "a choice to turn it on is kept")
    }

    @Test func theFeaturesCardCanBeFoundBySearch() {
        #expect(SettingsDestinationIndex.destination(id: "general.features") != nil)
    }
}
