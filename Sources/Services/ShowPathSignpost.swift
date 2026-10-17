import Foundation
import OSLog

/// Signposts for the show path: hotkey received, panel ordered front, the
/// field able to take keys. Read them in Instruments (os_signpost) or with
/// `log stream --signpost --predicate 'subsystem == "com.tristanmcinnis.quick-launch"'`.
///
/// Observation only. No log line carries user content, and the cost off
/// Instruments is a few atomic loads.
@MainActor
enum ShowPathSignpost {
    private static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "ShowPath")
    private static var open: OSSignpostIntervalState?

    /// A hotkey fired: starts the interval that ends when a field takes focus.
    /// A press while an earlier interval is still open (hotkey toggled the
    /// panel away before focus landed) closes the old one first.
    static func hotkeyReceived(quickAI: Bool) {
        endOpenInterval()
        let id = signposter.makeSignpostID()
        let surface = quickAI ? "quick-ai" : "launcher"
        open = signposter.beginInterval("HotkeyToFieldFocus", id: id, "\(surface, privacy: .public)")
    }

    /// The panel was ordered front and made key.
    static func panelOrderedFront() {
        signposter.emitEvent("PanelOrderedFront")
    }

    /// A launcher or composer field set its focus. This is the last point the
    /// app can observe without a key event: the field now accepts typing.
    static func fieldFocusApplied() {
        guard open != nil else { return }
        signposter.emitEvent("FieldFocusApplied")
        endOpenInterval()
    }

    /// The panel closed before any field took focus.
    static func abandon() {
        endOpenInterval()
    }

    /// Wraps the Quick AI surface open itself (state reset to presented).
    static func quickAIOpen<T>(_ body: () -> T) -> T {
        let state = signposter.beginInterval("OpenQuickAI")
        defer { signposter.endInterval("OpenQuickAI", state) }
        return body()
    }

    private static func endOpenInterval() {
        guard let state = open else { return }
        open = nil
        signposter.endInterval("HotkeyToFieldFocus", state)
    }
}
