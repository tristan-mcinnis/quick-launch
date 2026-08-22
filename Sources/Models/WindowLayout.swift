import CoreGraphics
import Foundation

/// Fixed-frame layouts: a fraction of the display's visible area.
enum WindowLayout: String, CaseIterable, Sendable {
    case maximize
    case almostMaximize
    case leftHalf
    case centerHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case firstThird
    case centerThird
    case lastThird
    case leftTwoThirds
    case rightTwoThirds
    case firstFourth
    case secondFourth
    case thirdFourth
    case lastFourth
    case topLeftSixth
    case topCenterSixth
    case topRightSixth
    case bottomLeftSixth
    case bottomCenterSixth
    case bottomRightSixth

    var title: String {
        switch self {
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .leftHalf: "Left Half"
        case .centerHalf: "Center Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeftQuarter: "Top Left Quarter"
        case .topRightQuarter: "Top Right Quarter"
        case .bottomLeftQuarter: "Bottom Left Quarter"
        case .bottomRightQuarter: "Bottom Right Quarter"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .leftTwoThirds: "First Two Thirds"
        case .rightTwoThirds: "Last Two Thirds"
        case .firstFourth: "First Fourth"
        case .secondFourth: "Second Fourth"
        case .thirdFourth: "Third Fourth"
        case .lastFourth: "Last Fourth"
        case .topLeftSixth: "Top Left Sixth"
        case .topCenterSixth: "Top Center Sixth"
        case .topRightSixth: "Top Right Sixth"
        case .bottomLeftSixth: "Bottom Left Sixth"
        case .bottomCenterSixth: "Bottom Center Sixth"
        case .bottomRightSixth: "Bottom Right Sixth"
        }
    }

    var groupTitle: String {
        switch self {
        case .maximize, .almostMaximize: "Whole Screen"
        case .leftHalf, .centerHalf, .rightHalf, .topHalf, .bottomHalf: "Halves"
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter: "Quarters"
        case .firstThird, .centerThird, .lastThird, .leftTwoThirds, .rightTwoThirds: "Thirds"
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth: "Fourths"
        case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth: "Sixths"
        }
    }

    static let groupTitles = ["Whole Screen", "Halves", "Quarters", "Thirds", "Fourths", "Sixths"]

    /// Unit-space frame measured from the display's top-left corner.
    var normalizedFrame: CGRect {
        let third = 1.0 / 3.0
        switch self {
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .almostMaximize: return CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .centerHalf: return CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeftQuarter: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRightQuarter: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeftQuarter: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRightQuarter: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .firstThird: return CGRect(x: 0, y: 0, width: third, height: 1)
        case .centerThird: return CGRect(x: third, y: 0, width: third, height: 1)
        case .lastThird: return CGRect(x: 2 * third, y: 0, width: third, height: 1)
        case .leftTwoThirds: return CGRect(x: 0, y: 0, width: 2 * third, height: 1)
        case .rightTwoThirds: return CGRect(x: third, y: 0, width: 2 * third, height: 1)
        case .firstFourth: return CGRect(x: 0, y: 0, width: 0.25, height: 1)
        case .secondFourth: return CGRect(x: 0.25, y: 0, width: 0.25, height: 1)
        case .thirdFourth: return CGRect(x: 0.5, y: 0, width: 0.25, height: 1)
        case .lastFourth: return CGRect(x: 0.75, y: 0, width: 0.25, height: 1)
        case .topLeftSixth: return CGRect(x: 0, y: 0, width: third, height: 0.5)
        case .topCenterSixth: return CGRect(x: third, y: 0, width: third, height: 0.5)
        case .topRightSixth: return CGRect(x: 2 * third, y: 0, width: third, height: 0.5)
        case .bottomLeftSixth: return CGRect(x: 0, y: 0.5, width: third, height: 0.5)
        case .bottomCenterSixth: return CGRect(x: third, y: 0.5, width: third, height: 0.5)
        case .bottomRightSixth: return CGRect(x: 2 * third, y: 0.5, width: third, height: 0.5)
        }
    }

    /// Repeating Left Half or Right Half on the same window cycles through
    /// these sizes, as Raycast's cycling option does.
    var cycle: [WindowLayout] {
        switch self {
        case .leftHalf: [.leftHalf, .leftTwoThirds, .firstThird]
        case .rightHalf: [.rightHalf, .rightTwoThirds, .lastThird]
        case .topHalf, .bottomHalf: [self]
        default: [self]
        }
    }

    /// Frame in `screen` (top-left origin space) for this layout.
    func frame(in screen: CGRect) -> CGRect {
        let unit = normalizedFrame
        return CGRect(
            x: (screen.minX + screen.width * unit.minX).rounded(),
            y: (screen.minY + screen.height * unit.minY).rounded(),
            width: (screen.width * unit.width).rounded(),
            height: (screen.height * unit.height).rounded()
        )
    }
}

/// Window commands that depend on the current frame or another display.
enum WindowMove: String, CaseIterable, Sendable {
    case nextDisplay
    case previousDisplay
    case center
    case maximizeHeight
    case maximizeWidth
    case reasonableSize
    case smaller
    case larger
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case restore
    case toggleFullScreen

    var title: String {
        switch self {
        case .nextDisplay: "Move to Next Display"
        case .previousDisplay: "Move to Previous Display"
        case .center: "Center"
        case .maximizeHeight: "Maximize Height"
        case .maximizeWidth: "Maximize Width"
        case .reasonableSize: "Reasonable Size"
        case .smaller: "Make Smaller"
        case .larger: "Make Larger"
        case .moveLeft: "Move Left"
        case .moveRight: "Move Right"
        case .moveUp: "Move Up"
        case .moveDown: "Move Down"
        case .restore: "Restore"
        case .toggleFullScreen: "Toggle Fullscreen"
        }
    }

    var detail: String {
        switch self {
        case .nextDisplay, .previousDisplay: "Keep the window's relative size and position"
        case .center: "Center the window, keeping its size"
        case .maximizeHeight: "Full height, same width"
        case .maximizeWidth: "Full width, same height"
        case .reasonableSize: "60% of the screen, up to 1025 × 900, centered"
        case .smaller: "Shrink by 10% around the center"
        case .larger: "Grow by 10% around the center"
        case .moveLeft, .moveRight, .moveUp, .moveDown: "Move the window to that screen edge"
        case .restore: "Back to the size and position before the last command"
        case .toggleFullScreen: "Native macOS full screen on or off"
        }
    }

    /// Which display index to move to, given the current index and count.
    func targetIndex(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        switch self {
        case .nextDisplay: return (current + 1) % count
        case .previousDisplay: return (current - 1 + count) % count
        default: return current
        }
    }

    /// The new frame for in-display moves. Pure; nil for display switches,
    /// restore, and full screen, which need the window manager's state.
    func adjustedFrame(window: CGRect, screen: CGRect) -> CGRect? {
        func clamped(_ frame: CGRect) -> CGRect {
            var result = frame
            result.size.width = min(result.width, screen.width)
            result.size.height = min(result.height, screen.height)
            result.origin.x = min(max(result.minX, screen.minX), screen.maxX - result.width)
            result.origin.y = min(max(result.minY, screen.minY), screen.maxY - result.height)
            return CGRect(
                x: result.minX.rounded(), y: result.minY.rounded(),
                width: result.width.rounded(), height: result.height.rounded()
            )
        }
        switch self {
        case .center:
            return clamped(CGRect(
                x: screen.midX - window.width / 2,
                y: screen.midY - window.height / 2,
                width: window.width,
                height: window.height
            ))
        case .maximizeHeight:
            return clamped(CGRect(x: window.minX, y: screen.minY, width: window.width, height: screen.height))
        case .maximizeWidth:
            return clamped(CGRect(x: screen.minX, y: window.minY, width: screen.width, height: window.height))
        case .reasonableSize:
            let width = min(screen.width * 0.6, 1_025)
            let height = min(screen.height * 0.6, 900)
            return clamped(CGRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height))
        case .smaller, .larger:
            let factor: CGFloat = self == .smaller ? 0.9 : 1.1
            let width = max(200, min(screen.width, window.width * factor))
            let height = max(150, min(screen.height, window.height * factor))
            return clamped(CGRect(x: window.midX - width / 2, y: window.midY - height / 2, width: width, height: height))
        case .moveLeft:
            return clamped(CGRect(x: screen.minX, y: window.minY, width: window.width, height: window.height))
        case .moveRight:
            return clamped(CGRect(x: screen.maxX - window.width, y: window.minY, width: window.width, height: window.height))
        case .moveUp:
            return clamped(CGRect(x: window.minX, y: screen.minY, width: window.width, height: window.height))
        case .moveDown:
            return clamped(CGRect(x: window.minX, y: screen.maxY - window.height, width: window.width, height: window.height))
        case .nextDisplay, .previousDisplay, .restore, .toggleFullScreen:
            return nil
        }
    }

    /// The frame on `target` that keeps the window's unit-space placement
    /// from `source`. Pure, so it is testable without Accessibility.
    static func relocatedFrame(window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return target }
        let unit = CGRect(
            x: (window.minX - source.minX) / source.width,
            y: (window.minY - source.minY) / source.height,
            width: min(1, window.width / source.width),
            height: min(1, window.height / source.height)
        )
        var frame = CGRect(
            x: target.minX + unit.minX * target.width,
            y: target.minY + unit.minY * target.height,
            width: unit.width * target.width,
            height: unit.height * target.height
        )
        frame.origin.x = min(max(frame.minX, target.minX), target.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, target.minY), target.maxY - frame.height)
        return frame
    }
}

/// Decides whether a repeated layout should step to the next size in its
/// cycle. Pure, so the rule is tested without Accessibility.
enum WindowCycling {
    /// `lastLayout`/`lastFrame` describe what Quick Launch set on this
    /// window most recently; `current` is the window's frame now.
    static func next(
        requested: WindowLayout,
        lastLayout: WindowLayout?,
        lastFrame: CGRect?,
        current: CGRect,
        tolerance: CGFloat = 4
    ) -> WindowLayout {
        let cycle = requested.cycle
        guard cycle.count > 1,
              let lastLayout, let lastFrame,
              cycle.contains(lastLayout),
              abs(lastFrame.minX - current.minX) <= tolerance,
              abs(lastFrame.minY - current.minY) <= tolerance,
              abs(lastFrame.width - current.width) <= tolerance,
              abs(lastFrame.height - current.height) <= tolerance,
              let index = cycle.firstIndex(of: lastLayout)
        else { return requested }
        return cycle[(index + 1) % cycle.count]
    }
}
