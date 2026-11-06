import Testing
@testable import QuickLaunch

/// Raycast's AI Commands: saved actions are root search rows that read the
/// selection when they run. The selection is never shown on open.
@Suite("Selection actions in root search", .serialized)
@MainActor
struct SelectionActionSearchTests {
    private let target = SelectionTarget(processIdentifier: 42, applicationName: "Editor")

    private func make(selected: String?) async -> (QuickViewModel, MockQuickService) {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Short summary", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: FakeSelectedTextService(text: selected)
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        return (vm, service)
    }

    private func rowID(_ vm: QuickViewModel, alias: String) -> String {
        let action = vm.settings.savedPrompts.first { $0.alias == alias }!
        return "command:" + QuickViewModel.savedActionValuePrefix + action.id.uuidString
    }

    @Test func anEmptyQueryWithASelectionLeadsWithTheQuickRewrites() async {
        let (vm, _) = await make(selected: "Long selected passage")
        let ids = vm.launcherMatches.map(\.id)
        #expect(ids.first == rowID(vm, alias: "shorter"))
        #expect(ids.prefix(4).contains(rowID(vm, alias: "tldr")))
    }

    @Test func withoutASelectionTheEmptyQueryIsUnchanged() async {
        let (vm, _) = await make(selected: nil)
        let ids = vm.launcherMatches.map(\.id)
        #expect(!ids.contains(rowID(vm, alias: "shorter")))
    }

    @Test func aTypedActionNameFindsTheActionAndSaysWhatItActsOn() async {
        let (vm, _) = await make(selected: "Long selected passage")
        vm.input = "tldr"
        let first = vm.launcherMatches.first
        #expect(first?.id == rowID(vm, alias: "tldr"))
        guard case .item(let item) = first else { Issue.record("no row"); return }
        #expect(item.detail == "On 21 selected characters from Editor")
    }

    @Test func returnRunsTheActionOnTheSelectionNotOnTheSearchText() async {
        let (vm, service) = await make(selected: "Long selected passage")
        vm.input = "tldr"
        guard case .item(let item) = vm.launcherMatches.first else { Issue.record("no row"); return }
        await vm.performLauncherItem(item)
        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("Long selected passage") == true)
        #expect(messages.last?.content.contains("tldr") == false)
        #expect(vm.output == "Short summary")
    }
}
