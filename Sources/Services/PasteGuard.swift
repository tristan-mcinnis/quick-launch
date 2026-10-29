import AppKit

/// Sends Command-V only while the clipboard still holds what Quick Launch
/// wrote. Between the write and the keystroke the app waits for the target to
/// come forward and for modifier keys to lift; if the user copies something
/// else in that window, Command-V would paste their new copy instead of the
/// answer. The two closures are the test seam; the defaults touch the system.
@MainActor
struct PasteGuard {
    var changeCount: @MainActor () -> Int = { NSPasteboard.general.changeCount }
    var sendCommandV: @MainActor () -> Bool = PasteGuard.postCommandV

    /// Returns false, without sending, when the change count moved. The log
    /// line carries no clipboard content.
    func sendCommandV(expectingChangeCount expected: Int) -> Bool {
        guard changeCount() == expected else { return false }
        return sendCommandV()
    }

    static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
