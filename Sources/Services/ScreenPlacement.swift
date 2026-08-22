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
