import AppKit
import SwiftUI

/// Quick Launch's view of the house design system ("Slate").
///
/// Every colour, radius, spacing, shadow, and control value comes from the
/// generated `HouseDesign.swift` (design-system/tokens.json). This file only
/// names the launcher's semantic roles. Nothing here retypes a value.
///
/// Type is the house scale at its fixed point sizes: 16 input, 14 prose,
/// 13 label, 12 meta, 11 caption, 10.5 section, 10 micro. Views that carry
/// their own accessibility scale use the `scaled*` helpers.
enum AQDesign {
    enum ColorToken {
        /// Focus rings and links only. Never a fill, never chrome.
        static let accent = House.ColorToken.accent
        /// Full-strength ink: row titles, glyphs in a tile, answers.
        static let emphasis = House.ColorToken.textPrimary
        static let textPrimary = House.ColorToken.textPrimary
        /// Ink at 60 %: supporting text, key-cap glyphs, footer context.
        static let textSecondary = House.ColorToken.textSecondary
        /// Ink at 40 %: metadata, placeholders, section labels.
        static let textTertiary = House.ColorToken.textTertiary
        /// Text on the HUD or on an ink-filled control.
        static let textInverse = House.ColorToken.textInverse
        static let success = House.ColorToken.success
        static let warning = House.ColorToken.warning
        static let danger = House.ColorToken.danger

        /// Selected row: fill plus an inset ring plus a 1 px drop.
        static let selectionFill = House.ColorToken.selectionFill
        static let selectionRing = House.ColorToken.selectionRing
        /// Hover is half the selection fill, and never carries a ring.
        static let hoverFill = House.ColorToken.hoverFill

        /// Tint painted over the blur material behind a floating panel.
        static let panelTint = House.ColorToken.panelTint
        /// Hairline around the overlay panel or a raised card.
        static let panelStroke = House.ColorToken.stroke
        /// Focused hairline.
        static let panelStrokeStrong = House.ColorToken.strokeStrong
        /// Line between the input row, the list, and the footer. Quieter
        /// than the panel stroke; never the panel stroke.
        static let divider = House.ColorToken.divider
        /// 1 px inset highlight along the top edge of a panel or card.
        static let highlightTop = House.ColorToken.highlightTop
        /// Sunken well under the footer strip and the settings rail.
        static let well = House.ColorToken.well

        /// The 26 pt tile behind a row glyph.
        static let tileFill = House.ColorToken.tileFill
        static let tileStroke = House.ColorToken.tileStroke
        /// Question chips, model chips, session chips.
        static let chipFill = House.ColorToken.chipFill

        /// Key caps are outlined; the fill is clear in both appearances.
        static let keyCapFill = House.ColorToken.keyCapFill
        static let keyCapStroke = House.ColorToken.keyCapStroke

        /// Quiet grouped surfaces: settings cards, the search field, the
        /// menu button beside the input.
        static let surfaceFill = House.ColorToken.surfaceTint
        /// Hover and pressed feedback for compact icon controls.
        static let interactiveFill = House.ColorToken.hoverFill
        /// Opaque ground of the Settings window.
        static let windowSurface = House.ColorToken.surface
        /// Raised card or composer above the ground.
        static let raisedSurface = House.ColorToken.surfaceRaised
        /// Sunken ground of the Settings rail.
        static let sidebarSurface = House.ColorToken.surfaceSunken
        /// Hairline around multi-line text editors in Settings.
        static let fieldStroke = House.ColorToken.stroke

        /// Full-screen HUD overlays (Type to Click). Same in both modes.
        static let hudFill = House.ColorToken.hudFill
        static let hudText = House.ColorToken.hudText
        static let hudStroke = House.ColorToken.hudStroke
        static let hudMuted = House.ColorToken.hudMuted
    }

    enum TypeToken {
        /// The launcher field and composers (16).
        static let input = House.TypeToken.input
        /// Row titles and control labels (13 medium).
        static let label = House.TypeToken.label
        /// Reading text one step below an answer (13).
        static let body = House.TypeToken.bodySmall
        /// Answers and prose (14, line height 1.55).
        static let prose = House.TypeToken.body
        /// Row detail, footer text, times (12).
        static let metadata = House.TypeToken.meta
        /// The same 12 pt, read as a status or detail line.
        static let detail = House.TypeToken.meta
        /// Hints (11).
        static let caption = House.TypeToken.caption
        static let hint = House.TypeToken.caption
        /// Smallest help text (10).
        static let footnote = House.TypeToken.micro
        /// Section labels: set in capitals with `sectionTracking`.
        static let section = House.TypeToken.section
        /// Key caps: SF at 11 medium, never monospaced.
        static let keyCap = House.TypeToken.keyCap
        /// Settings pane titles (20 semibold).
        static let title = House.TypeToken.title
        /// Card and group headings (16 semibold).
        static let heading = House.TypeToken.heading
        /// Bold lead-in above a run of related controls (13 semibold).
        static let subheading = Font.system(size: House.TypeToken.Size.bodySmall, weight: .semibold)
        /// Rail and sidebar tab icons.
        static let icon = House.TypeToken.label
        /// Monospaced identifiers: commands, bundle IDs, domains (12).
        static let code = House.TypeToken.code
        /// Emphasised monospaced labels: alias matches, recorded hotkeys.
        static let codeLabel = Font.system(
            size: House.TypeToken.Size.label,
            weight: .medium,
            design: .monospaced
        )
        /// Large symbol or emoji glyph in a row or icon slot.
        static let glyph = Font.system(size: 18)

        /// Letter spacing for `section`, in points.
        static let sectionTracking = House.TypeToken.Tracking.section
        /// Line spacing to add so `prose` reaches its 1.55 line height.
        static let proseLineSpacing =
            House.TypeToken.Size.body * (House.TypeToken.LineHeight.body - 1)

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
        static let compact = House.Spacing.xxs      // 4
        static let standard = House.Spacing.xs      // 8
        static let row = House.Spacing.sm           // 12: gap inside a row
        static let panel = House.Spacing.lg         // 20: panel side padding
        static let section = House.Spacing.lg       // 20
        static let window = House.Spacing.xl        // 24
    }

    /// Shadows. Opacity depends on the appearance, so views apply these
    /// through `houseShadow(_:)` rather than reading them directly.
    enum Shadow {
        static let panelNear = House.Shadow.panelNear
        static let panelFar = House.Shadow.panelFar
        static let selection = House.Shadow.selection
        static let card = House.Shadow.card
    }

    /// Blur material behind `panelTint`.
    enum Material {
        static let blur = House.Material.blur
        static let saturate = House.Material.saturate
    }

    enum Motion {
        static let hover = House.Motion.hover
        static let select = House.Motion.select
        static let open = House.Motion.open
    }

    // MARK: - Shape and size

    /// Floating panels.
    static let cornerRadius = House.Radius.xl
    /// Rows and the selection fill behind them.
    static let itemCornerRadius = House.Radius.row
    /// Menus, the input's menu button, small tiles.
    static let menuCornerRadius = House.Radius.md
    /// Raised cards and settings groups.
    static let cardCornerRadius = House.Radius.lg
    /// The 26 pt icon tile.
    static let tileCornerRadius = House.Radius.tile
    static let keyCapCornerRadius = House.Radius.xs
    /// Fields and chips.
    static let fieldCornerRadius = House.Radius.sm

    static let hairline = House.hairline
    static let tileSize = House.Control.tile          // 26
    static let keyCapHeight = House.Control.keyCap    // 20
    static let rowHeight = House.Control.row          // 40
    static let railRowHeight = House.Control.railRow  // 36
    static let inputHeight = House.Control.input      // 58
    static let controlHeight = House.Control.row      // 40
    static let footerHeight = House.Control.footer    // 40
}
