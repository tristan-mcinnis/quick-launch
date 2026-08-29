import AppKit

enum TypeToClickBadgePlacement: Equatable {
    case above
    case inside
}

/// A named callout anchored to one clickable control.
struct TypeToClickBadge: Equatable {
    let rect: NSRect        // in the overlay window's coordinate space
    let label: String
    let isSelected: Bool
    let isPulsing: Bool
    var placement: TypeToClickBadgePlacement = .above
}

/// Draws named target badges and search status, and captures raw key events.
final class TypeToClickOverlayView: NSView {
    var badges: [TypeToClickBadge] = [] {
        didSet { needsDisplay = true }
    }
    var statusText: String? {
        didSet { needsDisplay = true }
    }
    /// Panel-local point used for status messages. The controller places it
    /// near the bottom of the chosen display, away from top-edge app menus.
    var statusAnchor: NSPoint? {
        didSet { needsDisplay = true }
    }

    /// Returns true when the event was consumed. Receives unmodified keyDowns,
    /// Backspace, and Esc once this view is first responder.
    var keyHandler: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Transparent retained windows do not reliably erase pixels that a
        // previous draw pass painted. Explicit clearing prevents old badges or
        // status pills from ghosting into the next state or invocation.
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        for badge in badges {
            drawBadge(badge)
        }
        if let statusText {
            drawStatus(statusText)
        }
    }

    /// Compact gold callouts expose actual control names instead of arbitrary
    /// letter codes. The tail points to the control's click location.
    private func drawBadge(_ badge: TypeToClickBadge) {
        let fill = badge.isPulsing
            ? NSColor.white
            : NSColor(srgbRed: 0.97, green: 0.77, blue: 0.02, alpha: 0.96)
        let stroke = badge.isPulsing
            ? NSColor(srgbRed: 0.12, green: 0.78, blue: 0.32, alpha: 1)
            : badge.isSelected
                ? NSColor(srgbRed: 0.08, green: 0.07, blue: 0.03, alpha: 0.98)
                : NSColor(srgbRed: 0.43, green: 0.31, blue: 0.01, alpha: 0.72)
        let displayLabel = badge.label.count > 28
            ? String(badge.label.prefix(27)) + "…"
            : badge.label
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: badge.isPulsing ? 13 : 12,
                weight: .semibold
            ),
            .foregroundColor: NSColor(srgbRed: 0.08, green: 0.07, blue: 0.03, alpha: 1),
        ]
        let string = NSAttributedString(string: displayLabel, attributes: attributes)
        let textSize = string.size()
        let horizontalPadding: CGFloat = badge.isPulsing ? 9 : 7
        let verticalPadding: CGFloat = badge.isPulsing ? 5 : 3
        let tailWidth: CGFloat = 7
        let tailHeight: CGFloat = 4
        let chipSize = NSSize(
            width: ceil(textSize.width) + horizontalPadding * 2,
            height: ceil(textSize.height) + verticalPadding * 2
        )
        let proposedX = badge.rect.midX - chipSize.width / 2
        let chipX = min(
            max(bounds.minX + 2, proposedX),
            max(bounds.minX + 2, bounds.maxX - chipSize.width - 2)
        )
        let proposedY = badge.placement == .inside
            ? badge.rect.midY - chipSize.height / 2
            : badge.rect.maxY + tailHeight
        let chipY = min(
            max(bounds.minY + tailHeight + 2, proposedY),
            max(bounds.minY + tailHeight + 2, bounds.maxY - chipSize.height - 2)
        )
        let chip = NSRect(origin: NSPoint(x: chipX, y: chipY), size: chipSize)
        let tipX = min(max(badge.rect.midX, chip.minX + 4), chip.maxX - 4)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: tipX - tailWidth / 2, y: chip.minY + 0.5))
        tail.line(to: NSPoint(x: tipX, y: chip.minY - tailHeight))
        tail.line(to: NSPoint(x: tipX + tailWidth / 2, y: chip.minY + 0.5))
        tail.close()
        let rounded = NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = badge.isPulsing
            ? NSColor(srgbRed: 0.12, green: 0.78, blue: 0.32, alpha: 0.95)
            : NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = badge.isPulsing ? 10 : 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        fill.setFill()
        if badge.placement == .above { tail.fill() }
        rounded.fill()
        NSGraphicsContext.restoreGraphicsState()

        let tailOutline = NSBezierPath()
        tailOutline.move(to: NSPoint(x: tipX - tailWidth / 2, y: chip.minY + 0.5))
        tailOutline.line(to: NSPoint(x: tipX, y: chip.minY - tailHeight))
        tailOutline.line(to: NSPoint(x: tipX + tailWidth / 2, y: chip.minY + 0.5))
        stroke.setStroke()
        if badge.placement == .above {
            tailOutline.lineWidth = badge.isSelected || badge.isPulsing ? 1.5 : 0.75
            tailOutline.stroke()
        }
        rounded.lineWidth = badge.isPulsing ? 3 : (badge.isSelected ? 2 : 0.75)
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
