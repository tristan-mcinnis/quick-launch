import AppKit
import ApplicationServices

/// Borderless panel that can still become key, so the overlay receives
/// keystrokes (same trick as KeyablePanel).
final class TypeToClickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

/// Coordinates the type-to-click overlay: full-screen transparent panel,
/// hint filtering as the user types, and the click on an exact hint match.
@MainActor
final class TypeToClickController {
    static let defaultAlphabet = "sadfjklewcmpgh"

    private let service: TypeToClickServicing
    private let panel: NSPanel
    private let overlayView = TypeToClickOverlayView()
    private let primaryTop: CGFloat

    private var targets: [TypeToClickTarget] = []
    private var typed = ""
    private var activePID: pid_t = 0

    /// Called once when the mode dismisses (after a click or Esc).
    var onDismiss: (() -> Void)?

    init(service: TypeToClickServicing = TypeToClickService()) {
        self.service = service

        // Span every connected display, not just the primary one. AX frames are
        // anchored at the primary display's top-left, so the overlay must cover
        // the full union of screen frames to draw hints on all of them.
        let screens = NSScreen.screens
        let union = screens.map(\.frame).reduce(NSRect.null) { $0.union($1) }
        primaryTop = screens.first?.frame.maxY ?? 0
        panel = TypeToClickPanel(
            contentRect: union,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true            // clicks pass through
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = overlayView

        overlayView.keyHandler = { [weak self] event in
            self?.handle(event) ?? false
        }
    }

    var isActive: Bool { panel.isVisible }

    func start(in pid: pid_t) {
        guard !isActive else { return }
        typed = ""
        activePID = pid
        targets = service.targets(in: pid, alphabet: Self.defaultAlphabet)

        // windowRect(for:) returns panel-local coordinates, so intersect against
        // the panel's local bounds (origin .zero), not its global frame.
        let panelBounds = NSRect(origin: .zero, size: panel.frame.size)
        targets = targets.filter { panelBounds.intersects(windowRect(for: $0.frame)) }
        render()

        // The app must be active for the panel to become key and receive
        // keystrokes. Activation races with makeKey() when triggered from a
        // global hotkey, so defer the key/first-responder setup one run-loop
        // turn (the launcher gets the same effect via its SwiftUI focus
        // request).
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.panel.makeKey()
            _ = self.panel.makeFirstResponder(self.overlayView)
        }
    }

    func dismiss() {
        guard isActive else { return }
        panel.orderOut(nil)
        targets = []
        typed = ""
        let pid = activePID
        activePID = 0
        onDismiss?()
        if pid != 0 {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        }
    }

    // MARK: - Key handling

    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:                                   // Esc
            dismiss()
            return true
        case 51:                                   // Delete / Backspace
            typed = String(typed.dropLast())
            render()
            return true
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased(),
                  character.count == 1,
                  character.first?.isLetter == true || character.first?.isNumber == true
            else { return false }
            type(character)
            return true
        }
    }

    private func type(_ character: String) {
        typed += character
        render()
        if let exact = targets.first(where: { $0.hint == typed }) {
            service.press(exact)
            dismiss()
        }
    }

    // MARK: - Rendering

    private func render() {
        let matches = targets.filter { $0.hint.hasPrefix(typed) }
        overlayView.boxes = targets.map { target in
            TypeToClickBox(
                rect: windowRect(for: target.frame),
                hint: target.hint,
                matched: matches.contains { $0.hint == target.hint }
            )
        }
    }

    /// Converts an AX frame (global top-left origin, y down) to overlay-panel
    /// coordinates (bottom-left origin of the union of screens, y up).
    private func windowRect(for axFrame: CGRect) -> NSRect {
        // AX global -> AppKit global (y flipped around the primary top).
        let appKitX = axFrame.minX
        let appKitY = primaryTop - axFrame.minY - axFrame.height
        // AppKit global -> panel-local.
        return NSRect(
            x: appKitX - panel.frame.minX,
            y: appKitY - panel.frame.minY,
            width: axFrame.width,
            height: axFrame.height
        )
    }
}
