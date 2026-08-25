import CoreFoundation

/// Pure layout calculation for the Quick Launch overlay panel height.
/// Extracted from AppDelegate so it can be unit-tested without AppKit
/// and reused by the observation-driven resize path.
enum PanelSizing {

    static let inputHeight: CGFloat = 60
    static let maxBodyHeight: CGFloat = 560
    static let errorBannerHeight: CGFloat = 40
    static let attachmentHeight: CGFloat = 58
    /// One row in the ⌘K pane and the prompt palette.
    static let actionRowHeight: CGFloat = 42
    /// LazyVStack spacing between action rows.
    static let actionRowSpacing: CGFloat = 2
    /// Rows shown before the action list scrolls.
    static let actionVisibleRows = 6
    /// Gap between the floating pane's bottom edge and the window edge.
    static let paneBottomMargin: CGFloat = 12
    /// Footer row plus its divider.
    static let footerHeight: CGFloat = AQDesign.footerHeight + 1
    /// Vertical inset around the launcher rows.
    static let launcherListInset: CGFloat = 12
    /// The search row and footer stay pinned while long result sets scroll.
    static let launcherListMaximumHeight: CGFloat = 504
    /// A preview plus its Information block needs this much room.
    static let detailPaneMinimumHeight: CGFloat = 360
    /// Keeps the exact payload preview and its primary action visible. The
    /// payload body scrolls within this fixed production budget.
    static let screenHistorySaveMinimumHeight: CGFloat = 620

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
            + (padded ? 12 : 0)
    }

    /// ⌘K item pane: header 44 + divider + list + divider + search row 40.
    static func itemActionPaneHeight(rows: Int) -> CGFloat {
        44 + 1 + actionListHeight(rows: rows) + 1 + 40
    }

    /// ⌘K pane showing a form instead of the list: header 44 + divider + body.
    static func itemActionFormPaneHeight(form: ItemActionForm) -> CGFloat {
        switch form {
        case .edit: 44 + 1 + 240
        case .alias, .hotkey: 44 + 1 + 130
        case .screenHistorySave: screenHistorySaveMinimumHeight - inputHeight - paneBottomMargin
        }
    }

    /// Prompt palette: search row 42 + spacing + list + spacing + hint row 26.
    static func actionPaletteHeight(rows: Int) -> CGFloat {
        42 + 8 + actionListHeight(rows: rows, padded: false) + 8 + 26
    }

    /// The window keeps its base height while a pane floats over it; it only
    /// grows when the pane (input row + pane + margin) needs more room.
    static func windowHeight(base: CGFloat, paneHeight: CGFloat?) -> CGFloat {
        guard let paneHeight else { return base }
        return max(base, inputHeight + paneHeight + paneBottomMargin)
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
        showsDetailPane: Bool = false
    ) -> CGFloat {
        var total = inputHeight
        if hasAttachment { total += attachmentHeight }
        if gridRows > 0 {
            total += CGFloat(gridRows) * 52 + CGFloat(gridSections) * 24 + launcherListInset
        } else if suggestionCount > 0 {
            var block = min(CGFloat(suggestionCount), 12) * 42
            if launcherRowCount > 0 { block += launcherListInset }
            if showsDetailPane { block = max(block, detailPaneMinimumHeight) }
            total += block
        }
        if !output.isEmpty || isStreaming {
            let approxLines = max(1, output.count / 60 + 1)
            let bodyHeight = min(maxBodyHeight, CGFloat(approxLines) * 22 + 40)
            total += bodyHeight
            if showsQuestion { total += 24 }
        }
        if errorMessage != nil {
            total += errorBannerHeight
        }
        if showsResultActions {
            total += AQDesign.controlHeight + 1
        }
        if showsFooter {
            total += footerHeight
        }
        return total
    }
}
