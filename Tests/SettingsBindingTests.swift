import Testing
import Foundation
@testable import QuickLaunch

/// The settings views persist through `settingsBinding`, so every set must
/// land in UserDefaults immediately, exactly as the old `.onChange { save() }`
/// pattern did.
@MainActor
@Suite("Settings bindings", .serialized)
struct SettingsBindingTests {

    private func saved() -> QuickSettings {
        QuickSettings.load(from: .standard)
    }

    @Test func keyPathBindingSavesOnSet() async {
        let vm = QuickViewModel(service: MockQuickService())
        let original = saved().autoCopy
        defer { vm.updateSettings { $0.autoCopy = original } }

        let binding = vm.settingsBinding(\.autoCopy)
        binding.wrappedValue = !original

        #expect(vm.settings.autoCopy == !original)
        #expect(saved().autoCopy == !original)
    }

    @Test func keyPathBindingRunsSideEffectAfterSave() async {
        let vm = QuickViewModel(service: MockQuickService())
        let original = saved().reopenRetentionSeconds
        defer { vm.updateSettings { $0.reopenRetentionSeconds = original } }

        var observed: [Int] = []
        let binding = vm.settingsBinding(\.reopenRetentionSeconds) { observed.append($0) }
        binding.wrappedValue = 300

        #expect(observed == [300])
        #expect(saved().reopenRetentionSeconds == 300)
    }

    @Test func derivedBindingSavesTransformedValue() async {
        let vm = QuickViewModel(service: MockQuickService())
        let original = saved().hasSeenWelcome
        defer { vm.updateSettings { $0.hasSeenWelcome = original } }

        let showWelcome = vm.settingsBinding(
            get: { !$0.hasSeenWelcome },
            set: { settings, show in settings.hasSeenWelcome = !show }
        )
        showWelcome.wrappedValue = true

        #expect(showWelcome.wrappedValue == true)
        #expect(saved().hasSeenWelcome == false)
    }

    @Test func updateSettingsPersistsMutation() async {
        let vm = QuickViewModel(service: MockQuickService())
        let original = saved().clipboardHistoryLimit
        defer { vm.updateSettings { $0.clipboardHistoryLimit = original } }

        vm.updateSettings { $0.clipboardHistoryLimit = 170 }

        #expect(saved().clipboardHistoryLimit == 170)
    }
}
