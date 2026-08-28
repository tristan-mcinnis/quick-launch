import Testing
import Foundation
@testable import QuickLaunch

// Tests for QuickSettings persistence.
// Uses an isolated UserDefaults suite per test to avoid cross-test contamination.

@Suite("QuickSettings")
struct QuickSettingsTests {

    // Isolated UserDefaults suite name — unique per test run
    private func freshDefaults() -> UserDefaults {
        let suiteName = "com.quicklaunch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return defaults
    }

    // MARK: - 1. Default values

    @Test func testDefaultValues() {
        let settings = QuickSettings()
        #expect(settings.autoCopy == true)
        #expect(settings.launchAtLogin == true)
        #expect(settings.showMenuBar == true)
        #expect(settings.checkForUpdatesOnLaunch == false)
        #expect(settings.hasSeenWelcome == false)
        #expect(settings.configurationVersion == 17)
        #expect(!settings.screenHistorySameUserAccessRiskAccepted)
        #expect(settings.caffeinateEnabled)
        #expect(settings.clipboardHistoryEnabled)
        #expect(settings.clipboardHistoryLimit == 50)
        #expect(settings.clipboardHistoryHotkey.keyCode == 9)
        #expect(settings.typeToClickHotkey == ActionHotkey(
            keyCode: 8, modifiers: 262_144 | 524_288
        ))
        #expect(settings.reopenRetentionSeconds == 10)
        #expect(settings.selectedProviderID == InferenceProvider.deepSeekID)
        #expect(!settings.systemPrompt.isEmpty)
        #expect(settings.launcherItemConfigurations.contains {
            $0.itemID == "window.leftHalf"
                && $0.alias == "left"
                && $0.hotkey == ActionHotkey(keyCode: 123, modifiers: 1_572_864)
        })
    }

    @Test func screenHistorySameUserRiskAcceptanceRoundTripsAndDefaultsClosed() throws {
        let defaults = freshDefaults()
        var settings = QuickSettings()
        #expect(!settings.screenHistorySameUserAccessRiskAccepted)
        settings.screenHistorySameUserAccessRiskAccepted = true
        settings.save(to: defaults)
        #expect(QuickSettings.load(from: defaults).screenHistorySameUserAccessRiskAccepted)

        struct LegacySettings: Encodable { var configurationVersion = 17 }
        let legacy = try JSONDecoder().decode(
            QuickSettings.self,
            from: JSONEncoder().encode(LegacySettings())
        )
        #expect(!legacy.screenHistorySameUserAccessRiskAccepted)
    }

    @Test func typeToClickHotkeyCanChangeAndBeCleared() throws {
        let defaults = freshDefaults()
        var settings = QuickSettings()
        settings.typeToClickHotkey = ActionHotkey(keyCode: 0, modifiers: 1_048_576)
        settings.save(to: defaults)
        #expect(QuickSettings.load(from: defaults).typeToClickHotkey == settings.typeToClickHotkey)

        settings.typeToClickHotkeyEnabled = false
        settings.save(to: defaults)
        #expect(!QuickSettings.load(from: defaults).typeToClickHotkeyEnabled)

        struct LegacySettings: Encodable { var configurationVersion = 17 }
        let legacy = try JSONDecoder().decode(
            QuickSettings.self,
            from: JSONEncoder().encode(LegacySettings())
        )
        #expect(legacy.typeToClickHotkey == ActionHotkey(
            keyCode: 8, modifiers: 262_144 | 524_288
        ))
        #expect(legacy.typeToClickHotkeyEnabled)
    }

    @Test func testLauncherItemConfigurationRoundTrips() {
        let defaults = freshDefaults()
        var settings = QuickSettings()
        settings.launcherItemConfigurations = [
            LauncherItemConfiguration(
                kind: .application,
                itemID: "com.tinyspeck.slackmacgap",
                alias: "work chat",
                hotkey: ActionHotkey(keyCode: 1, modifiers: 524_288)
            )
        ]

        settings.save(to: defaults)
        let loaded = QuickSettings.load(from: defaults)

        #expect(loaded.launcherItemConfigurations == settings.launcherItemConfigurations)
    }

    @Test func screenHistoryDomainExclusionsRoundTrip() {
        let defaults = freshDefaults()
        var settings = QuickSettings()
        settings.screenHistoryExcludedDomains = ["private.example.com", "example.org"]

        settings.save(to: defaults)
        let loaded = QuickSettings.load(from: defaults)

        #expect(loaded.screenHistoryExcludedDomains == settings.screenHistoryExcludedDomains)
    }

    @Test func screenHistoryCommunicationSourcesCanBeIncludedCaseByCase() {
        var settings = QuickSettings()
        #expect(settings.screenHistoryIncludes(
            bundleIdentifiers: ["com.tinyspeck.slackmacgap"]
        ))
        #expect(settings.screenHistoryIncludes(domains: ["web.whatsapp.com"]))

        settings.setScreenHistoryIncluded(
            false,
            bundleIdentifiers: ["com.tinyspeck.slackmacgap"]
        )
        settings.setScreenHistoryIncluded(false, domains: ["web.whatsapp.com"])

        #expect(!settings.screenHistoryIncludes(
            bundleIdentifiers: ["COM.TINYSPECK.SLACKMACGAP"]
        ))
        #expect(!settings.screenHistoryIncludes(domains: ["https://web.whatsapp.com/chat"]))
        #expect(settings.screenHistoryIncludes(
            bundleIdentifiers: ["com.microsoft.outlook"]
        ))

        settings.setScreenHistoryIncluded(
            true,
            bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
            domains: ["web.whatsapp.com"]
        )
        #expect(settings.screenHistoryIncludes(
            bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
            domains: ["web.whatsapp.com"]
        ))
    }

    @Test func legacySettingsGainSafeScreenHistoryDomainDefaults() throws {
        struct LegacySettings: Encodable {
            var configurationVersion = 16
            var screenHistoryExcludedBundleIDs = ["com.example.private"]
        }
        let decoded = try JSONDecoder().decode(
            QuickSettings.self,
            from: JSONEncoder().encode(LegacySettings())
        )

        #expect(decoded.configurationVersion == 17)
        #expect(decoded.screenHistoryExcludedBundleIDs == ["com.example.private"])
        #expect(decoded.screenHistoryExcludedDomains == ScreenHistoryCaptureConfiguration.safeDefaultExcludedDomains.sorted())
    }

    @Test func testLegacySettingsGainPiSearchActionOnce() throws {
        struct LegacySettings: Encodable {
            var savedPrompts = [SavedPrompt(alias: "grammar", prompt: "Fix this")]
        }
        let decoded = try JSONDecoder().decode(
            QuickSettings.self,
            from: JSONEncoder().encode(LegacySettings())
        )

        #expect(decoded.savedPrompts.filter { $0.alias == "search" }.count == 1)
        #expect(decoded.savedPrompts.first(where: { $0.alias == "grammar" })?.outputBehavior == .replaceSelection)
        #expect(decoded.savedPrompts.first(where: { $0.alias == "grammar" })?.name == "Clean Up")
        #expect(decoded.providers.contains { $0.id == InferenceProvider.mlxVisionID })
    }

    @Test func testActionHotkeyConflictsAreDetected() {
        var settings = QuickSettings()
        let firstID = settings.savedPrompts[0].id
        settings.savedPrompts[0].hotkey = ActionHotkey(
            keyCode: settings.hotkeyKeyCode,
            modifiers: settings.hotkeyModifiers
        )
        #expect(settings.actionHotkeyConflict(for: firstID)?.contains("main") == true)

        settings.savedPrompts[0].hotkey = ActionHotkey(keyCode: 3, modifiers: 786_432)
        settings.savedPrompts[1].hotkey = settings.savedPrompts[0].hotkey
        #expect(settings.actionHotkeyConflict(for: firstID)?.contains(settings.savedPrompts[1].name) == true)
    }

    @Test func clipboardHistoryConflictNamesDedicatedHotkeys() {
        var settings = QuickSettings()
        settings.clipboardHistoryHotkey = settings.typeToClickHotkey
        #expect(settings.clipboardHistoryHotkeyConflict()?.contains("Type to Click") == true)

        settings.typeToClickHotkeyEnabled = false
        settings.clipboardHistoryHotkey = settings.translatorHotkey
        #expect(settings.clipboardHistoryHotkeyConflict()?.contains("Translator") == true)
    }

    // MARK: - 2. Hotkey defaults

    @Test func testHotkeyDefaults() {
        let settings = QuickSettings()
        // Space bar key code = 49
        #expect(settings.hotkeyKeyCode == 49)
        // Option key modifier = NSEvent.ModifierFlags.option.rawValue = 524288
        #expect(settings.hotkeyModifiers == 524288)
    }

    // MARK: - 3. Save and load round-trip preserves all fields

    @Test func testSaveAndLoadRoundtrip() {
        let defaults = freshDefaults()
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.launchAtLogin = false
        settings.showMenuBar = false
        settings.checkForUpdatesOnLaunch = false
        settings.hasSeenWelcome = true
        settings.hotkeyKeyCode = 36   // Return key
        settings.hotkeyModifiers = 786432  // Command + Option
        settings.select(providerID: InferenceProvider.deepSeekID, model: "deepseek-v4-pro")
        settings.systemPrompt = "Return only corrected text."
        settings.reopenRetentionSeconds = 30

        settings.save(to: defaults)

        let loaded = QuickSettings.load(from: defaults)
        #expect(loaded.autoCopy == false)
        #expect(loaded.launchAtLogin == false)
        #expect(loaded.showMenuBar == false)
        #expect(loaded.checkForUpdatesOnLaunch == false)
        #expect(loaded.hasSeenWelcome == true)
        #expect(loaded.hotkeyKeyCode == 36)
        #expect(loaded.hotkeyModifiers == 786432)
        #expect(loaded.selectedProviderID == InferenceProvider.deepSeekID)
        #expect(loaded.selectedModel == "deepseek-v4-pro")
        #expect(loaded.systemPrompt == "Return only corrected text.")
        #expect(loaded.reopenRetentionSeconds == 30)
    }

    // MARK: - 4. Load from empty UserDefaults returns defaults

    @Test func testLoadFromEmptyDefaultsReturnsDefaults() {
        let defaults = freshDefaults()
        let loaded = QuickSettings.load(from: defaults)
        // Should be identical to a fresh QuickSettings()
        #expect(loaded.autoCopy == true)
        #expect(loaded.launchAtLogin == true)
        #expect(loaded.showMenuBar == true)
        #expect(loaded.checkForUpdatesOnLaunch == false)
        #expect(loaded.hasSeenWelcome == false)
        #expect(loaded.hotkeyKeyCode == 49)
        #expect(loaded.hotkeyModifiers == 524288)
    }

    // MARK: - 5. Load from corrupt data returns defaults

    @Test func testLoadFromCorruptDataReturnsDefaults() {
        let defaults = freshDefaults()
        // Write garbage bytes to the settings key
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF])
        defaults.set(garbage, forKey: QuickSettings.defaultsKey)

        let loaded = QuickSettings.load(from: defaults)
        #expect(loaded.autoCopy == true)
        #expect(loaded.launchAtLogin == true)
        #expect(loaded.hasSeenWelcome == false)
    }

    // MARK: - 6. Second save overwrites first

    @Test func testSaveOverwritesPreviousValue() {
        let defaults = freshDefaults()

        var first = QuickSettings()
        first.autoCopy = true
        first.save(to: defaults)

        var second = QuickSettings()
        second.autoCopy = false
        second.save(to: defaults)

        let loaded = QuickSettings.load(from: defaults)
        #expect(loaded.autoCopy == false)
    }

    // MARK: - Additional edge cases

    // 7. hasSeenWelcome can be toggled and persisted
    @Test func testHasSeenWelcomeToggle() {
        let defaults = freshDefaults()
        var settings = QuickSettings()
        #expect(settings.hasSeenWelcome == false)

        settings.hasSeenWelcome = true
        settings.save(to: defaults)

        let loaded = QuickSettings.load(from: defaults)
        #expect(loaded.hasSeenWelcome == true)
    }

    // 8. Custom hotkey key code persists correctly
    @Test func testCustomHotkeyKeyCodePersists() {
        let defaults = freshDefaults()
        var settings = QuickSettings()
        settings.hotkeyKeyCode = 0   // 'a' key
        settings.save(to: defaults)

        let loaded = QuickSettings.load(from: defaults)
        #expect(loaded.hotkeyKeyCode == 0)
    }

    // 9. Modifier flags zero value persists
    @Test func testZeroModifierFlagsPersists() {
        let defaults = freshDefaults()
        var settings = QuickSettings()
        settings.hotkeyModifiers = 0
        settings.save(to: defaults)

        let loaded = QuickSettings.load(from: defaults)
        #expect(loaded.hotkeyModifiers == 0)
    }

    // 10. defaultsKey is stable
    @Test func testDefaultsKeyIsStable() {
        #expect(QuickSettings.defaultsKey == "QuickSettings")
    }
}
