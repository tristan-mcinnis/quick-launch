import Testing
import Foundation
@testable import QuickLaunch

// Tests for semantic version comparison logic.
// QuickViewModel.isVersionNewer(_:than:) is a static helper used by
// handleUpdateCheck to decide whether a remote version is newer.
//
// Signature: static func isVersionNewer(_ remote: String, than local: String) -> Bool

@Suite("VersionComparison")
struct VersionComparisonTests {

    // MARK: - 1. Newer patch returns true

    @Test func testNewerPatch() {
        #expect(QuickViewModel.isVersionNewer("1.0.1", than: "1.0.0") == true)
    }

    // MARK: - 2. Newer minor returns true (even with larger patch in local)

    @Test func testNewerMinor() {
        #expect(QuickViewModel.isVersionNewer("1.1.0", than: "1.0.9") == true)
    }

    // MARK: - 3. Newer major returns true (even with larger minor.patch in local)

    @Test func testNewerMajor() {
        #expect(QuickViewModel.isVersionNewer("2.0.0", than: "1.9.9") == true)
    }

    // MARK: - 4. Same version returns false

    @Test func testSameVersion() {
        #expect(QuickViewModel.isVersionNewer("1.0.0", than: "1.0.0") == false)
    }

    // MARK: - 5. Older remote version returns false

    @Test func testOlderVersion() {
        #expect(QuickViewModel.isVersionNewer("1.0.0", than: "1.0.1") == false)
    }

    // MARK: - 6. Missing patch component — treated as .0

    @Test func testMissingPatch() {
        // "1.1" treated as "1.1.0" which is newer than "1.0.0"
        #expect(QuickViewModel.isVersionNewer("1.1", than: "1.0.0") == true)
    }

    // MARK: - 7. v prefix stripped from remote version

    @Test func testVPrefixStripped() {
        #expect(QuickViewModel.isVersionNewer("v1.0.1", than: "1.0.0") == true)
    }

    // MARK: - 8. v prefix stripped from both versions

    @Test func testBothVPrefix() {
        #expect(QuickViewModel.isVersionNewer("v2.0.0", than: "v1.9.9") == true)
    }

    // MARK: - Additional edge cases

    // 9. Much newer major is still just "newer"
    @Test func testMuchNewerMajor() {
        #expect(QuickViewModel.isVersionNewer("10.0.0", than: "1.0.0") == true)
    }

    // 10. Older minor returns false
    @Test func testOlderMinorReturnsFalse() {
        #expect(QuickViewModel.isVersionNewer("1.0.0", than: "1.1.0") == false)
    }

    // 11. Older major returns false
    @Test func testOlderMajorReturnsFalse() {
        #expect(QuickViewModel.isVersionNewer("1.9.9", than: "2.0.0") == false)
    }

    // 12. v prefix only on local version
    @Test func testVPrefixOnlyOnLocal() {
        #expect(QuickViewModel.isVersionNewer("1.0.1", than: "v1.0.0") == true)
    }

    // 13. Equal versions with v prefix on both — same, returns false
    @Test func testSameVersionBothVPrefix() {
        #expect(QuickViewModel.isVersionNewer("v1.2.3", than: "v1.2.3") == false)
    }

    // 14. Single component version "2" vs "1.9.9" — "2" treated as "2.0.0"
    @Test func testSingleComponentVersion() {
        #expect(QuickViewModel.isVersionNewer("2", than: "1.9.9") == true)
    }

    // 15. Same minor, newer patch
    @Test func testSameMinorNewerPatch() {
        #expect(QuickViewModel.isVersionNewer("1.2.5", than: "1.2.4") == true)
    }

    // 16. Same minor, older patch
    @Test func testSameMinorOlderPatch() {
        #expect(QuickViewModel.isVersionNewer("1.2.3", than: "1.2.4") == false)
    }
}
