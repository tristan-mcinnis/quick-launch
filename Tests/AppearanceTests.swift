import Testing
import Foundation
import SwiftUI
@testable import QuickLaunch

/// TDD (RED) for dark mode (issue #10).
///
/// Spec:
/// - QuickSettings.colorScheme: `.system | .light | .dark`, default `.dark` (legacy blobs that never chose one migrate to dark).
/// - AppearancePreference maps each case to `SwiftUI.ColorScheme?`
///   (nil = "follow system").
/// - Legacy QuickSettings blobs written before this feature still decode.

@Suite("AppearancePreference")
struct AppearancePreferenceTests {

    @Test func testCasesExist() {
        _ = AppearancePreference.system
        _ = AppearancePreference.light
        _ = AppearancePreference.dark
    }

    @Test func testSystemMapsToNilColorScheme() {
        #expect(AppearancePreference.system.swiftUIColorScheme == nil)
    }

    @Test func testLightMapsToLight() {
        #expect(AppearancePreference.light.swiftUIColorScheme == .light)
    }

    @Test func testDarkMapsToDark() {
        #expect(AppearancePreference.dark.swiftUIColorScheme == .dark)
    }

    @Test func testCodableRoundTrip() throws {
        for c in AppearancePreference.allCases {
            let data = try JSONEncoder().encode(c)
            let back = try JSONDecoder().decode(AppearancePreference.self, from: data)
            #expect(back == c)
        }
    }

    @Test func testDisplayNameIsHumanReadable() {
        for c in AppearancePreference.allCases {
            #expect(!c.displayName.isEmpty)
        }
        #expect(AppearancePreference.system.displayName == "Follow system")
        #expect(AppearancePreference.light.displayName == "Light")
        #expect(AppearancePreference.dark.displayName == "Dark")
    }

    @Test func testAllCasesCount() {
        #expect(AppearancePreference.allCases.count == 3)
    }
}

@Suite("QuickSettings appearance")
struct QuickSettingsAppearanceTests {

    @Test func testDefaultIsDark() {
        let s = QuickSettings()
        #expect(s.appearance == .dark)
    }

    @Test func testLegacyExplicitLightChoiceSurvivesMigration() throws {
        let legacy = #"""
        {"configurationVersion":9,"appearance":"light"}
        """#
        let s = try JSONDecoder().decode(QuickSettings.self, from: Data(legacy.utf8))
        #expect(s.appearance == .light)
    }

    @Test func testLegacySystemChoiceMovesToDarkOnce() throws {
        let legacy = #"""
        {"configurationVersion":9,"appearance":"system"}
        """#
        let migrated = try JSONDecoder().decode(QuickSettings.self, from: Data(legacy.utf8))
        #expect(migrated.appearance == .dark)

        // A deliberate return to "system" after the migration is respected.
        var chosen = migrated
        chosen.appearance = .system
        let data = try JSONEncoder().encode(chosen)
        let back = try JSONDecoder().decode(QuickSettings.self, from: data)
        #expect(back.appearance == .system)
    }

    @Test func testCustomAppearanceRoundTrips() throws {
        var s = QuickSettings()
        s.appearance = .dark
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(QuickSettings.self, from: data)
        #expect(back.appearance == .dark)
    }

    @Test func testLegacyBlobWithoutAppearanceDecodes() throws {
        let legacy = #"""
        {"hotkeyKeyCode":49,"hotkeyModifiers":524288,"autoCopy":true,"launchAtLogin":true,"showMenuBar":true,"checkForUpdatesOnLaunch":true,"hasSeenWelcome":true,"launchAtLoginPromptShown":true}
        """#
        let s = try JSONDecoder().decode(QuickSettings.self, from: Data(legacy.utf8))
        #expect(s.appearance == .dark)
    }
}
