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
}
