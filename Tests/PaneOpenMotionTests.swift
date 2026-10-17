import Testing
@testable import QuickLaunch

@Suite @MainActor struct PaneOpenMotionTests {
    @Test func reduceMotionKeepsTheFadeAndDropsTheScale() {
        #expect(PaneOpenMotion.style(reduceMotion: true) == .fadeOnly)
        #expect(PaneOpenMotion.style(reduceMotion: false) == .fadeAndScale)
    }

    @Test func openScaleIsTheDesignValue() {
        #expect(PaneOpenMotion.startScale == 0.98)
    }

    @Test func primaryButtonIsSizedByItsLongestLabel() {
        let labels = [
            QuickViewModel.transformChooserConfirmTitle, QuickViewModel.addContextConfirmTitle,
            QuickViewModel.captureChooserConfirmTitle, QuickViewModel.assistantChooserConfirmTitle,
            QuickViewModel.queuedActionLabel, "Regenerate", "Use Model", "Open", "Stop", "Ask",
            "Paste Response", "Copy Response",
        ]
        for label in labels {
            #expect(label.count <= QuickAIComposer.widestPrimaryLabel.count)
        }
    }
}
