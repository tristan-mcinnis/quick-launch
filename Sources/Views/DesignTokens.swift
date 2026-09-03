import AppKit
import SwiftUI

/// Quick Launch's view of the house design system.
///
/// Every colour, radius, spacing, and control value comes from the generated
/// `HouseDesign.swift` (design-system/tokens.json). This file only names the
/// launcher's semantic roles and keeps Dynamic Type for overlay text so the
/// system text-size setting still applies.
enum AQDesign {
    enum ColorToken {
        /// The one accent: the primary action (send) only.
        static let accent = House.ColorToken.accent
        /// Ink for selected icons, alias labels, and active tabs.
        static let emphasis = House.ColorToken.textPrimary
        static let success = House.ColorToken.success
        static let danger = House.ColorToken.danger
        /// Highlighted row background.
        static let selectionFill = House.ColorToken.selectionFill
        /// Tint painted over the blur material behind the overlay.
        static let panelTint = House.ColorToken.panelTint
        /// Hairline around the overlay panel.
        static let panelStroke = House.ColorToken.stroke
        /// Key-cap background for hotkey badges and footer hints.
        static let keyCapFill = House.ColorToken.keyCapFill
        static let keyCapStroke = House.ColorToken.keyCapStroke
        /// Quiet grouped surfaces in Settings and footer action capsules.
        static let surfaceFill = House.ColorToken.surfaceTint
        /// Hover and pressed feedback for compact icon controls.
        static let interactiveFill = House.ColorToken.hoverFill
        /// Opaque ground of the Settings window.
        static let windowSurface = House.ColorToken.surface
        /// Slightly raised ground of the Settings sidebar.
        static let sidebarSurface = House.ColorToken.surfaceSunken.opacity(0.55)
        /// Hairline around multi-line text editors in Settings.
        static let fieldStroke = House.ColorToken.stroke
    }

    enum TypeToken {
        /// Semantic styles scale with macOS text-size settings. Base sizes
        /// match the house scale (15/13/12/11/10).
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
        /// Reading and editing text one step above body: the translator
        /// editor and the welcome copy.
        static let prose = House.TypeToken.body
        /// Large symbol or emoji glyph in a row or icon slot (18 pt).
        static let glyph = Font.system(size: 18)

        /// Body text that follows the Screen History detail pane's own
        /// accessibility scale rather than Dynamic Type.
        static func scaledBody(_ scale: CGFloat, weight: Font.Weight = .regular) -> Font {
            Font.system(size: House.TypeToken.Size.bodySmall * scale, weight: weight)
        }

        /// Hint text under the same manual scale as `scaledBody`.
        static func scaledHint(_ scale: CGFloat, weight: Font.Weight = .regular) -> Font {
            Font.system(size: House.TypeToken.Size.caption * scale, weight: weight)
        }
    }

    enum Space {
        static let compact = House.Spacing.xxs
        static let standard = House.Spacing.xs
        static let section = House.Spacing.lg
        static let window = House.Spacing.xl
    }

    static let cornerRadius = House.Radius.xl
    static let itemCornerRadius = House.Radius.md
    static let cardCornerRadius = House.Radius.lg
    static let keyCapCornerRadius = House.Radius.xs
    static let fieldCornerRadius = House.Radius.sm
    static let controlHeight = House.Control.large
    /// Footer strip height; a layout constant, not a control.
    static let footerHeight: CGFloat = 38
    static let motionDuration = House.Motion.fast
}
