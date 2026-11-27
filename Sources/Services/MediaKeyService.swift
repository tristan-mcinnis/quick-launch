import AppKit

/// The keyboard's media keys: play/pause, next and previous track.
enum MediaKey: Int32, Sendable, CaseIterable {
    // NX_KEYTYPE_* in IOKit's ev_keymap.h.
    case playPause = 16
    case next = 17
    case previous = 18
}

/// Presses a media key the way the keyboard does: a system-defined event
/// (subtype 8, aux control button) down, then up. Whatever app owns Now
/// Playing gets it, as with the real key. Posting needs the Accessibility
/// permission Quick Launch already holds for paste.
enum MediaKeyService {
    static let auxControlSubtype: Int16 = 8

    /// The event's data1: key code in the high half, then the down (0xA) or
    /// up (0xB) state. Pure, so the layout is tested.
    static func data1(for key: MediaKey, down: Bool) -> Int {
        (Int(key.rawValue) << 16) | ((down ? 0xA : 0xB) << 8)
    }

    @MainActor
    static func press(_ key: MediaKey) -> Bool {
        for down in [true, false] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: auxControlSubtype,
                data1: data1(for: key, down: down),
                data2: -1
            ), let cgEvent = event.cgEvent else { return false }
            cgEvent.post(tap: .cghidEventTap)
        }
        return true
    }
}
