import AppKit

enum TypeToClickBadgePlacement: Equatable {
    case above
    case inside
}

/// The tone a status line carries. The controller supplies it alongside the
/// words, so the view never infers a tone by matching English copy.
enum TypeToClickStatusTone: Equatable {
    case ready
    case busy
    case alert

    var color: NSColor {
        switch self {
        case .ready: House.NSColorToken.success
        case .busy: House.NSColorToken.hudMuted
        case .alert: House.NSColorToken.danger
        }
    }
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
///
/// The HUD is painted from the house HUD tokens alone (`hudFill`, `hudStroke`,
/// `hudText`, `hudMuted`), which are the same in light and dark by design, so
/// nothing here branches on appearance.
final class TypeToClickOverlayView: NSView {
    var badges: [TypeToClickBadge] = [] {
        didSet { needsDisplay = true }
    }
    var statusText: String? {
        didSet { needsDisplay = true }
    }
    /// The tone for `statusText`'s dot, carried from the controller. Only
    /// the words change the drawn line; a caller that sets none stays ready.
    var statusTone: TypeToClickStatusTone = .ready {
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

    /// The house status dot: 6 pt, and never the only signal.
    private static let statusDotDiameter: CGFloat = 6

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

    /// Compact HUD callouts expose actual control names instead of arbitrary
    /// letter codes. The tail points to the control's click location.
    ///
    /// Three states, told apart without leaning on colour: a resting badge is
    /// a dark HUD chip in `meta`; the selected badge inverts to dark ink on
    /// the HUD's light text colour and steps up to `label`; the badge being
    /// clicked keeps that inversion and adds a `success` dot beside its name.
    private func drawBadge(_ badge: TypeToClickBadge) {
        let isEmphasised = badge.isSelected || badge.isPulsing
        let fill = isEmphasised
            ? House.NSColorToken.hudText
            : House.NSColorToken.hudFill
        let stroke = isEmphasised
            ? House.NSColorToken.hudFill
            : House.NSColorToken.hudStroke
        let displayLabel = badge.label.count > 28
            ? String(badge.label.prefix(27)) + "…"
            : badge.label
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: isEmphasised
                    ? House.TypeToken.Size.label
                    : House.TypeToken.Size.meta,
                weight: isEmphasised ? .medium : .regular
            ),
            .foregroundColor: isEmphasised
                ? House.NSColorToken.hudFill
                : House.NSColorToken.hudText,
        ]
        let string = NSAttributedString(string: displayLabel, attributes: attributes)
        let textSize = string.size()
        let horizontalPadding = House.Spacing.xs
        let verticalPadding = House.Spacing.xxs
        let dotGap = House.Spacing.xxs
        // Only the badge being clicked carries the dot; it sits beside the
        // control's own name, never alone.
        let dotBlock = badge.isPulsing ? Self.statusDotDiameter + dotGap : 0
        let edgeInset = House.Spacing.xxs
        let tailWidth = House.Spacing.xs
        let tailHeight = House.Spacing.xxs
        let chipSize = NSSize(
            width: ceil(textSize.width) + dotBlock + horizontalPadding * 2,
            height: ceil(textSize.height) + verticalPadding * 2
        )
        let proposedX = badge.rect.midX - chipSize.width / 2
        let chipX = min(
            max(bounds.minX + edgeInset, proposedX),
            max(bounds.minX + edgeInset, bounds.maxX - chipSize.width - edgeInset)
        )
        let proposedY = badge.placement == .inside
            ? badge.rect.midY - chipSize.height / 2
            : badge.rect.maxY + tailHeight
        let chipY = min(
            max(bounds.minY + tailHeight + edgeInset, proposedY),
            max(bounds.minY + tailHeight + edgeInset, bounds.maxY - chipSize.height - edgeInset)
        )
        let chip = NSRect(origin: NSPoint(x: chipX, y: chipY), size: chipSize)
        let tipX = min(max(badge.rect.midX, chip.minX + 4), chip.maxX - 4)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: tipX - tailWidth / 2, y: chip.minY + 0.5))
        tail.line(to: NSPoint(x: tipX, y: chip.minY - tailHeight))
        tail.line(to: NSPoint(x: tipX + tailWidth / 2, y: chip.minY + 0.5))
        tail.close()
        let rounded = NSBezierPath(
            roundedRect: chip,
            xRadius: AQDesign.fieldCornerRadius,
            yRadius: AQDesign.fieldCornerRadius
        )

        NSGraphicsContext.saveGraphicsState()
        // Depth comes from the house card shadow, not from stroke weight.
        // The HUD is mode-independent, so it always uses the dark opacity.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(
            House.Shadow.card.opacity(dark: true)
        )
        shadow.shadowBlurRadius = House.Shadow.card.blur / 2
        shadow.shadowOffset = NSSize(width: 0, height: -House.Shadow.card.y)
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
            tailOutline.lineWidth = House.hairline
            tailOutline.stroke()
        }
        rounded.lineWidth = House.hairline
        rounded.stroke()

        var textX = chip.minX + horizontalPadding
        if badge.isPulsing {
            let dot = NSRect(
                x: textX,
                y: chip.midY - Self.statusDotDiameter / 2,
                width: Self.statusDotDiameter,
                height: Self.statusDotDiameter
            )
            House.NSColorToken.success.setFill()
            NSBezierPath(ovalIn: dot).fill()
            textX = dot.maxX + dotGap
        }
        string.draw(at: NSPoint(x: textX, y: chip.midY - textSize.height / 2))
    }

    /// The status line: one HUD pill with a status dot and the words that
    /// explain it. Ready is `success`, work in progress is `hudMuted`, a
    /// no-match or permission line is `danger`.
    private func drawStatus(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: House.TypeToken.Size.label, weight: .medium),
            .foregroundColor: House.NSColorToken.hudText,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let horizontalPadding = House.Spacing.md
        let verticalPadding = House.Spacing.sm
        let dotGap = House.Spacing.xs
        let anchor = statusAnchor ?? NSPoint(x: bounds.midX, y: bounds.midY)
        let pillSize = NSSize(
            width: textSize.width + Self.statusDotDiameter + dotGap + horizontalPadding * 2,
            height: textSize.height + verticalPadding * 2
        )
        let pill = NSRect(
            x: anchor.x - pillSize.width / 2,
            y: anchor.y - pillSize.height / 2,
            width: pillSize.width,
            height: pillSize.height
        )
        House.NSColorToken.hudFill.setFill()
        NSBezierPath(
            roundedRect: pill,
            xRadius: AQDesign.itemCornerRadius,
            yRadius: AQDesign.itemCornerRadius
        ).fill()
        House.NSColorToken.hudStroke.setStroke()
        let border = NSBezierPath(
            roundedRect: pill,
            xRadius: AQDesign.itemCornerRadius,
            yRadius: AQDesign.itemCornerRadius
        )
        border.lineWidth = House.hairline
        border.stroke()

        let dot = NSRect(
            x: pill.minX + horizontalPadding,
            y: pill.midY - Self.statusDotDiameter / 2,
            width: Self.statusDotDiameter,
            height: Self.statusDotDiameter
        )
        statusTone.color.setFill()
        NSBezierPath(ovalIn: dot).fill()

        string.draw(at: NSPoint(
            x: dot.maxX + dotGap,
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
            keyCode: VirtualKey.escape.rawValue
        ), keyHandler?(event) == true {
            return
        }
        super.cancelOperation(sender)
    }
}
