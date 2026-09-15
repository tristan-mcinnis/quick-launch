import Foundation
import Testing
@testable import QuickLaunch

@Suite("Palette search", .serialized)
@MainActor
struct PaletteSearchTests {
    private func answeredChat() -> QuickViewModel {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        settings.newChatInterval = .never
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
        let conversation = QuickConversation(
            providerID: vm.settings.providers[0].id,
            model: "test-model",
            messages: [
                QuickMessage(role: .user, content: "A question"),
                QuickMessage(role: .assistant, content: "An answer"),
            ]
        )
        vm.history = [conversation]
        vm.loadConversation(id: conversation.id)
        vm.openQuickAI()
        return vm
    }

    @Test func openChatPaletteFindsUnpinAfterPinning() async throws {
        let vm = answeredChat()
        vm.actionQuery = "PIN"
        #expect(vm.paletteResultActions.contains(.pinChat))
        vm.actionQuery = "unpin"
        #expect(!vm.paletteResultActions.contains(.pinChat))
        await vm.performResultAction(.pinChat)
        #expect(try #require(vm.currentConversation).isPinned)
        #expect(vm.resultActionTitle(.pinChat) == "Unpin Chat")
        #expect(vm.resultActionSystemImage(.pinChat) == "pin.slash")
        for query in ["unpin", "UNPIN", "unpn"] {
            vm.actionQuery = query
            #expect(vm.paletteResultActions.first == .pinChat)
        }
        await vm.performResultAction(.pinChat)
        #expect(vm.resultActionTitle(.pinChat) == "Pin Chat")
        #expect(!vm.paletteResultActions.contains(.pinChat))
    }

    @Test func railSearchFiltersActionsAndReturnRunsTheDisplayedAction() throws {
        let vm = answeredChat()
        let defaults = UserDefaults(suiteName: "PaletteSearchTests.\(UUID().uuidString)")!
        let window = AIChatWindowModel(chat: vm, defaults: defaults)
        window.showRail()
        let chatID = try #require(window.highlightedRailItem?.itemID)
        window.toggleRailActions()
        window.railActionQuery = "rnme"
        #expect(window.filteredRailActions == [.rename])
        #expect(window.railQuery.isEmpty, "action search never filters the chat list")
        #expect(window.highlightedRailItem?.itemID == chatID)
        window.moveRailSelection(1)
        #expect(window.railActionIndex == 0)
        window.activateRailSelection()
        #expect(window.renamingChatID?.uuidString == chatID)
    }

    @Test func railSearchUsesCurrentPinStateAndResetsWhenReopened() {
        let vm = answeredChat()
        let defaults = UserDefaults(suiteName: "PaletteSearchTests.\(UUID().uuidString)")!
        let window = AIChatWindowModel(chat: vm, defaults: defaults)
        window.showRail()
        window.toggleRailActions()
        window.railActionQuery = "UNPIN"
        #expect(window.filteredRailActions.isEmpty)
        window.activateRailSelection()
        #expect(window.highlightedRailItem?.isPinned == false)
        window.railActionQuery = "pin"
        #expect(window.filteredRailActions == [.pin])
        window.activateRailSelection()
        #expect(window.highlightedRailItem?.isPinned == true)
        window.toggleRailActions()
        #expect(window.railActionQuery.isEmpty)
        window.railActionQuery = "UNPN"
        #expect(window.filteredRailActions == [.pin])
        #expect(window.title(of: .pin) == "Unpin Chat")
        window.activateRailSelection()
        #expect(window.highlightedRailItem?.isPinned == false)
    }

    @Test func paletteFuzzySearchHandlesNoncontiguousLettersAndKeepsBestMatchFirst() {
        let vm = answeredChat()
        vm.actionQuery = "rgmdl"
        #expect(vm.paletteResultActions.first == .regenerateWithModel)
        vm.actionQuery = "cchat"
        #expect(vm.paletteResultActions.first == .copyChat)
        vm.actionQuery = "impossibleaction"
        #expect(vm.paletteResultActions.isEmpty)
        #expect(vm.paletteSurfaceActions.isEmpty)
        #expect(vm.paletteCommandMatches.isEmpty)
        #expect(vm.actionMatches.isEmpty)
    }

    @Test func catalogActionSearchUsesPinStateAcrossPinnableItems() {
        for kind in [LauncherItemKind.clipboard, .screenshot, .conversation, .snippet, .quickLink, .folder, .askAI] {
            for pinned in [false, true] {
                let item = LauncherCatalogItem(kind: kind, itemID: "fixture", title: "Fixture", detail: "", value: "value", isPinned: pinned)
                let actions = ItemActionCatalog.actions(for: .item(item), pasteTarget: nil)
                let matches = QuickViewModel.rankByQuery(actions, query: "UNPN", title: \.title)
                #expect(matches.map(\.kind) == (pinned ? [.pin] : []))
            }
        }
    }
}
