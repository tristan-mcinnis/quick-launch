import CoreGraphics
import Testing
@testable import QuickLaunch

@Suite("Screen placement")
struct ScreenPlacementTests {
    @Test func choosesDisplayContainingPointer() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: -120, width: 1920, height: 1080),
        ]

        #expect(
            ScreenPlacement.screenIndex(
                containing: CGPoint(x: 2_000, y: 400),
                frames: frames
            ) == 1
        )
    }

    @Test func recognisesMenuBarsOnEveryDisplay() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: -1920, y: 900, width: 1920, height: 1080),
        ]

        #expect(ScreenPlacement.isInMenuBarRegion(
            CGPoint(x: 700, y: 890),
            frames: frames
        ))
        #expect(ScreenPlacement.isInMenuBarRegion(
            CGPoint(x: -1_000, y: 1_970),
            frames: frames
        ))
        #expect(!ScreenPlacement.isInMenuBarRegion(
            CGPoint(x: -1_000, y: 1_000),
            frames: frames
        ))
    }

    @Test func anchoredTopKeepsTheInputRowCentredAndInsideTheMargin() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        // Input row 408...468 is centred on 437.5; its top edge is the anchor.
        #expect(ScreenPlacement.anchoredTop(visibleFrame: visible, inputHeight: 60) == 468)
        // A very short display pulls the anchor down to the top margin.
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 40)
        #expect(ScreenPlacement.anchoredTop(visibleFrame: tiny, inputHeight: 60) == 28)
    }

    @Test func framesHungFromTheAnchorNeverMoveTheTopEdge() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let top = ScreenPlacement.anchoredTop(visibleFrame: visible, inputHeight: 60)
        let short = ScreenPlacement.frameHanging(from: top, height: 60, width: 720, centreX: 720, within: visible)
        let tall = ScreenPlacement.frameHanging(from: top, height: 603, width: 720, centreX: 720, within: visible)
        // Growth from the empty input to the full list keeps the same top.
        #expect(short.maxY == 468)
        #expect(tall.maxY == 468)
        #expect(short.height == 60)
        // Content taller than the room below the anchor is capped, not moved.
        #expect(tall.height == 456)
        #expect(tall.minY == 12)
        #expect(tall.minX == 360)
        // Width is kept inside the display's side margins.
        let wide = ScreenPlacement.frameHanging(from: top, height: 60, width: 2000, centreX: 720, within: visible)
        #expect(wide.width == 1416)
        #expect(wide.minX == 12)
    }

    @Test func panelInputRowSitsOnTheVisualCentreLine() {
        let origin = ScreenPlacement.panelOrigin(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            panelWidth: 620,
            inputHeight: 60
        )
        #expect(origin.x == 410)
        // Input row spans y 408...468, centred on 875 / 2 = 437.5.
        #expect(origin.y == 408)

        let second = ScreenPlacement.panelOrigin(
            screenFrame: CGRect(x: 1440, y: -120, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: -120, width: 1920, height: 1055),
            panelWidth: 620,
            inputHeight: 60
        )
        let expectedX: CGFloat = 2090
        let expectedY: CGFloat = 378   // (-120 + 527.5 - 30) rounded
        #expect(second.x == expectedX)
        #expect(second.y == expectedY)
    }

    @Test func tallPanelsShiftUpToStayOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let fits = CGRect(x: 410, y: 300, width: 620, height: 400)
        #expect(ScreenPlacement.clamped(frame: fits, within: visible) == fits)
        let low = CGRect(x: 410, y: -200, width: 620, height: 500)
        let shifted = ScreenPlacement.clamped(frame: low, within: visible)
        #expect(shifted.minY == 12 && shifted.height == 500)
        let tall = CGRect(x: 410, y: 100, width: 620, height: 900)
        let pinned = ScreenPlacement.clamped(frame: tall, within: visible)
        #expect(pinned.minY == 12)
        #expect(pinned.height == 851)
        #expect(pinned.maxY == 863)
    }

    @Test func oversizedPanelsShrinkAndStayInsideEveryEdge() {
        let visible = CGRect(x: -1_200, y: 50, width: 700, height: 500)
        let oversized = CGRect(x: -1_400, y: -200, width: 900, height: 800)

        let result = ScreenPlacement.clamped(frame: oversized, within: visible)

        #expect(result == CGRect(x: -1_188, y: 62, width: 676, height: 476))
    }
}
