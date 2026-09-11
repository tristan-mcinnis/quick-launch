import CoreFoundation
import SwiftUI

/// Pure layout calculation for the Quick Launch overlay panel height.
/// Extracted from AppDelegate so it can be unit-tested without AppKit
/// and reused by the observation-driven resize path.
enum PanelSizing {

    // MARK: - Widths

    /// The house launcher width. The Quick AI surface opens at the same
    /// width and can be dragged wider (`QuickAISize`).
    static let panelWidth = House.Layout.panelWidth
    /// A preview-worthy catalog with its detail pane beside the list.
    static let panelWidthWithDetail: CGFloat = 960
    /// The `⌘K` palette and item pane floating over a surface, and how far
    /// they keep from its sides.
    static let actionPaletteWidth: CGFloat = 520
    static let actionPaletteSideMargin = House.Spacing.lg + House.Spacing.xxs
    /// The tallest the floating palette or pane grows before it scrolls.
    static let actionPaletteMaxHeight: CGFloat = 460

    // MARK: - Heights

    static let inputHeight = House.Control.input
    /// The Quick AI surface's standard (and smallest) height; the thread
    /// scrolls inside it. The user can drag it taller (`QuickAISize`).
    static let quickAIHeight = House.Layout.quickAIHeight
    static let errorBannerHeight = House.Control.footer
    /// The attachment strip over a composer: one row of chips with
    /// `Spacing.xs` above and below.
    static let attachmentStripHeight = House.Control.chip + House.Spacing.xs * 2
    /// The strip at root: its divider plus the row.
    static let attachmentHeight = House.hairline + attachmentStripHeight
    /// The longest an attachment chip's name grows before it truncates in
    /// the middle (spec 3.10).
    static let attachmentNameMaxWidth: CGFloat = 180
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

    // MARK: - Local answer in root search

    /// The question chip over a local answer, as v1.3.0 drew it.
    static let rootAnswerChipHeight = House.Control.chip
    /// Space above the chip, between chip and answer, and below the answer.
    static let rootAnswerTopInset = House.Spacing.md
    static let rootAnswerGap = House.Spacing.xs
    static let rootAnswerBottomInset = House.Spacing.lg
    /// The answer's side inset, both sides.
    static let rootAnswerSideInset = House.Spacing.lg

    /// The width the local answer's text wraps at in a panel this wide.
    static func rootAnswerTextWidth(panelWidth: CGFloat) -> CGFloat {
        min(House.Layout.answerMaxWidth, panelWidth - rootAnswerSideInset * 2)
    }

    /// The local answer block under the input row: divider, chip, gap, the
    /// measured answer, and the insets around them.
    static func rootAnswerBlockHeight(answerHeight: CGFloat) -> CGFloat {
        House.hairline + rootAnswerTopInset + rootAnswerChipHeight + rootAnswerGap
            + answerHeight + rootAnswerBottomInset
    }

    /// Chrome around the chooser's row list: header row plus top/bottom padding.
    static let chooserChrome: CGFloat = House.Control.chip + House.Spacing.xs * 2

    /// The Transform chooser block height for `rows` options (the chooser
    /// replaces the launcher list while open).
    static func chooserBlockHeight(rows: Int) -> CGFloat {
        chooserChrome + actionListHeight(rows: rows, padded: false)
    }
    /// Add Context lists every row (seven at most, with Finder behind the
    /// overlay) instead of scrolling after six; four rows measure as the
    /// other choosers do.
    static func addContextListHeight(rows: Int) -> CGFloat {
        let count = max(1, rows)
        return CGFloat(count) * actionRowHeight + CGFloat(count - 1) * actionRowSpacing
    }
    static func addContextBlockHeight(rows: Int) -> CGFloat {
        chooserChrome + addContextListHeight(rows: rows)
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

    // MARK: - Quick AI size (user-resizable)

    /// What the user may drag the launcher panel between. Only the Quick AI
    /// surface (Recent Chats included) has limits; root search is measured,
    /// not user-sized, so the panel is not resizable there.
    struct ResizeLimits: Equatable, Sendable {
        let minimum: CGSize
        let maximum: CGSize

        /// A size the drag proposes, held between the limits.
        func clamp(_ size: CGSize) -> CGSize {
            CGSize(
                width: min(maximum.width, max(minimum.width, size.width)),
                height: min(maximum.height, max(minimum.height, size.height))
            )
        }

        /// A size a live drag proposes, held between the limits and inside
        /// `room`, how far the moving edges may go before they leave the
        /// display (`ScreenPlacement.dragRoom`). The display wins over the
        /// minimum.
        func clamp(_ size: CGSize, room: CGSize?) -> CGSize {
            let clamped = clamp(size)
            guard let room else { return clamped }
            return CGSize(
                width: min(clamped.width, room.width),
                height: min(clamped.height, room.height)
            )
        }
    }

    /// The largest Quick AI surface a display can hold: its visible frame
    /// less the placement margin on every side, never below the standard
    /// 750 × 475 (the surface keeps its minimum on a tiny display).
    static func quickAIMaximumSize(visibleFrame: CGRect) -> CGSize {
        let margin = ScreenPlacement.edgeMargin * 2
        return CGSize(
            width: max(QuickAISize.standard.width, visibleFrame.width - margin),
            height: max(QuickAISize.standard.height, visibleFrame.height - margin)
        )
    }

    /// The size the Quick AI surface is placed at on a display: the
    /// remembered size held between the drag limits, and never larger than
    /// the display holds. This is the size `ScreenPlacement.frameHanging`
    /// gives a Quick AI frame (`risingToFit`), so the resize pass compares
    /// the window with the frame it would apply: a stored size from a larger
    /// display is never re-applied on every observation tick.
    static func quickAIPlacedSize(_ size: CGSize, visibleFrame: CGRect) -> CGSize {
        let clamped = ResizeLimits(
            minimum: QuickAISize.standard.cgSize,
            maximum: quickAIMaximumSize(visibleFrame: visibleFrame)
        ).clamp(size)
        let margin = ScreenPlacement.edgeMargin * 2
        return CGSize(
            width: min(clamped.width, max(1, visibleFrame.width - margin)),
            height: min(clamped.height, max(1, visibleFrame.height - margin))
        )
    }

    /// The drag limits for the surface on screen: the standard Quick AI size
    /// to the display's maximum while Quick AI is up, none at root search.
    static func userResizeLimits(isQuickAIPresented: Bool, visibleFrame: CGRect) -> ResizeLimits? {
        guard isQuickAIPresented else { return nil }
        return ResizeLimits(
            minimum: QuickAISize.standard.cgSize,
            maximum: quickAIMaximumSize(visibleFrame: visibleFrame)
        )
    }

    /// The root launcher window. Answers never add to it: they live on the
    /// Quick AI surface, which has its own remembered size (`QuickAISize`).
    static func panelHeight(
        errorMessage: String?,
        suggestionCount: Int = 0,
        showsResultActions: Bool = false,
        hasAttachment: Bool = false,
        showsFooter: Bool = false,
        launcherRowCount: Int = 0,
        gridRows: Int = 0,
        gridSections: Int = 0,
        showsDetailPane: Bool = false
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
