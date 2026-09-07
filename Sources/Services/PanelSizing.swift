import CoreFoundation
import SwiftUI

/// Pure layout calculation for the Quick Launch overlay panel height.
/// Extracted from AppDelegate so it can be unit-tested without AppKit
/// and reused by the observation-driven resize path.
enum PanelSizing {

    // MARK: - Widths

    /// The house launcher width.
    static let panelWidth = House.Layout.panelWidth
    /// A preview-worthy catalog with its detail pane beside the list.
    static let panelWidthWithDetail: CGFloat = 960
    /// A Quick AI thread gets a little more room so answers read like a
    /// document rather than a strip.
    static let panelWidthForAnswer = House.Layout.answerPanelWidth

    // MARK: - Heights

    static let inputHeight = House.Control.input
    static let maxBodyHeight: CGFloat = 640
    /// Horizontal padding around the answer body (20pt each side); the
    /// measured markdown width is the panel width minus this.
    static let answerHorizontalPadding = House.Spacing.lg * 2
    /// Compact earlier-turns transcript shown above the latest answer.
    static let transcriptHeight: CGFloat = 240
    static let errorBannerHeight = House.Control.footer
    static let attachmentHeight = House.Control.input
    /// One row in the launcher list.
    static let launcherRowHeight = House.Control.row
    /// One row in the ⌘K pane and the prompt palette.
    static let actionRowHeight = House.Control.row
    /// LazyVStack spacing between action rows.
    static let actionRowSpacing: CGFloat = 2
    /// Rows shown before the action list scrolls.
    static let actionVisibleRows = 6
    /// Title row at the top of the ⌘K item pane.
    static let paneHeaderHeight = House.Control.large
    /// Search field row at the bottom of the ⌘K item pane.
    static let paneSearchRowHeight = House.Control.footer
    /// Gap between the floating pane's bottom edge and the window edge.
    static let paneBottomMargin = House.Spacing.sm
    /// Footer row plus its divider.
    static let footerHeight = AQDesign.footerHeight + House.hairline
    /// Vertical inset around the launcher rows.
    static let launcherListInset = House.Spacing.sm
    /// The question chip above an answer, plus the gap under it.
    static let questionChipBlock = House.Control.chip - 6 + House.Spacing.sm
    /// The launcher list's chrome above and below the rows: the section
    /// header ("Results") plus the bottom inset, as measured from the
    /// rendered view. Counting only the rows left the last one clipped.
    /// 8 top inset + (6 + label + 6) section block + 8 bottom inset.
    /// `estimateCoversTheRenderedSingleResultWindow` measures the real view
    /// against this, so it cannot drift.
    static let launcherListChrome: CGFloat = 42

    /// The launch-selection chip row: divider + vertical padding + a control
    /// height of content. Inline content, so the window must include it.
    static let selectionChipHeight = House.hairline + House.Spacing.xs * 2 + House.Control.row

    /// Chrome around the chooser's row list: header row plus top/bottom padding.
    static let chooserChrome: CGFloat = House.Control.chip + House.Spacing.xs * 2

    /// The Transform chooser block height for `rows` options (the chooser
    /// replaces the launcher list while open).
    static func chooserBlockHeight(rows: Int) -> CGFloat {
        chooserChrome + actionListHeight(rows: rows, padded: false)
    }
    /// The search row and footer stay pinned while long result sets scroll.
    /// Twelve whole rows plus the section block: the list scrolls rather
    /// than cutting the thirteenth row in half.
    static let launcherListMaximumHeight = launcherListChrome + 12 * House.Control.row
    /// A preview plus its Information block needs this much room.
    static let detailPaneMinimumHeight: CGFloat = 360

    // MARK: - Floating ⌘K pane / prompt palette
    //
    // OverlayView renders these panes with the same constants, so the window
    // estimate and the drawn pane cannot drift apart. The pane hugs its rows;
    // it never stretches to fill leftover window height.

    /// The scrolling row list inside a pane. `padded` covers the item pane's
    /// 6pt vertical insets; the palette list has none.
    static func actionListHeight(rows: Int, padded: Bool = true) -> CGFloat {
        let visible = max(1, min(rows, actionVisibleRows))
        return CGFloat(visible) * actionRowHeight
            + CGFloat(visible - 1) * actionRowSpacing
            + (padded ? House.Spacing.sm : 0)
    }

    /// ⌘K item pane: header + divider + list + divider + search row.
    static func itemActionPaneHeight(rows: Int) -> CGFloat {
        paneHeaderHeight + House.hairline
            + actionListHeight(rows: rows)
            + House.hairline + paneSearchRowHeight
    }

    /// ⌘K pane showing a form instead of the list. Each form knows its own
    /// body height; sizing never names a feature.
    static func itemActionFormPaneHeight(form: ItemActionForm) -> CGFloat {
        form.minimumPaneHeight
    }

    /// Prompt palette: search row + spacing + list + spacing + hint row.
    static func actionPaletteHeight(rows: Int) -> CGFloat {
        House.Control.row + House.Spacing.xs
            + actionListHeight(rows: rows, padded: false)
            + House.Spacing.xs + House.Control.tile
    }

    /// The window keeps its base height while a pane floats over it; it only
    /// grows when the pane (everything above it + pane + margin) needs more
    /// room. `paneTop` is the input row plus, when shown, the attachment strip.
    static func windowHeight(
        base: CGFloat,
        paneHeight: CGFloat?,
        paneTop: CGFloat = PanelSizing.inputHeight
    ) -> CGFloat {
        guard let paneHeight else { return base }
        return max(base, paneTop + paneHeight + paneBottomMargin)
    }

    /// The earlier-turns block above the latest answer: capped transcript
    /// plus its divider and the surrounding stack spacing. Zero until a
    /// conversation has more than one exchange on screen.
    static func transcriptBlockHeight(messageCount: Int) -> CGFloat {
        messageCount > 2 ? transcriptHeight + 17 : 0
    }

    static func panelHeight(
        output: String,
        isStreaming: Bool,
        errorMessage: String?,
        suggestionCount: Int = 0,
        showsResultActions: Bool = false,
        hasAttachment: Bool = false,
        showsFooter: Bool = false,
        launcherRowCount: Int = 0,
        showsQuestion: Bool = false,
        gridRows: Int = 0,
        gridSections: Int = 0,
        showsDetailPane: Bool = false,
        measuredBodyHeight: CGFloat? = nil,
        transcriptHeight: CGFloat = 0
    ) -> CGFloat {
        var total = inputHeight
        if hasAttachment { total += attachmentHeight }
        if gridRows > 0 {
            total += CGFloat(gridRows) * House.Control.composer
                + CGFloat(gridSections) * House.Spacing.xl
                + launcherListInset
        } else if suggestionCount > 0 {
            var block = min(CGFloat(suggestionCount), 12) * launcherRowHeight
            if launcherRowCount > 0 {
                // Header + inset, capped exactly like the rendered list.
                block = min(block + launcherListChrome, launcherListMaximumHeight)
            }
            if showsDetailPane { block = max(block, detailPaneMinimumHeight) }
            total += block
        }
        if !output.isEmpty || isStreaming {
            total += transcriptHeight
            let bodyHeight: CGFloat
            if let measuredBodyHeight {
                // Measured text plus the 20pt vertical padding around the
                // answer stack; the floor keeps room for the thinking row.
                bodyHeight = min(maxBodyHeight, max(68, measuredBodyHeight + 40))
            } else {
                let approxLines = max(1, output.count / 60 + 1)
                bodyHeight = min(maxBodyHeight, CGFloat(approxLines) * 22 + 40)
            }
            total += bodyHeight
            if showsQuestion { total += questionChipBlock }
        }
        if errorMessage != nil {
            total += errorBannerHeight
        }
        if showsResultActions {
            total += AQDesign.controlHeight + House.hairline
        }
        if showsFooter {
            total += footerHeight
        }
        return total
    }
}
