import AppKit

/// macOS virtual key codes the overlay dispatches on. One place for the
/// magic numbers so no handler re-declares `53` for Escape.
enum VirtualKey: UInt16, Sendable {
    case `return` = 36
    case tab = 48
    case delete = 51
    case escape = 53
    case keypadEnter = 76
    case pageUp = 116
    case pageDown = 121
    case leftArrow = 123
    case rightArrow = 124
    case downArrow = 125
    case upArrow = 126

    init?(event: NSEvent) {
        self.init(rawValue: event.keyCode)
    }

    /// Return and keypad Enter both submit.
    var isReturn: Bool { self == .return || self == .keypadEnter }

    static func isReturn(keyCode: UInt16) -> Bool {
        VirtualKey(rawValue: keyCode)?.isReturn == true
    }
}

extension NSEvent.ModifierFlags {
    /// Modifier flags with the noise (fn, keypad, caps lock) removed, so
    /// comparisons such as `== [.command]` are exact.
    var overlayRelevant: NSEvent.ModifierFlags {
        intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
    }
}
