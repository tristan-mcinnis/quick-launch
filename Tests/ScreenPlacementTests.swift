import CoreGraphics
import Testing
@testable import apfel_quick

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
}
