import CoreFoundation

/// Pure layout calculation for the Quick Launch overlay panel height.
/// Extracted from AppDelegate so it can be unit-tested without AppKit
/// and reused by the observation-driven resize path.
enum PanelSizing {

    // MARK: - Widths

    /// Raycast Beta uses a calmer, wider search canvas. Keep enough room for
    /// title, metadata, and two visible actions without crowding.
    static let panelWidth: CGFloat = 720
    /// A preview-worthy catalog with its detail pane beside the list.
    static let panelWidthWithDetail: CGFloat = 960
    /// A Quick AI thread gets a little more room so answers read like a
    /// document rather than a strip.
    static let panelWidthForAnswer: CGFloat = 800

    // MARK: - Heights

    static let inputHeight: CGFloat = 60
    static let maxBodyHeight: CGFloat = 640
    /// Horizontal padding around the answer body (20pt each side); the
    /// measured markdown width is the panel width minus this.
    static let answerHorizontalPadding: CGFloat = 40
    /// Compact earlier-turns transcript shown above the latest answer.
    static let transcriptHeight: CGFloat = 240
    static let errorBannerHeight: CGFloat = 40
    static let attachmentHeight: CGFloat = 58
    /// One row in the ⌘K pane and the prompt palette.
    static let actionRowHeight: CGFloat = 42
    /// LazyVStack spacing between action rows.
    static let actionRowSpacing: CGFloat = 2
    /// Rows shown before the action list scrolls.
    static let actionVisibleRows = 6
    /// Title row at the top of the ⌘K item pane.
    static let paneHeaderHeight: CGFloat = 44
    /// Search field row at the bottom of the ⌘K item pane.
    static let paneSearchRowHeight: CGFloat = 40
    /// Gap between the floating pane's bottom edge and the window edge.
    static let paneBottomMargin: CGFloat = 12
    /// Footer row plus its divider.
    static let footerHeight: CGFloat = AQDesign.footerHeight + 1
    /// Vertical inset around the launcher rows.
    static let launcherListInset: CGFloat = 12
    /// The launcher list's chrome above and below the rows: the section
    /// header ("Results") plus the bottom inset, as measured from the
    /// rendered view. Counting only the rows left the last one clipped.
    static let launcherListChrome: CGFloat = 26
    /// The search row and footer stay pinned while long result sets scroll.
    static let launcherListMaximumHeight: CGFloat = 504
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
            + (padded ? 12 : 0)
    }

    /// ⌘K item pane: header 44 + divider + list + divider + search row 40.
    static func itemActionPaneHeight(rows: Int) -> CGFloat {
        paneHeaderHeight + 1 + actionListHeight(rows: rows) + 1 + paneSearchRowHeight
    }

    /// ⌘K pane showing a form instead of the list. Each form knows its own
    /// body height; sizing never names a feature.
    static func itemActionFormPaneHeight(form: ItemActionForm) -> CGFloat {
        form.minimumPaneHeight
    }

    /// Prompt palette: search row 42 + spacing + list + spacing + hint row 26.
    static func actionPaletteHeight(rows: Int) -> CGFloat {
        42 + 8 + actionListHeight(rows: rows, padded: false) + 8 + 26
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
            total += CGFloat(gridRows) * 52 + CGFloat(gridSections) * 24 + launcherListInset
        } else if suggestionCount > 0 {
            var block = min(CGFloat(suggestionCount), 12) * 42
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
