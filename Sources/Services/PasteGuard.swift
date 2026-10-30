import AppKit

/// How a paste ended. `clipboardChanged` means nothing was sent because the
/// user copied something else first: callers must not copy the answer over it.
enum PasteOutcome: Sendable, Equatable {
    case pasted
    case clipboardChanged
    case failed
}

/// Sends Command-V only while the clipboard still holds what Quick Launch
/// wrote. Between the write and the keystroke the app waits for the target to
/// come forward and for modifier keys to lift; if the user copies something
/// else in that window, Command-V would paste their new copy instead of the
/// answer. The two closures are the test seam; the defaults touch the system.
@MainActor
struct PasteGuard {
    var changeCount: @MainActor () -> Int = { NSPasteboard.general.changeCount }
    var sendCommandV: @MainActor () -> Bool = PasteGuard.postCommandV
    /// Waits (bounded) for held modifier keys to lift, so they cannot turn
    /// the keystroke into another shortcut.
    var waitForModifierRelease: @MainActor () async -> Void = PasteGuard.waitForModifiers

    /// `.clipboardChanged`, without sending, when the change count moved.
    func sendCommandV(expectingChangeCount expected: Int) -> PasteOutcome {
        guard changeCount() == expected else { return .clipboardChanged }
        return sendCommandV() ? .pasted : .failed
    }

    static func waitForModifiers() async {
        for _ in 0..<40 {
            let held = NSEvent.modifierFlags.intersection([.command, .option, .shift, .control])
            if held.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
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
