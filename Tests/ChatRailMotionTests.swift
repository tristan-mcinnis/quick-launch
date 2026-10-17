// ChatRailMotionTests: the chat rail slides on the house curves, the
// conversation's slot snaps, Reduce Motion fades, and a narrow window
// gets an overlay instead of a squeeze.

import CoreGraphics
import HouseDesign
import Testing
@testable import QuickLaunch

struct ChatRailMotionTests {
    @Test func openingEasesOutAndClosingEasesIn() throws {
        let open = try #require(ChatRailMotion.curve(opening: true, reduceMotion: false))
        let close = try #require(ChatRailMotion.curve(opening: false, reduceMotion: false))
        #expect(open == (0.165, 0.84, 0.44, 1))
        #expect(close == (0.77, 0, 0.175, 1))
        #expect(ChatRailMotion.duration == 0.2)
    }

    @Test func reduceMotionHasNoCurveAndFadesOnly() {
        #expect(ChatRailMotion.curve(opening: true, reduceMotion: true) == nil)
        #expect(ChatRailMotion.curve(opening: false, reduceMotion: true) == nil)
    }

    @Test func slotSnapsOnlyWhenWideEnough() {
        let wide = House.Layout.chatMinWidth
        #expect(ChatRailMotion.slotWidth(railVisible: false, windowWidth: wide) == 0)
        #expect(ChatRailMotion.slotWidth(railVisible: true, windowWidth: wide) == House.Layout.chatRail + House.hairline)
        #expect(ChatRailMotion.slotWidth(railVisible: true, windowWidth: wide - 1) == 0, "narrow: the rail overlays")
    }
}
