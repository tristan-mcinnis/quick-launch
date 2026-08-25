import CoreGraphics

enum ScreenPlacement {
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
    static func clamped(frame: CGRect, within visibleFrame: CGRect, margin: CGFloat = 12) -> CGRect {
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
