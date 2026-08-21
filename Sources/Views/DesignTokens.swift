import SwiftUI

/// Small semantic token set shared by the launcher and settings surfaces.
enum AQDesign {
    enum ColorToken {
        static let accent = Color(red: 0.55, green: 0.36, blue: 0.96)
        static let success = Color(red: 0.18, green: 0.72, blue: 0.36)
        static let danger = Color.red
        static let selectionFill = accent.opacity(0.12)
    }

    enum TypeToken {
        static let input = Font.system(size: 17)
        static let body = Font.system(size: 13)
        static let label = Font.system(size: 11, weight: .medium)
        static let caption = Font.system(size: 10)
    }

    enum Space {
        static let compact: CGFloat = 4
        static let standard: CGFloat = 8
        static let section: CGFloat = 20
        static let window: CGFloat = 24
    }

    static let cornerRadius: CGFloat = 16
    static let itemCornerRadius: CGFloat = 7
    static let controlHeight: CGFloat = 44
    static let motionDuration: TimeInterval = 0.10
}
