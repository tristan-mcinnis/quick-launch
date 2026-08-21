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
}
