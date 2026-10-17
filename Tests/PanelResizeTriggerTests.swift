import Foundation
import Testing
@testable import QuickLaunch

@Suite("PanelResizeTrigger")
@MainActor
struct PanelResizeTriggerTests {
    /// Re-arms after every change, as the AppDelegate does, and reports
    /// the passes the changes in `body` started.
    private func passes(on vm: QuickViewModel, _ body: () -> Void) -> Int {
        // Re-armed on the spot: the change is counted before the value lands.
        final class Rearm: @unchecked Sendable {
            nonisolated(unsafe) var run: (() -> Void)?
        }
        let rearm = Rearm()
        rearm.run = { PanelResizeTrigger.arm(viewModel: vm) { rearm.run?() } }
        rearm.run?()
        defer { rearm.run = nil }
        let before = PanelResizeTrigger.passCount
        body()
        return PanelResizeTrigger.passCount - before
    }

    @Test func arrowingThroughTheLauncherStartsNoResizePass() {
        let vm = QuickViewModel()
        #expect(vm.launcherMatches.count > 3)
        let count = passes(on: vm) {
            for _ in 0..<3 { vm.moveApplicationSelection(1) }
            vm.moveApplicationSelection(-1)
        }
        #expect(count == 0, "the window height does not depend on the selected row")
    }

    @Test func aStreamedAnswerStartsNoResizePassAfterTheSurfaceIsUp() {
        let vm = QuickViewModel()
        vm.output = "first"
        #expect(vm.isQuickAIPresented)
        let count = passes(on: vm) {
            vm.output = "first token"
            vm.output = "first token and more"
            vm.isStreaming = true
            vm.isStreaming = false
        }
        #expect(count == 0, "the Quick AI surface keeps its size while the answer grows")
    }

    @Test func typingStillStartsAResizePass() {
        let vm = QuickViewModel()
        let count = passes(on: vm) { vm.input = "x" }
        #expect(count >= 1, "the list under the field changes height as the query changes")
    }

    @Test func theDetailPaneOpeningOrClosingStartsAPass() {
        let vm = QuickViewModel(launcherCatalog: FakeLauncherCatalog())
        vm.enterCatalog(.snippets)
        #expect(vm.showsDetailPane)
        let stays = passes(on: vm) { vm.applicationSelectionIndex = 0 }
        #expect(stays == 0, "the pane stays open: the row change alone moves nothing")

        vm.input = "zzz-no-match"
        #expect(!vm.showsDetailPane)
        let closes = passes(on: vm) { vm.applicationSelectionIndex = 0 }
        #expect(closes >= 1, "the pane closed, so the window width must be re-measured")
    }

    @Test func arrowingInsideAPaneCatalogStartsNoResizePass() {
        let vm = QuickViewModel(launcherCatalog: FakeLauncherCatalog())
        vm.enterCatalog(.quickLinks)
        #expect(vm.showsDetailPane)
        let count = passes(on: vm) {
            vm.moveApplicationSelection(1)
            vm.moveApplicationSelection(-1)
        }
        #expect(count == 0)
    }

    @Test func growthAppliesAtOnceAndAShrinkWaits() {
        typealias T = PanelResizeTrigger
        #expect(T.step(frameHeight: 200, frameWidth: 700, targetHeight: 300, targetWidth: 700) == .applyNow,
                "growth applies now, which is also what cancels a pending shrink")
        #expect(T.step(frameHeight: 300, frameWidth: 700, targetHeight: 200, targetWidth: 700) == .holdShrink)
        #expect(T.step(frameHeight: 300, frameWidth: 700, targetHeight: 200, targetWidth: 900) == .applyNow,
                "a width change applies now even when the height shrinks")
        #expect(T.step(frameHeight: 300, frameWidth: 700, targetHeight: 300.5, targetWidth: 700) == .none)
    }

    @Test func theShrinkHoldIsShort() {
        #expect(PanelResizeTrigger.shrinkHold == .milliseconds(50))
    }
}
