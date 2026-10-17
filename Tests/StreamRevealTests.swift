import Foundation
import Testing
@testable import QuickLaunch

@Suite("StreamReveal")
struct StreamRevealTests {
    private static func framesToCatchUp(total: Int, from shown: Int = 0) -> Int {
        var shown = shown
        var frames = 0
        while shown < total {
            shown = StreamReveal.advance(shown: shown, total: total, frames: 1)
            frames += 1
        }
        return frames
    }

    @Test func oneCharacterTakesOneFrame() {
        #expect(StreamReveal.advance(shown: 0, total: 1, frames: 1) == 1)
        #expect(Self.framesToCatchUp(total: 1) == 1)
    }

    @Test func aSmallBurstMovesAtLeastTwoCharactersAFrame() {
        #expect(StreamReveal.advance(shown: 0, total: 10, frames: 1) == 2)
        #expect(StreamReveal.advance(shown: 8, total: 10, frames: 1) == 10)
    }

    @Test func aBacklogMovesATwelfthAFrame() {
        #expect((100...101).contains(StreamReveal.advance(shown: 0, total: 1_200, frames: 1)))
        // 40 characters: the floor of two a frame is the larger step at first.
        #expect(Self.framesToCatchUp(total: 40) < 40 / 2 + 1)
    }

    @Test func aBacklogOverTheThresholdShowsAtOnce() {
        #expect(StreamReveal.advance(shown: 0, total: 4_001, frames: 1) == 4_001)
        #expect(StreamReveal.advance(shown: 0, total: 4_000, frames: 1) < 4_000)
    }

    @Test func aLongFrameCatchesUpFurther() {
        let one = StreamReveal.advance(shown: 0, total: 500, frames: 1)
        let four = StreamReveal.advance(shown: 0, total: 500, frames: 4)
        #expect(four > one)
    }

    @Test func neverPassesTheTotalAndEventuallyArrives() {
        for total in [0, 1, 7, 300, 3_999] {
            #expect(StreamReveal.advance(shown: total, total: total, frames: 1) == total)
            var shown = 0
            for _ in 0..<(total + 1) {
                shown = StreamReveal.advance(shown: shown, total: total, frames: 1)
                #expect(shown <= total)
            }
            #expect(shown == total)
        }
    }

    @Test func prefixKeepsTextWholeAtOrPastTheEnd() {
        #expect(StreamReveal.prefix(of: "hello", count: 3) == "hel")
        #expect(StreamReveal.prefix(of: "hello", count: 5) == "hello")
        #expect(StreamReveal.prefix(of: "hello", count: 99) == "hello")
        #expect(StreamReveal.prefix(of: "hello", count: 0) == "")
    }

    @MainActor
    @Test func theClockDrawsWhatHasArrivedOnFirstSight() {
        let clock = RevealClock()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        #expect(clock.visible(total: 50, now: t0) == 50)
        // New text eases in; it does not appear at once.
        let next = clock.visible(total: 80, now: t0.addingTimeInterval(StreamReveal.frame))
        #expect(next > 50 && next < 80)
    }

    @MainActor
    @Test func theClockEasesInAfterAnIdlePauseInsteadOfDrawingTheChunkAtOnce() {
        let clock = RevealClock()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = clock.visible(total: 50, now: t0)
        // The timeline paused for a second; a 20 character chunk then lands.
        let next = clock.visible(total: 70, now: t0.addingTimeInterval(1))
        #expect(next > 50 && next <= 50 + 4)
    }

    @MainActor
    @Test func theClockRestartsWhenTheTextShrinksAndWhenReset() {
        let clock = RevealClock()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = clock.visible(total: 100, now: t0)
        #expect(clock.visible(total: 10, now: t0.addingTimeInterval(0.02)) == 10)
        clock.reset()
        #expect(clock.shown == nil)
    }
}
