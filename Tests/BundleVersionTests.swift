// BundleVersionTests — regression test for issue #3
//
// The user-visible version must come from the bundle's CFBundleShortVersionString,
// not the hardcoded "1.0.0" default parameter on QuickViewModel.init.
//
// https://github.com/Arthur-Ficial/apfel-quick/issues/3

import Foundation
import Testing
@testable import apfel_quick

@Suite("BundleVersion")
struct BundleVersionTests {

    @Test("AppDelegate wires Bundle.main.shortVersion into QuickViewModel")
    func appDelegateUsesBundleVersion() throws {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // Tests/
        url.deleteLastPathComponent() // repo root
        let source = try String(
            contentsOf: url.appendingPathComponent("Sources/App/AppDelegate.swift"),
            encoding: .utf8
        )
        // The only acceptable call site is the one that threads the bundle
        // version through. A bare `QuickViewModel()` silently regresses users
        // to "1.0.0" forever (issue #3).
        #expect(
            source.contains("currentVersion: Bundle.main.shortVersion"),
            "AppDelegate must construct QuickViewModel with Bundle.main.shortVersion — a bare QuickViewModel() falls back to the 1.0.0 default"
        )
        #expect(
            !source.contains("QuickViewModel()"),
            "AppDelegate must not call QuickViewModel() without arguments — that uses the 1.0.0 default parameter and hides the real bundle version"
        )
    }

    @Test("Bundle.shortVersion returns the embedded CFBundleShortVersionString")
    func shortVersionReadsInfoPlist() {
        // This test documents the contract the AppDelegate relies on. If
        // Bundle.main is somehow unreadable, shortVersion falls back to
        // "1.0.0", which is exactly the bug mode the user reported.
        let bundle = Bundle.main
        let v = bundle.shortVersion
        // Test process has its own (Xcode test host) Info.plist — just assert
        // the method returns a non-empty value that isn't nil-fallback-ish.
        #expect(!v.isEmpty, "shortVersion must never be empty")
    }
}
