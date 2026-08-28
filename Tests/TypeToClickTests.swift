import XCTest
@testable import QuickLaunch

final class TypeToClickTests: XCTestCase {

    func testHintsEmpty() {
        XCTAssertEqual(HintGenerator.hints(count: 0, alphabet: "abc"), [])
        XCTAssertEqual(HintGenerator.hints(count: 3, alphabet: ""), [])
    }

    func testSingleLetterHintsWhenFewEnough() {
        XCTAssertEqual(HintGenerator.hints(count: 3, alphabet: "abc"), ["a", "b", "c"])
        XCTAssertEqual(HintGenerator.hints(count: 2, alphabet: "abc"), ["a", "b"])
    }

    func testAllHintsShareLengthForLargerCounts() {
        // 8 targets over a 3-char alphabet: 3 < 8 <= 9, so 2-char hints throughout.
        let hints = HintGenerator.hints(count: 8, alphabet: "abc")
        XCTAssertEqual(hints.count, 8)
        XCTAssertTrue(hints.allSatisfy { $0.count == 2 })
    }

    func testHintsAreUniqueAndNonPrefix() {
        let hints = HintGenerator.hints(count: 40, alphabet: "sadfjklewcmpgh")
        XCTAssertEqual(Set(hints).count, 40)
        for hint in hints {
            // No hint may be a strict prefix of another (unambiguous typing).
            let prefixes = hints.filter { $0.hasPrefix(hint) }
            XCTAssertEqual(prefixes, [hint], "\(hint) collides with \(prefixes)")
        }
    }

    func testCoverageForLargeCount() {
        let hints = HintGenerator.hints(count: 200, alphabet: "sadfjklewcmpgh")
        XCTAssertEqual(hints.count, 200)
        XCTAssertTrue(hints.allSatisfy { !$0.isEmpty })
    }
}
