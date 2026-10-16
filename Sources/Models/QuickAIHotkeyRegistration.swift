import Foundation

/// The optional direct Quick AI hotkey's registration decision.
///
/// Split from the Carbon registration itself so the three rules that matter —
/// off by default, refuse a key something else owns, and re-read the settings
/// on every change — are testable without registering a real system hotkey.
enum QuickAIHotkeyRegistration {
    enum Decision: Equatable {
        /// The feature is off: nothing is registered.
        case disabled
        /// The chosen key collides with another key the app owns.
        case refused(String)
        /// Register this (already normalized) key.
        case register(ActionHotkey)
    }

    /// What `AppDelegate` should do for the settings it holds right now.
    /// Called once at launch and again on every settings change, so the same
    /// input always yields the same decision.
    static func decide(settings: QuickSettings) -> Decision {
        guard settings.quickAIHotkeyEnabled else { return .disabled }
        if let conflict = settings.quickAIHotkeyConflict() { return .refused(conflict) }
        return .register(settings.quickAIHotkey.normalized)
    }
}
