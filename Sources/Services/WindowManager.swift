import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol WindowManaging: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    func apply(_ layout: WindowLayout, to target: SelectionTarget) -> Bool
}

@MainActor
final class WindowManager: WindowManaging {
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func apply(_ layout: WindowLayout, to target: SelectionTarget) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue,
        CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return false }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        guard let screenFrame = screenFrame(containing: window) else { return false }
        let unit = layout.normalizedFrame
        var position = CGPoint(
            x: screenFrame.minX + screenFrame.width * unit.minX,
            y: screenFrame.minY + screenFrame.height * unit.minY
        )
        var size = CGSize(
            width: screenFrame.width * unit.width,
            height: screenFrame.height * unit.height
        )
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

    private func screenFrame(containing window: AXUIElement) -> CGRect? {
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
        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        let screen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber else { return false }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value)).contains(center)
        } ?? NSScreen.main
        guard let screen else { return nil }
        // Accessibility uses a top-left global coordinate space. Convert the
        // AppKit visible frame so layouts avoid the menu bar and Dock.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: screen.visibleFrame.minX,
            y: primaryTop - screen.visibleFrame.maxY,
            width: screen.visibleFrame.width,
            height: screen.visibleFrame.height
        )
    }
}
