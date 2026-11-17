import Foundation
import Testing
@testable import QuickLaunch

/// The launcher's Quick AI grows with a long answer, in steps, up to its
/// limit, for the chat it grew for; the AI Chat window never does.
@Suite("Quick AI grows with a long answer")
@MainActor
struct QuickAIGrowthTests {
    private func make(grows: Bool = true) -> QuickViewModel {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let vm = QuickViewModel(settings: settings, service: MockQuickService())
        vm.growsWithAnswer = grows
        vm.quickAIGrowLimit = 760
        vm.openQuickAI()
        vm.currentConversation = QuickConversation(providerID: UUID(), model: "test", messages: [])
        return vm
    }

    private var standard: CGFloat { QuickAISize.standard.height }

    @Test func roomLeftMeansNoGrowth() {
        let vm = make()
        vm.noteQuickAIRoom(40, visibleHeight: 360)
        #expect(vm.quickAISize.height == standard)
        #expect(vm.canGrowQuickAI)
    }

    @Test func aTallTurnGrowsTheSurfaceInSteps() {
        let vm = make()
        let chrome = standard - 360
        vm.noteQuickAIRoom(10, visibleHeight: 360)   // measures the chrome
        vm.noteQuickAIRoom(-50, visibleHeight: 360)
        let grown = vm.quickAISize.height
        #expect(grown >= 360 + 50 + chrome)
        #expect(grown.truncatingRemainder(dividingBy: QuickViewModel.quickAIGrowthStep) == 0)
        // The same report again (the window has not grown yet) asks nothing new.
        vm.noteQuickAIRoom(-50, visibleHeight: 360)
        #expect(vm.quickAISize.height == grown)
    }

    @Test func growthStopsAtTheLimitAndThenTheHoldMayCome() {
        let vm = make()
        vm.noteQuickAIRoom(10, visibleHeight: 360)
        vm.noteQuickAIRoom(-5_000, visibleHeight: 360)
        #expect(vm.quickAISize.height == 760)
        #expect(!vm.canGrowQuickAI)
    }

    @Test func anotherChatStartsAtTheUsersSize() {
        let vm = make()
        vm.noteQuickAIRoom(10, visibleHeight: 360)
        vm.noteQuickAIRoom(-200, visibleHeight: 360)
        #expect(vm.quickAISize.height > standard)
        vm.currentConversation = QuickConversation(providerID: UUID(), model: "test", messages: [])
        #expect(vm.quickAISize.height == standard)
    }

    @Test func aDragTakesOverFromGrowth() {
        let vm = make()
        vm.noteQuickAIRoom(10, visibleHeight: 360)
        vm.noteQuickAIRoom(-200, visibleHeight: 360)
        vm.rememberQuickAISize(CGSize(width: QuickAISize.standard.width, height: standard + 20))
        #expect(vm.quickAIGrowth == nil)
        #expect(abs(vm.quickAISize.height - (standard + 20)) < 1)
    }

    @Test func theAIChatWindowNeverGrows() {
        let vm = make(grows: false)
        vm.noteQuickAIRoom(10, visibleHeight: 360)
        vm.noteQuickAIRoom(-200, visibleHeight: 360)
        #expect(vm.quickAISize.height == standard)
        #expect(!vm.canGrowQuickAI, "so the hold works there as before")
    }
}
