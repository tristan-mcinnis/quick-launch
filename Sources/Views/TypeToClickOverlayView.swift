import AppKit

/// Draws search status and becomes first responder to capture raw key events.
final class TypeToClickOverlayView: NSView {
    var statusText: String? {
        didSet { needsDisplay = true }
    }
    /// Panel-local point used for status messages. The controller keeps this
    /// on the display under the pointer rather than between two displays.
    var statusAnchor: NSPoint? {
        didSet { needsDisplay = true }
    }

    /// Returns true when the event was consumed. Receives unmodified keyDowns,
    /// Backspace, and Esc once this view is first responder.
    var keyHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Transparent retained windows do not reliably erase pixels that a
        // previous draw pass painted. Explicit clearing prevents old status
        // pills from ghosting into the next state or invocation.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        if let statusText {
            drawStatus(statusText)
        }
    }

    private func drawStatus(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let anchor = statusAnchor ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let pill = NSRect(
            x: anchor.x - (textSize.width + 32) / 2,
            y: anchor.y - (textSize.height + 22) / 2,
            width: textSize.width + 32,
            height: textSize.height + 22
        )
        NSColor.black.withAlphaComponent(0.84).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10).fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let border = NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10)
        border.lineWidth = 1
        border.stroke()
        string.draw(at: NSPoint(
            x: pill.midX - textSize.width / 2,
            y: pill.midY - textSize.height / 2
        ))
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc keyCode is 53; mirror it into the handler via a synthetic event.
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ), keyHandler?(event) == true {
            return
        }
        super.cancelOperation(sender)
    }
}
