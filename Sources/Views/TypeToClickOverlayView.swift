import AppKit

/// A hint box to draw over one on-screen element.
struct TypeToClickBox {
    let rect: NSRect        // in the overlay window's coordinate space
    let hint: String
    let matched: Bool
}

/// Draws the hint boxes and becomes first responder to capture raw key events.
final class TypeToClickOverlayView: NSView {
    var boxes: [TypeToClickBox] = [] {
        didSet { needsDisplay = true }
    }

    /// Returns true when the event was consumed. Receives unmodified keyDowns,
    /// Backspace, and Esc once this view is first responder.
    var keyHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for box in boxes {
            let color: NSColor = box.matched ? .systemYellow : .systemBlue

            let path = NSBezierPath(
                roundedRect: box.rect.insetBy(dx: -1, dy: -1),
                xRadius: 4,
                yRadius: 4
            )
            color.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 2
            path.stroke()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let string = NSAttributedString(string: box.hint, attributes: attributes)
            let textSize = string.size()
            let pill = NSRect(
                x: box.rect.minX,
                y: box.rect.maxY - textSize.height - 6,
                width: textSize.width + 10,
                height: textSize.height + 6
            )
            color.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            string.draw(at: NSPoint(x: pill.minX + 5, y: pill.minY + 3))
        }
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
