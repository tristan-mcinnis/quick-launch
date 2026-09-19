import AppKit
import Carbon.HIToolbox

/// A permission-free process-owned global shortcut.
///
/// `NSEvent.addGlobalMonitorForEvents` needs Input Monitoring permission and silently receives
/// nothing when that permission has not been granted. Carbon hot keys are the native API for a
/// discrete shortcut and do not require keyboard monitoring access.
@MainActor
final class GlobalHotKey {
    private final class WeakBox {
        weak var value: GlobalHotKey?
        init(_ value: GlobalHotKey) { self.value = value }
    }

    private static let signature: OSType = 0x4150_4651 // APFQ
    private static var nextIdentifier: UInt32 = 1
    private static var sharedHandler: EventHandlerRef?
    private static var registry: [UInt32: WeakBox] = [:]

    private var hotKeyRef: EventHotKeyRef?
    private let action: () -> Void
    private let identifier: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1

        guard Self.installSharedHandler() else { return nil }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        guard RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        ) == noErr else { return nil }

        Self.registry = Self.registry.filter { $0.value.value != nil }
        Self.registry[identifier] = WeakBox(self)
    }

    func invalidate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        Self.registry[identifier] = nil
    }

    /// A hot key that is only dropped, never invalidated, still unregisters.
    /// `isolated` keeps the main-actor state (`hotKeyRef`, the shared
    /// registry) reachable from the deinitializer under Swift 6.
    isolated deinit {
        invalidate()
    }

    nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    private static func installSharedHandler() -> Bool {
        if sharedHandler != nil { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        return InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var pressed = EventHotKeyID()
                guard GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                ) == noErr else { return OSStatus(eventNotHandledErr) }

                return MainActor.assumeIsolated {
                    guard let hotKey = GlobalHotKey.registry[pressed.id]?.value else {
                        return OSStatus(eventNotHandledErr)
                    }
                    hotKey.action()
                    return noErr
                }
            },
            1,
            &eventType,
            nil,
            &sharedHandler
        ) == noErr
    }
}
