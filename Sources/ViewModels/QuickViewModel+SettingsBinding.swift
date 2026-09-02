import SwiftUI

/// Settings views bind straight to `viewModel.settings` and persist on every
/// user edit, so no view needs a trailing `.onChange { settings.save() }`.
///
/// `QuickSettings.save()` encodes the whole struct to `UserDefaults`; every
/// setter here calls it once after the mutation, matching the old per-change
/// save behaviour.
extension QuickViewModel {

    /// A binding to one stored setting that saves after each set.
    /// `onSet` runs after the save, for side effects such as notifications.
    func settingsBinding<Value>(
        _ keyPath: WritableKeyPath<QuickSettings, Value>,
        onSet: ((Value) -> Void)? = nil
    ) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in
                self.settings[keyPath: keyPath] = value
                self.settings.save()
                onSet?(value)
            }
        )
    }

    /// A binding whose view value is derived from the settings (inverted
    /// flags, joined lists, optional fallbacks). `set` mutates the settings,
    /// the helper saves, then `onSet` runs.
    func settingsBinding<Value>(
        get: @escaping (QuickSettings) -> Value,
        set: @escaping (inout QuickSettings, Value) -> Void,
        onSet: (() -> Void)? = nil
    ) -> Binding<Value> {
        Binding(
            get: { get(self.settings) },
            set: { value in
                set(&self.settings, value)
                self.settings.save()
                onSet?()
            }
        )
    }

    /// Applies one edit to the settings and persists it. For button actions
    /// and list edits that do not go through a `Binding`.
    func updateSettings(_ mutation: (inout QuickSettings) -> Void) {
        mutation(&settings)
        settings.save()
    }
}
