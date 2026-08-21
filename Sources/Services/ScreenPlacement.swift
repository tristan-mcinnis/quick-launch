import CoreGraphics

enum ScreenPlacement {
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
