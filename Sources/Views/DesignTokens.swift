import AppKit
import SwiftUI

/// Small semantic token set shared by the launcher and settings surfaces.
///
/// The palette is monochrome: near-black on light, near-white on dark, with
/// translucent fills for selection and key caps. Green and red stay for
/// success and danger only.
enum AQDesign {
    enum ColorToken {
        /// Primary emphasis (send arrow, icons, active labels).
        static let accent = adaptive(
            light: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1),
            dark: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
        )
        static let success = Color(red: 0.18, green: 0.72, blue: 0.36)
        static let danger = Color.red
        /// Highlighted row background.
        static let selectionFill = adaptive(
            light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07),
            dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
        )
        /// Tint painted over the blur material behind the overlay.
        static let panelTint = adaptive(
            light: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.78),
            dark: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.82)
        )
        /// Hairline around the overlay panel.
        static let panelStroke = adaptive(
            light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10),
            dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)
        )
        /// Key-cap background for hotkey badges and footer hints.
        static let keyCapFill = adaptive(
            light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06),
            dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
        )
        static let keyCapStroke = adaptive(
            light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10),
            dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
        )

        /// One colour that resolves per appearance, so the overlay follows
        /// the user's appearance setting without separate view code.
        static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
        }
    }

    enum TypeToken {
        static let input = Font.system(size: 17)
        static let body = Font.system(size: 13)
        static let label = Font.system(size: 11, weight: .medium)
        static let caption = Font.system(size: 10)
        /// Key caps in hotkey badges and the footer.
        static let keyCap = Font.system(size: 10, weight: .medium, design: .rounded)
    }

    enum Space {
        static let compact: CGFloat = 4
        static let standard: CGFloat = 8
        static let section: CGFloat = 20
        static let window: CGFloat = 24
    }

    static let cornerRadius: CGFloat = 14
    static let itemCornerRadius: CGFloat = 7
    static let keyCapCornerRadius: CGFloat = 4
    static let controlHeight: CGFloat = 44
    static let footerHeight: CGFloat = 30
    static let motionDuration: TimeInterval = 0.10
}
