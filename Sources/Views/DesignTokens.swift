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
        /// Quiet grouped surfaces in Settings and footer action capsules.
        static let surfaceFill = adaptive(
            light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.035),
            dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.055)
        )
        /// Hover and pressed feedback for compact icon controls.
        static let interactiveFill = adaptive(
            light: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.075),
            dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
        )
        /// Opaque ground of the Settings window.
        static let windowSurface = Color(nsColor: .windowBackgroundColor)
        /// Slightly raised ground of the Settings sidebar.
        static let sidebarSurface = Color(nsColor: .controlBackgroundColor).opacity(0.55)
        /// Hairline around multi-line text editors in Settings.
        static let fieldStroke = Color.secondary.opacity(0.25)

        /// One colour that resolves per appearance, so the overlay follows
        /// the user's appearance setting without separate view code.
        static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            })
        }
    }

    enum TypeToken {
        /// Semantic styles scale with macOS text-size settings.
        static let input = Font.title3
        static let body = Font.body
        static let label = Font.callout.weight(.medium)
        static let metadata = Font.caption
        static let section = Font.caption.weight(.semibold)
        static let caption = Font.caption
        /// Key caps in hotkey badges and the footer.
        static let keyCap = Font.caption2.weight(.medium).monospaced()
        /// Settings pane and section titles.
        static let heading = Font.headline
        /// Bold lead-in above a group of related controls.
        static let subheading = Font.body.weight(.semibold)
        /// Product name in About.
        static let title = Font.title3.weight(.semibold)
        /// Sidebar tab icons.
        static let icon = Font.body.weight(.medium)
        /// Secondary status lines and editor text in Settings (~12 pt).
        static let detail = Font.callout
        /// Explanatory hint under a control (~11 pt).
        static let hint = Font.subheadline
        /// Smallest help text and conflict warnings (~10 pt).
        static let footnote = Font.footnote
        /// Monospaced identifiers: commands, bundle IDs, domains.
        static let code = Font.callout.monospaced()
        /// Emphasised monospaced labels: alias matches, recorded hotkeys.
        static let codeLabel = Font.body.weight(.medium).monospaced()
        /// Reading and editing text one step above body (14 pt): the
        /// translator editor and the welcome copy.
        static let prose = Font.system(size: 14)
        /// Large symbol or emoji glyph in a row or icon slot (18 pt).
        static let glyph = Font.system(size: 18)

        /// Body text that follows the Screen History detail pane's own
        /// accessibility scale rather than Dynamic Type.
        static func scaledBody(_ scale: CGFloat, weight: Font.Weight = .regular) -> Font {
            Font.system(size: 13 * scale, weight: weight)
        }

        /// Hint text (11 pt) under the same manual scale as `scaledBody`.
        static func scaledHint(_ scale: CGFloat, weight: Font.Weight = .regular) -> Font {
            Font.system(size: 11 * scale, weight: weight)
        }
    }

    enum Space {
        static let compact: CGFloat = 4
        static let standard: CGFloat = 8
        static let section: CGFloat = 20
        static let window: CGFloat = 24
    }

    static let cornerRadius: CGFloat = 16
    static let itemCornerRadius: CGFloat = 8
    static let cardCornerRadius: CGFloat = 12
    static let keyCapCornerRadius: CGFloat = 5
    static let fieldCornerRadius: CGFloat = 6
    static let controlHeight: CGFloat = 44
    static let footerHeight: CGFloat = 38
    static let motionDuration: TimeInterval = 0.10
}
