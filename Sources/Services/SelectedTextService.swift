import AppKit
import ApplicationServices
import Foundation

struct SelectionTarget: Sendable, Equatable {
    let processIdentifier: pid_t
    let applicationName: String
}

struct SelectedTextContext: Sendable, Equatable {
    let target: SelectionTarget
    let text: String
}

@MainActor
protocol SelectedTextServicing: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    func currentExternalTarget() -> SelectionTarget?
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext?
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool
    func openAccessibilitySettings()
}

@MainActor
final class SelectedTextService: SelectedTextServicing {
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    private var lastTarget: SelectionTarget?
    private var activationObserver: NSObjectProtocol?

    init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        rememberIfExternal(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            Task { @MainActor in self?.rememberIfExternal(app) }
        }
    }

    func currentExternalTarget() -> SelectionTarget? {
        rememberIfExternal(NSWorkspace.shared.frontmostApplication)
        return lastTarget
    }

    private func rememberIfExternal(_ app: NSRunningApplication?) {
        guard let app,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastTarget = SelectionTarget(
            processIdentifier: app.processIdentifier,
            applicationName: app.localizedName ?? app.bundleIdentifier ?? "Previous app"
        )
    }

    func capture(
        from target: SelectionTarget,
        promptForPermission: Bool
    ) -> SelectedTextContext? {
        let options = ["AXTrustedCheckOptionPrompt": promptForPermission] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return nil }

        let application = AXUIElementCreateApplication(target.processIdentifier)
        guard let focused = focusedElement(in: application) else { return nil }
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
        let text = selectedValue as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SelectedTextContext(target: target, text: text)
    }

    func replace(_ text: String, in context: SelectedTextContext) async -> Bool {
        guard !text.isEmpty, AXIsProcessTrusted() else { return false }
        let application = AXUIElementCreateApplication(context.target.processIdentifier)

        if let focused = focusedElement(in: application) {
            var settable = DarwinBoolean(false)
            let checked = AXUIElementIsAttributeSettable(
                focused,
                kAXSelectedTextAttribute as CFString,
                &settable
            )
            if checked == .success,
               settable.boolValue,
               AXUIElementSetAttributeValue(
                   focused,
                   kAXSelectedTextAttribute as CFString,
                   text as CFString
               ) == .success {
                activate(context.target)
                return true
            }
        }

        return await paste(text, to: context.target)
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func focusedElement(in application: AXUIElement) -> AXUIElement? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue,
        CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(focusedValue, to: AXUIElement.self)
    }

    private func activate(_ target: SelectionTarget) {
        NSRunningApplication(processIdentifier: target.processIdentifier)?
            .activate(from: .current, options: [.activateAllWindows])
    }

    private func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        let previousText = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        app.activate(from: .current, options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(220))

        for _ in 0..<40 {
            let held = NSEvent.modifierFlags.intersection([.command, .option, .shift, .control])
            if held.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: false
        ) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        try? await Task.sleep(for: .milliseconds(450))
        if pasteboard.string(forType: .string) == text, let previousText {
            pasteboard.clearContents()
            pasteboard.setString(previousText, forType: .string)
        }
        return true
    }
}
