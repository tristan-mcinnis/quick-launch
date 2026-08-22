import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol WindowManaging: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    func apply(_ layout: WindowLayout, to target: SelectionTarget) -> Bool
    func move(_ move: WindowMove, target: SelectionTarget) -> Bool
}

@MainActor
final class WindowManager: WindowManaging {
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func apply(_ layout: WindowLayout, to target: SelectionTarget) -> Bool {
        guard let window = focusedWindow(of: target),
              let screenFrame = screenFrame(containing: window)
        else { return false }
        let unit = layout.normalizedFrame
        let frame = CGRect(
            x: screenFrame.minX + screenFrame.width * unit.minX,
            y: screenFrame.minY + screenFrame.height * unit.minY,
            width: screenFrame.width * unit.width,
            height: screenFrame.height * unit.height
        )
        return set(frame, on: window, target: target)
    }

    func move(_ move: WindowMove, target: SelectionTarget) -> Bool {
        guard let window = focusedWindow(of: target),
              let windowFrame = frame(of: window)
        else { return false }
        let screens = NSScreen.screens.map(accessibilityFrame(for:))
        guard screens.count > 1 else { return false }
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        let current = screens.firstIndex { $0.contains(center) } ?? 0
        let source = screens[current]
        let destination = screens[move.targetIndex(current: current, count: screens.count)]
        let frame = WindowMove.relocatedFrame(window: windowFrame, from: source, to: destination)
        return set(frame, on: window, target: target)
    }

    private func focusedWindow(of target: SelectionTarget) -> AXUIElement? {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return nil }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue,
        CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(windowValue, to: AXUIElement.self)
    }

    private func set(_ frame: CGRect, on window: AXUIElement, target: SelectionTarget) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }
        let positioned = AXUIElementSetAttributeValue(
            window, kAXPositionAttribute as CFString, positionValue
        ) == .success
        let sized = AXUIElementSetAttributeValue(
            window, kAXSizeAttribute as CFString, sizeValue
        ) == .success
        // Some applications constrain size by shifting the origin, so restore it.
        if sized {
            _ = AXUIElementSetAttributeValue(
                window, kAXPositionAttribute as CFString, positionValue
            )
        }
        NSRunningApplication(processIdentifier: target.processIdentifier)?
            .activate(from: .current, options: [.activateAllWindows])
        return positioned && sized
    }

    /// The window's frame in the Accessibility (top-left origin) space.
    private func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &positionRef
        ) == .success,
        AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &sizeRef
        ) == .success,
        let positionRef, let sizeRef,
        CFGetTypeID(positionRef) == AXValueGetTypeID(),
        CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionRef, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeRef, to: AXValue.self), .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func screenFrame(containing window: AXUIElement) -> CGRect? {
        guard let windowFrame = frame(of: window) else { return nil }
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber else { return false }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value)).contains(center)
        } ?? NSScreen.main
        guard let screen else { return nil }
        return accessibilityFrame(for: screen)
    }

    /// Accessibility uses a top-left global coordinate space. Convert the
    /// AppKit visible frame so layouts avoid the menu bar and Dock.
    private func accessibilityFrame(for screen: NSScreen) -> CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: screen.visibleFrame.minX,
            y: primaryTop - screen.visibleFrame.maxY,
            width: screen.visibleFrame.width,
            height: screen.visibleFrame.height
        )
    }
}
