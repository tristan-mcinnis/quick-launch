import CoreGraphics
import Testing
@testable import QuickLaunch

@Suite("Window layouts")
struct WindowLayoutTests {
    @Test func halvesCoverTheExpectedRegions() {
        #expect(WindowLayout.leftHalf.normalizedFrame == CGRect(x: 0, y: 0, width: 0.5, height: 1))
        #expect(WindowLayout.rightHalf.normalizedFrame == CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(WindowLayout.topHalf.normalizedFrame == CGRect(x: 0, y: 0, width: 1, height: 0.5))
        #expect(WindowLayout.bottomHalf.normalizedFrame == CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
    }

    @Test func thirdsAndFourthsPartitionTheDisplay() {
        let thirds = [WindowLayout.firstThird, .centerThird, .lastThird]
        let fourths = [WindowLayout.firstFourth, .secondFourth, .thirdFourth, .lastFourth]
        #expect(abs(thirds.reduce(0) { $0 + $1.normalizedFrame.width } - 1) < 0.000_001)
        #expect(fourths.reduce(0) { $0 + $1.normalizedFrame.width } == 1)
        let expectedThirdOrigins: [CGFloat] = [0, 1.0 / 3.0, 2.0 / 3.0]
        #expect(zip(thirds.map(\.normalizedFrame.minX), expectedThirdOrigins).allSatisfy {
            abs($0 - $1) < 0.000_001
        })
        #expect(fourths.map(\.normalizedFrame.minX) == [0, 0.25, 0.5, 0.75])
    }

    @Test func layoutsUseFamiliarDirectionalNamesAndGroups() {
        #expect(WindowLayout.firstThird.title == "Left Third")
        #expect(WindowLayout.centerThird.title == "Middle Third")
        #expect(WindowLayout.lastFourth.title == "Right Fourth")
        #expect(WindowLayout.leftHalf.groupTitle == "Halves")
        #expect(WindowLayout.centerThird.groupTitle == "Thirds")
        #expect(WindowLayout.thirdFourth.groupTitle == "Fourths")
    }

    @Test func wholeScreenLayoutsStayInsideTheUnitSquare() {
        let limit: CGFloat = 1.0001
        for layout in WindowLayout.allCases {
            let frame = layout.normalizedFrame
            let insideLeftTop = frame.minX >= 0 && frame.minY >= 0
            let insideRightBottom = frame.maxX <= limit && frame.maxY <= limit
            #expect(insideLeftTop)
            #expect(insideRightBottom)
        }
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        #expect(WindowLayout.maximize.normalizedFrame == full)
        let centerMidX: CGFloat = WindowLayout.center.normalizedFrame.midX
        #expect(centerMidX == 0.5)
        let leftTwoThirdsMaxX: CGFloat = WindowLayout.leftTwoThirds.normalizedFrame.maxX
        let lastThirdMinX: CGFloat = WindowLayout.lastThird.normalizedFrame.minX
        #expect(leftTwoThirdsMaxX == lastThirdMinX)
        let rightTwoThirdsMinX: CGFloat = WindowLayout.rightTwoThirds.normalizedFrame.minX
        let firstThirdMaxX: CGFloat = WindowLayout.firstThird.normalizedFrame.maxX
        #expect(rightTwoThirdsMinX == firstThirdMaxX)
        #expect(WindowLayout.groupTitles == ["Whole Screen", "Halves", "Thirds", "Fourths"])
        let groups = Set(WindowLayout.allCases.map(\.groupTitle))
        #expect(groups == Set(WindowLayout.groupTitles))
    }

    @Test func displayMovesWrapAroundAndKeepRelativePlacement() {
        #expect(WindowMove.nextDisplay.targetIndex(current: 1, count: 2) == 0)
        #expect(WindowMove.previousDisplay.targetIndex(current: 0, count: 2) == 1)

        let source = CGRect(x: 0, y: 25, width: 1000, height: 600)
        let target = CGRect(x: 1000, y: 0, width: 2000, height: 1200)
        let window = CGRect(x: 500, y: 25, width: 500, height: 300)
        let moved = WindowMove.relocatedFrame(window: window, from: source, to: target)
        let expected = CGRect(x: 2000, y: 0, width: 1000, height: 600)
        #expect(moved == expected)

        // A window larger than the destination is clamped to fit.
        let big = CGRect(x: 0, y: 25, width: 1000, height: 600)
        let small = CGRect(x: 1000, y: 0, width: 500, height: 300)
        let clamped = WindowMove.relocatedFrame(window: big, from: source, to: small)
        let fits = clamped.width <= small.width && clamped.height <= small.height
        let inside = clamped.minX >= small.minX && clamped.minY >= small.minY
        #expect(fits)
        #expect(inside)
    }
}
