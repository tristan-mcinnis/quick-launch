import Foundation
import Testing
@testable import QuickLaunch

@MainActor
@Suite("Selection pacing")
struct ListSelectionPacingTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    @Test("A first or deliberate press slides; a held key cuts")
    func helper() {
        #expect(ListSelection.shouldAnimateSelection(previous: nil, now: t0))
        #expect(ListSelection.shouldAnimateSelection(previous: t0, now: t0.addingTimeInterval(0.3)))
        #expect(!ListSelection.shouldAnimateSelection(previous: t0, now: t0.addingTimeInterval(0.03)))
        #expect(ListSelection.shouldAnimateSelection(previous: t0, now: t0.addingTimeInterval(ListSelection.repeatThreshold)))
    }

    @Test("The pacer cuts on repeat, slides again after a pause, and is stable within one render")
    func pacer() {
        let pacer = SelectionPacer()
        #expect(pacer.animates(for: 0, now: t0))
        #expect(pacer.animates(for: 1, now: t0.addingTimeInterval(1)))
        #expect(!pacer.animates(for: 2, now: t0.addingTimeInterval(1.03)))
        #expect(!pacer.animates(for: 2, now: t0.addingTimeInterval(2)))
        #expect(pacer.animates(for: 3, now: t0.addingTimeInterval(3)))
    }
}
