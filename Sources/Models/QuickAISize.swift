import CoreGraphics

/// The Quick AI surface's size. The surface opens at 750 × 475 (the Raycast
/// size, `House.Layout.panelWidth` × `House.Layout.quickAIHeight`) and the
/// user can drag its edges to make it larger; the size is remembered in
/// `QuickSettings.quickAISize` across opens and relaunches. It is never
/// smaller than the standard size: that is the surface's minimum.
struct QuickAISize: Codable, Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat

    init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }

    /// The size Quick AI opens at, and the smallest it can be dragged to.
    static let standard = QuickAISize(
        width: House.Layout.panelWidth,
        height: House.Layout.quickAIHeight
    )

    var cgSize: CGSize { CGSize(width: width, height: height) }

    /// Never below the standard size in either dimension. A value that is
    /// not a finite number (a hand-edited blob) falls back to the standard.
    var atLeastStandard: QuickAISize {
        QuickAISize(
            width: Self.atLeast(Self.standard.width, width),
            height: Self.atLeast(Self.standard.height, height)
        )
    }

    /// True when the size is the standard one, give or take a point, so
    /// Reset Quick AI Size is offered only when there is something to reset.
    var isStandard: Bool {
        let size = atLeastStandard
        return abs(size.width - Self.standard.width) < 1
            && abs(size.height - Self.standard.height) < 1
    }

    private static func atLeast(_ minimum: CGFloat, _ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return minimum }
        return max(minimum, value)
    }
}
