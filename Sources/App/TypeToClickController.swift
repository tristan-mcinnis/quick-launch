import AppKit
import ApplicationServices

/// Borderless panel that can still become key, so the overlay receives
/// keystrokes without activating the app behind it (same trick as KeyablePanel).
final class TypeToClickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Coordinates the type-to-click overlay: full-screen transparent panel,
/// hint filtering as the user types, and the click on an exact hint match.
@MainActor
final class TypeToClickController {
    static let defaultAlphabet = "sadfjklewcmpgh"

    private let service: TypeToClickServicing
    private let panel: NSPanel
    private let overlayView = TypeToClickOverlayView()

    private var targets: [TypeToClickTarget] = []
    private var typed = ""

    /// Called once when the mode dismisses (after a click, Esc, or release).
    var onDismiss: (() -> Void)?

    init(service: TypeToClickServicing = TypeToClickService()) {
        self.service = service

        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = TypeToClickPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
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
        targets = service.targets(in: pid, alphabet: Self.defaultAlphabet)
        targets = targets.filter { panel.frame.intersects(windowRect(for: $0.frame)) }
        render()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(overlayView)
    }

    func dismiss() {
        guard isActive else { return }
        panel.orderOut(nil)
        targets = []
        typed = ""
        onDismiss?()
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

    /// Converts an AX frame (top-left global origin, y down) to overlay-window
    /// coordinates (bottom-left origin, y up) on the primary screen.
    private func windowRect(for axFrame: CGRect) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: axFrame.size)
        }
        let height = screen.frame.height
        return NSRect(
            x: axFrame.minX - screen.frame.minX,
            y: height - axFrame.minY - axFrame.height + screen.frame.minY,
            width: axFrame.width,
            height: axFrame.height
        )
    }
}
