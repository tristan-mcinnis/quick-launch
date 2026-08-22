import CoreGraphics
import Foundation

enum WindowLayout: String, CaseIterable, Sendable {
    case maximize
    case almostMaximize
    case center
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case firstThird
    case centerThird
    case lastThird
    case leftTwoThirds
    case rightTwoThirds
    case firstFourth
    case secondFourth
    case thirdFourth
    case lastFourth

    var title: String {
        switch self {
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .center: "Center"
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .firstThird: "Left Third"
        case .centerThird: "Middle Third"
        case .lastThird: "Right Third"
        case .leftTwoThirds: "Left Two Thirds"
        case .rightTwoThirds: "Right Two Thirds"
        case .firstFourth: "Left Fourth"
        case .secondFourth: "Second Fourth"
        case .thirdFourth: "Third Fourth"
        case .lastFourth: "Right Fourth"
        }
    }

    var groupTitle: String {
        switch self {
        case .maximize, .almostMaximize, .center: "Whole Screen"
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: "Halves"
        case .firstThird, .centerThird, .lastThird, .leftTwoThirds, .rightTwoThirds: "Thirds"
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth: "Fourths"
        }
    }

    static let groupTitles = ["Whole Screen", "Halves", "Thirds", "Fourths"]

    /// Unit-space frame measured from the display's top-left corner.
    var normalizedFrame: CGRect {
        switch self {
        case .maximize: CGRect(x: 0, y: 0, width: 1, height: 1)
        case .almostMaximize: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        case .center: CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8)
        case .leftHalf: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .firstThird: CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1)
        case .centerThird: CGRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        case .lastThird: CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        case .leftTwoThirds: CGRect(x: 0, y: 0, width: 2.0 / 3.0, height: 1)
        case .rightTwoThirds: CGRect(x: 1.0 / 3.0, y: 0, width: 2.0 / 3.0, height: 1)
        case .firstFourth: CGRect(x: 0, y: 0, width: 0.25, height: 1)
        case .secondFourth: CGRect(x: 0.25, y: 0, width: 0.25, height: 1)
        case .thirdFourth: CGRect(x: 0.5, y: 0, width: 0.25, height: 1)
        case .lastFourth: CGRect(x: 0.75, y: 0, width: 0.25, height: 1)
        }
    }
}

/// Window moves that are not a layout on the current display.
enum WindowMove: String, CaseIterable, Sendable {
    case nextDisplay
    case previousDisplay

    var title: String {
        switch self {
        case .nextDisplay: "Move to Next Display"
        case .previousDisplay: "Move to Previous Display"
        }
    }

    var detail: String { "Keep the window's relative size and position" }

    /// Which display index to move to, given the current index and count.
    func targetIndex(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        switch self {
        case .nextDisplay: return (current + 1) % count
        case .previousDisplay: return (current - 1 + count) % count
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
