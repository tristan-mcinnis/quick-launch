import AppKit
import ApplicationServices
import Foundation
import OSLog

struct SelectionTarget: Sendable, Equatable {
    let processIdentifier: pid_t
    let applicationName: String
}

struct SelectedTextContext: Sendable, Equatable {
    let target: SelectionTarget
    let text: String
}

@MainActor
final class SelectedTextService: SelectedTextServicing {
    private let logger = Logger(
        subsystem: "com.tristanmcinnis.quick-launch",
        category: "ExternalAction"
    )
    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }
    private var lastTarget: SelectionTarget?
    private var activationObserver: NSObjectProtocol?
    private let pasteGuard: PasteGuard

    /// Bounded AX messaging wait, in seconds, so an unresponsive target app
    /// cannot hang the panel while Quick Launch reads or replaces a selection.
    /// AX calls are synchronous and cannot be cancelled mid-call, so the
    /// messaging timeout is the supported lever. The launch-time selection
    /// read must stay on the main thread: the panel takes focus immediately
    /// after, so deferring the read off-main would race the focus steal and
    /// read the wrong (or no) selection.
    nonisolated static let axMessagingTimeout: Float = 0.15

    init(pasteGuard: PasteGuard = PasteGuard()) {
        self.pasteGuard = pasteGuard
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
        if let stacked = closestExternalWindowTarget() {
            lastTarget = stacked
            return stacked
        }
        rememberIfExternal(NSWorkspace.shared.frontmostApplication)
        return lastTarget
    }

    /// Resolve the first normal application window beneath Quick Launch in the
    /// WindowServer stack. This is more reliable than activation notifications,
    /// which can be displaced by menu extras and helper applications.
    private func closestExternalWindowTarget() -> SelectionTarget? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber,
                  pidNumber.int32Value != ownPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? NSNumber)?.doubleValue ?? 0 > 80,
                  (bounds["Height"] as? NSNumber)?.doubleValue ?? 0 > 40,
                  let app = NSRunningApplication(processIdentifier: pidNumber.int32Value),
                  !app.isTerminated,
                  app.activationPolicy == .regular
            else { continue }
            return SelectionTarget(
                processIdentifier: app.processIdentifier,
                applicationName: app.localizedName ?? app.bundleIdentifier ?? "Previous app"
            )
        }
        return nil
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
        // Bound every AX read here so a hung app returns quickly rather than
        // blocking the launch-time capture (see `axMessagingTimeout`).
        AXUIElementSetMessagingTimeout(application, Self.axMessagingTimeout)
        guard let focused = focusedElement(in: application) else { return nil }
        AXUIElementSetMessagingTimeout(focused, Self.axMessagingTimeout)
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
        await replaceOutcome(text, in: context) == .pasted
    }

    func replaceOutcome(_ text: String, in context: SelectedTextContext) async -> PasteOutcome {
        guard !text.isEmpty, AXIsProcessTrusted() else { return .failed }
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
                return .pasted
            }
        }

        return await pasteOutcome(text, to: context.target)
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func focusedElement(in application: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(application, Self.axMessagingTimeout)
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

    func pastePasteboard(to target: SelectionTarget) async -> Bool {
        await pastePasteboardOutcome(to: target) == .pasted
    }

    func pastePasteboardOutcome(to target: SelectionTarget) async -> PasteOutcome {
        // The caller wrote the clipboard just before this call.
        let expectedChangeCount = pasteGuard.changeCount()
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options),
              let app = NSRunningApplication(processIdentifier: target.processIdentifier)
        else { return .failed }
        app.activate(from: .current, options: [.activateAllWindows])
        var becameFrontmost = false
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                becameFrontmost = true
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard becameFrontmost else { return .failed }
        return await commandVAfterSettling(expectingChangeCount: expectedChangeCount)
    }

    /// Waits for modifier keys to lift, then sends Command-V unless the
    /// clipboard changed meanwhile.
    func commandVAfterSettling(expectingChangeCount expected: Int) async -> PasteOutcome {
        await pasteGuard.waitForModifierRelease()
        return commandVOutcome(expectingChangeCount: expected)
    }

    /// The guarded keystroke, with one log line per way it can not happen
    /// (never the clipboard text).
    func commandVOutcome(expectingChangeCount expected: Int) -> PasteOutcome {
        let outcome = pasteGuard.sendCommandV(expectingChangeCount: expected)
        switch outcome {
        case .pasted: break
        case .clipboardChanged:
            logger.error("Paste skipped: the clipboard changed after Quick Launch wrote it")
        case .failed:
            logger.error("Could not synthesise Command-V")
        }
        return outcome
    }

    func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        await pasteOutcome(text, to: target) == .pasted
    }

    func pasteOutcome(_ text: String, to target: SelectionTarget) async -> PasteOutcome {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            logger.error("Paste blocked: Accessibility permission is not granted")
            return .failed
        }
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            logger.error("Paste target is no longer running: \(target.applicationName, privacy: .public)")
            return .failed
        }
        logger.info("Paste requested for \(target.applicationName, privacy: .public)")
        app.activate(from: .current, options: [.activateAllWindows])
        var becameFrontmost = false
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == target.processIdentifier {
                becameFrontmost = true
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard becameFrontmost else {
            let actual = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
            logger.error(
                "Paste target did not become frontmost; frontmost is \(actual, privacy: .public)"
            )
            return .failed
        }

        // The text lands on the clipboard first, so whatever happens next the
        // content is one manual Command-V away and never silently lost. The
        // transient marker tells clipboard managers (ours included) that this
        // is paste plumbing, not a deliberate copy: without it every paste
        // reshuffled the history and stamped the entry with a fresh time.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes(
            [.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")],
            owner: nil
        )
        pasteboard.setString(text, forType: .string)
        let expectedChangeCount = pasteGuard.changeCount()

        await pasteGuard.waitForModifierRelease()

        // Fast path: accessibility insertion at the caret, no keystrokes.
        if insertAtCaret(text, processIdentifier: target.processIdentifier) { return .pasted }
        // Fallback: a synthesised Command-V into the now-frontmost app.
        let outcome = commandVOutcome(expectingChangeCount: expectedChangeCount)
        if outcome == .pasted { logger.info("Paste completed by Command-V fallback") }
        return outcome
    }

    /// Sets the caret text through Accessibility and verifies the write took:
    /// some apps report the attribute as settable and then drop it, which used
    /// to report a paste that never happened.
    private func insertAtCaret(_ text: String, processIdentifier: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let focused = focusedElement(in: application) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success,
        settable.boolValue,
        AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
        else { return false }

        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success, let value = valueRef as? String, !value.contains(text) {
            logger.error("The app dropped the accessibility insertion; using Command-V instead")
            return false
        }
        logger.info("Paste completed by Accessibility insertion")
        return true
    }
}
