import AppKit

/// A hint box to draw over one on-screen element.
struct TypeToClickBox {
    let rect: NSRect        // in the overlay window's coordinate space
    let hint: String
}

/// Draws the hint boxes and becomes first responder to capture raw key events.
final class TypeToClickOverlayView: NSView {
    var boxes: [TypeToClickBox] = [] {
        didSet { needsDisplay = true }
    }
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
        // previous draw pass painted. Explicit clearing prevents loading pills
        // and old hint boxes from ghosting into the next state or invocation.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        if let statusText {
            drawStatus(statusText)
        }
        for box in boxes {
            drawHint(box)
        }
    }

    /// Homerow's original labels are compact gold callouts. They identify the
    /// click point without washing the app in coloured target outlines.
    private func drawHint(_ box: TypeToClickBox) {
        let fill = NSColor(srgbRed: 0.97, green: 0.77, blue: 0.02, alpha: 1)
        let stroke = NSColor(srgbRed: 0.43, green: 0.31, blue: 0.01, alpha: 0.72)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 0.08, green: 0.07, blue: 0.03, alpha: 1),
        ]
        let string = NSAttributedString(string: box.hint.uppercased(), attributes: attributes)
        let textSize = string.size()
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 3
        let tailWidth: CGFloat = 7
        let tailHeight: CGFloat = 4
        let chipSize = NSSize(
            width: ceil(textSize.width) + horizontalPadding * 2,
            height: ceil(textSize.height) + verticalPadding * 2
        )
        let proposedX = box.rect.midX - chipSize.width / 2
        let chipX = min(
            max(bounds.minX + 2, proposedX),
            max(bounds.minX + 2, bounds.maxX - chipSize.width - 2)
        )
        let proposedY = box.rect.maxY + tailHeight
        let chipY = min(
            max(bounds.minY + tailHeight + 2, proposedY),
            max(bounds.minY + tailHeight + 2, bounds.maxY - chipSize.height - 2)
        )
        let chip = NSRect(origin: NSPoint(x: chipX, y: chipY), size: chipSize)
        let tipX = min(max(box.rect.midX, chip.minX + 4), chip.maxX - 4)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: tipX - tailWidth / 2, y: chip.minY + 0.5))
        tail.line(to: NSPoint(x: tipX, y: chip.minY - tailHeight))
        tail.line(to: NSPoint(x: tipX + tailWidth / 2, y: chip.minY + 0.5))
        tail.close()
        let rounded = NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        fill.setFill()
        tail.fill()
        rounded.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Stroke only the tail's two exposed edges. Closing and stroking the
        // triangle would leave a dark seam across the gold callout.
        let tailOutline = NSBezierPath()
        tailOutline.move(to: NSPoint(x: tipX - tailWidth / 2, y: chip.minY + 0.5))
        tailOutline.line(to: NSPoint(x: tipX, y: chip.minY - tailHeight))
        tailOutline.line(to: NSPoint(x: tipX + tailWidth / 2, y: chip.minY + 0.5))
        stroke.setStroke()
        tailOutline.lineWidth = 0.75
        tailOutline.stroke()
        rounded.lineWidth = 0.75
        rounded.stroke()
        string.draw(at: NSPoint(
            x: chip.midX - textSize.width / 2,
            y: chip.midY - textSize.height / 2
        ))
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
