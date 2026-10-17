import SwiftUI
import HouseDesign

/// How the AI Chat rail comes and goes. The layout slot beside the
/// conversation changes width at once, so the thread never re-wraps on a
/// curve; only the rail itself slides, 0.2 s, easing out on the way in and
/// in on the way out. With Reduce Motion it fades and does not move
/// (DESIGN.md). A window narrower than the layout minimum lays the rail
/// over the conversation instead of squeezing it.
enum ChatRailMotion {
    static let duration: Double = ChatMotion.slide

    /// Cubic Bézier control points (x1, y1, x2, y2), or nil when Reduce
    /// Motion swaps the slide for a plain fade.
    static func curve(opening: Bool, reduceMotion: Bool) -> (Double, Double, Double, Double)? {
        if reduceMotion { return nil }
        return ChatMotion.slideCurve(opening: opening)
    }

    static func animation(opening: Bool, reduceMotion: Bool) -> Animation {
        ChatMotion.slideAnimation(opening: opening, reduceMotion: reduceMotion)
    }

    /// The rail takes its own column only while the window is as wide as
    /// the layout minimum; narrower, it overlays.
    static func isInline(windowWidth: CGFloat) -> Bool {
        windowWidth >= House.Layout.chatMinWidth
    }

    /// The width the conversation gives up to the rail: none while the
    /// rail is out or overlaying.
    static func slotWidth(railVisible: Bool, windowWidth: CGFloat) -> CGFloat {
        railVisible && isInline(windowWidth: windowWidth) ? House.Layout.chatRail + House.hairline : 0
    }
}
