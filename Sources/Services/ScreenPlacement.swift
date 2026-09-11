import CoreGraphics

enum ScreenPlacement {
    /// The air kept between a panel and the edges of the display's visible
    /// frame. Also the Quick AI surface's limit: it can be dragged as large
    /// as the visible frame less this margin on every side.
    static let edgeMargin: CGFloat = 12

    /// Bottom-left origin for a panel whose input row should sit on the
    /// display's visual centre line. The panel grows downward from there.
    static func panelOrigin(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        panelWidth: CGFloat,
        inputHeight: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: (screenFrame.midX - panelWidth / 2).rounded(),
            y: (visibleFrame.midY - inputHeight / 2).rounded()
        )
    }

    /// Keeps the whole panel inside the visible frame. Oversized panels shrink
    /// before they move, so their scrollable content and pinned footer remain
    /// reachable on short or narrow displays. `margin` keeps a little air.
    static func clamped(frame: CGRect, within visibleFrame: CGRect, margin: CGFloat = edgeMargin) -> CGRect {
        var result = frame
        let availableWidth = max(1, visibleFrame.width - margin * 2)
        let availableHeight = max(1, visibleFrame.height - margin * 2)
        result.size.width = min(result.width, availableWidth)
        result.size.height = min(result.height, availableHeight)

        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - margin
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - margin
        if result.minX < minX { result.origin.x = minX }
        if result.maxX > maxX { result.origin.x = maxX - result.width }
        if result.minY < minY { result.origin.y = minY }
        if result.maxY > maxY { result.origin.y = maxY - result.height }
        return result
    }

    /// The top edge a panel keeps for its whole visible life: the input row
    /// on the centre line, pulled down only if the tallest panel would not
    /// fit above the bottom margin. Computed once per show so later growth
    /// never moves the search field.
    static func anchoredTop(
        visibleFrame: CGRect,
        inputHeight: CGFloat,
        margin: CGFloat = edgeMargin
    ) -> CGFloat {
        let centred = (visibleFrame.midY + inputHeight / 2).rounded()
        return min(centred, visibleFrame.maxY - margin)
    }

    /// A frame hung from `top`: the height is capped so the bottom stays
    /// above the margin, and only the bottom edge moves as content changes.
    ///
    /// `risingToFit` is for a surface the user sized (Quick AI): when it is
    /// taller than the room under `top`, the top edge rises just enough to
    /// fit it, never past the top margin, instead of cutting its height.
    /// Root search keeps the fixed top, so its field never moves.
    static func frameHanging(
        from top: CGFloat,
        height: CGFloat,
        width: CGFloat,
        centreX: CGFloat,
        within visibleFrame: CGRect,
        margin: CGFloat = edgeMargin,
        risingToFit: Bool = false
    ) -> CGRect {
        var top = top
        if risingToFit, height > top - (visibleFrame.minY + margin) {
            top = min(visibleFrame.maxY - margin, visibleFrame.minY + margin + height)
        }
        let maxHeight = max(1, top - (visibleFrame.minY + margin))
        let clampedHeight = min(height, maxHeight)
        var result = CGRect(
            x: (centreX - width / 2).rounded(),
            y: top - clampedHeight,
            width: width,
            height: clampedHeight
        )
        let availableWidth = max(1, visibleFrame.width - margin * 2)
        result.size.width = min(result.width, availableWidth)
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - margin
        if result.minX < minX { result.origin.x = minX }
        if result.maxX > maxX { result.origin.x = maxX - result.width }
        return result
    }

    // MARK: - The launcher's anchor

    /// Where the launcher panel hangs for one open, fixed at show time: the
    /// top edge (the input row on the centre line), the horizontal centre,
    /// and the display's visible frame. Root search always comes back to
    /// it, so a drag of one Quick AI edge never moves the search field.
    struct PanelAnchor: Equatable, Sendable {
        let top: CGFloat
        let centreX: CGFloat
        let visibleFrame: CGRect

        /// The frame for a programmatic resize, hung from the anchor's top.
        /// `keepsCurrentCentre` is for a Quick AI surface the user sized:
        /// it stays centred where the user's drag left it (`current`).
        /// Everything else centres on the anchor.
        func frame(
            width: CGFloat,
            height: CGFloat,
            current: CGRect,
            keepsCurrentCentre: Bool,
            risingToFit: Bool
        ) -> CGRect {
            ScreenPlacement.frameHanging(
                from: top,
                height: height,
                width: width,
                centreX: keepsCurrentCentre ? current.midX : centreX,
                within: visibleFrame,
                risingToFit: risingToFit
            )
        }
    }

    // MARK: - Live resize

    /// The two edges a live resize moves, read from where the pointer is
    /// when the drag starts: the half of the frame it is in on each axis.
    /// A drag on one side edge only never changes the other axis, so the
    /// axis it does not move is harmless.
    struct DragEdges: Equatable, Sendable {
        enum Horizontal: Equatable, Sendable { case left, right }
        enum Vertical: Equatable, Sendable { case bottom, top }

        let horizontal: Horizontal
        let vertical: Vertical

        init(horizontal: Horizontal, vertical: Vertical) {
            self.horizontal = horizontal
            self.vertical = vertical
        }

        init(pointer: CGPoint, frame: CGRect) {
            horizontal = pointer.x < frame.midX ? .left : .right
            vertical = pointer.y < frame.midY ? .bottom : .top
        }
    }

    /// The largest size a live resize from `frame` may reach: each moving
    /// edge stops at the visible frame less the margin, so the composer
    /// never slides under the Dock and the header never under the menu
    /// bar. The edges that stay put keep their place, as AppKit keeps them.
    /// Never less than the frame's own size: a frame already past the
    /// margin (moved there by its background) can shrink but not grow.
    static func dragRoom(
        from frame: CGRect,
        moving edges: DragEdges,
        within visibleFrame: CGRect,
        margin: CGFloat = edgeMargin
    ) -> CGSize {
        let width: CGFloat = switch edges.horizontal {
        case .left: frame.maxX - (visibleFrame.minX + margin)
        case .right: (visibleFrame.maxX - margin) - frame.minX
        }
        let height: CGFloat = switch edges.vertical {
        case .bottom: frame.maxY - (visibleFrame.minY + margin)
        case .top: (visibleFrame.maxY - margin) - frame.minY
        }
        return CGSize(width: max(width, frame.width), height: max(height, frame.height))
    }

    static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex(where: { $0.contains(point) }) ?? frames.indices.first
    }

    static func isInMenuBarRegion(
        _ point: CGPoint,
        frames: [CGRect],
        height: CGFloat = 30
    ) -> Bool {
        frames.contains { frame in
            frame.contains(point) && point.y >= frame.maxY - height
        }
    }
}
