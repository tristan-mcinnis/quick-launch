import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol WindowManaging: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    func apply(_ layout: WindowLayout, to target: SelectionTarget) -> Bool
    func move(_ move: WindowMove, target: SelectionTarget) -> Bool
}

/// Resizes the window that was actually on top behind Quick Launch.
///
/// Accuracy notes, learned the hard way:
/// - The app's "focused" window is not always the one on top. The window
///   is chosen by matching the on-screen window list, focused as fallback.
/// - Chromium and Electron apps (Helium, Slack, VS Code) resize wrongly or
///   not at all while `AXEnhancedUserInterface` is on. It is switched off
///   for the duration of the change and restored afterwards.
/// - Size is set before position and again after it, because apps clamp
///   the size to their minimum and shift the origin while doing so.
/// - Repeating Left or Right Half cycles half → two thirds → third.
@MainActor
final class WindowManager: WindowManaging {
    private struct Applied {
        let windowNumber: Int
        let layout: WindowLayout?
        let frame: CGRect
        let previous: CGRect
        let date: Date
    }

    private var lastApplied: Applied?
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func apply(_ layout: WindowLayout, to target: SelectionTarget) -> Bool {
        guard let (window, number) = topWindow(of: target),
              let current = frame(of: window),
              let screen = screenFrame(containing: current)
        else { return false }
        let resolved = WindowCycling.next(
            requested: layout,
            lastLayout: lastApplied?.windowNumber == number ? lastApplied?.layout : nil,
            lastFrame: lastApplied?.windowNumber == number ? lastApplied?.frame : nil,
            current: current
        )
        let frame = resolved.frame(in: screen)
        return set(frame, on: window, number: number, layout: resolved, previous: current, target: target)
    }

    func move(_ move: WindowMove, target: SelectionTarget) -> Bool {
        guard let (window, number) = topWindow(of: target),
              let current = frame(of: window)
        else { return false }
        switch move {
        case .nextDisplay, .previousDisplay:
            let screens = NSScreen.screens.map(accessibilityFrame(for:))
            guard screens.count > 1 else { return false }
            let center = CGPoint(x: current.midX, y: current.midY)
            let index = screens.firstIndex { $0.contains(center) } ?? 0
            let destination = screens[move.targetIndex(current: index, count: screens.count)]
            let frame = WindowMove.relocatedFrame(window: current, from: screens[index], to: destination)
            return set(frame, on: window, number: number, layout: nil, previous: current, target: target)
        case .restore:
            guard let last = lastApplied, last.windowNumber == number else { return false }
            return set(last.previous, on: window, number: number, layout: nil, previous: current, target: target)
        case .toggleFullScreen:
            var value: CFTypeRef?
            let isFull = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success
                && (value as? Bool) == true
            let result = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, (!isFull) as CFBoolean)
            activate(target)
            return result == .success
        default:
            guard let screen = screenFrame(containing: current),
                  let frame = move.adjustedFrame(window: current, screen: screen)
            else { return false }
            return set(frame, on: window, number: number, layout: nil, previous: current, target: target)
        }
    }

    // MARK: - Window lookup

    /// The app's window nearest the top of the on-screen stack, matched by
    /// frame to an Accessibility window; the focused window as fallback.
    private func topWindow(of target: SelectionTarget) -> (AXUIElement, Int)? {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return nil }
        let application = AXUIElementCreateApplication(target.processIdentifier)

        var windowsValue: CFTypeRef?
        let axWindows = (AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success)
            ? (windowsValue as? [AXUIElement]) ?? []
            : []

        if let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in onScreen {
                guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.processIdentifier,
                      (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                      let bounds = info[kCGWindowBounds as String] as? [String: Any],
                      let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                      let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat,
                      width > 80, height > 40
                else { continue }
                let cgFrame = CGRect(x: x, y: y, width: width, height: height)
                if let match = axWindows.first(where: { element in
                    guard let frame = frame(of: element) else { return false }
                    return abs(frame.minX - cgFrame.minX) < 2 && abs(frame.minY - cgFrame.minY) < 2
                        && abs(frame.width - cgFrame.width) < 2 && abs(frame.height - cgFrame.height) < 2
                }) {
                    return (match, number)
                }
            }
        }

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return axWindows.first.map { ($0, 0) } }
        return (unsafeDowncast(focusedValue, to: AXUIElement.self), 0)
    }

    // MARK: - Setting frames

    private func set(
        _ frame: CGRect,
        on window: AXUIElement,
        number: Int,
        layout: WindowLayout?,
        previous: CGRect,
        target: SelectionTarget
    ) -> Bool {
        let application = AXUIElementCreateApplication(target.processIdentifier)
        let enhanced = enhancedUserInterface(of: application)
        if enhanced { setEnhancedUserInterface(false, on: application) }
        defer { if enhanced { setEnhancedUserInterface(true, on: application) } }

        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else { return false }

        // Size first (so the window can fit where it is going), then position,
        // then size again (apps that hit their minimum size shift the origin).
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        let positioned = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success
        let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
        if let result = self.frame(of: window), abs(result.minX - frame.minX) > 2 || abs(result.minY - frame.minY) > 2 {
            _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
        let final = self.frame(of: window) ?? frame
        lastApplied = Applied(windowNumber: number, layout: layout, frame: final, previous: previous, date: Date())
        activate(target)
        return positioned && sized
    }

    private func activate(_ target: SelectionTarget) {
        NSRunningApplication(processIdentifier: target.processIdentifier)?
            .activate(from: .current, options: [.activateAllWindows])
    }

    private func enhancedUserInterface(of application: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXEnhancedUserInterface" as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) == true
    }

    private func setEnhancedUserInterface(_ enabled: Bool, on application: AXUIElement) {
        _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, enabled as CFBoolean)
    }

    // MARK: - Geometry

    /// The window's frame in the Accessibility (top-left origin) space.
    private func frame(of window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
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

    /// The visible frame of the display that holds most of `windowFrame`.
    private func screenFrame(containing windowFrame: CGRect) -> CGRect? {
        let candidates = NSScreen.screens.map { (screen: $0, frame: accessibilityFrame(for: $0)) }
        guard !candidates.isEmpty else { return nil }
        let best = candidates.max { lhs, rhs in
            lhs.frame.intersection(windowFrame).area < rhs.frame.intersection(windowFrame).area
        }
        if let best, best.frame.intersection(windowFrame).area > 0 { return best.frame }
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return candidates.first { $0.frame.contains(center) }?.frame ?? candidates.first?.frame
    }

    /// Accessibility uses a top-left global coordinate space anchored on the
    /// primary display. Convert the AppKit visible frame so layouts avoid the
    /// menu bar and Dock on every display.
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

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
