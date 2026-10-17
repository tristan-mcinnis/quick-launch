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

    @Test func theShrinkHoldIsShort() {
        #expect(PanelResizeTrigger.shrinkHold == .milliseconds(50))
    }
}
