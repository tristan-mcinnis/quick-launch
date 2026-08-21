import CoreGraphics
import Foundation

enum WindowLayout: String, CaseIterable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case firstThird
    case centerThird
    case lastThird
    case firstFourth
    case secondFourth
    case thirdFourth
    case lastFourth

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .firstFourth: "First Fourth"
        case .secondFourth: "Second Fourth"
        case .thirdFourth: "Third Fourth"
        case .lastFourth: "Last Fourth"
        }
    }

    /// Unit-space frame measured from the display's top-left corner.
    var normalizedFrame: CGRect {
        switch self {
        case .leftHalf: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .firstThird: CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1)
        case .centerThird: CGRect(x: 1.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        case .lastThird: CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1)
        case .firstFourth: CGRect(x: 0, y: 0, width: 0.25, height: 1)
        case .secondFourth: CGRect(x: 0.25, y: 0, width: 0.25, height: 1)
        case .thirdFourth: CGRect(x: 0.5, y: 0, width: 0.25, height: 1)
        case .lastFourth: CGRect(x: 0.75, y: 0, width: 0.25, height: 1)
        }
    }
}
