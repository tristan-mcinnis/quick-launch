import CoreFoundation

/// Pure layout calculation for the Quick Launch overlay panel height.
/// Extracted from AppDelegate so it can be unit-tested without AppKit
/// and reused by the observation-driven resize path.
enum PanelSizing {

    static let inputHeight: CGFloat = 60
    static let maxBodyHeight: CGFloat = 560
    static let errorBannerHeight: CGFloat = 40
    static let attachmentHeight: CGFloat = 58
    /// Footer row plus its divider.
    static let footerHeight: CGFloat = AQDesign.footerHeight + 1
    /// Vertical inset around the launcher rows.
    static let launcherListInset: CGFloat = 12
    /// A preview plus its Information block needs this much room.
    static let detailPaneMinimumHeight: CGFloat = 360

    static func panelHeight(
        output: String,
        isStreaming: Bool,
        errorMessage: String?,
        actionCount: Int = 0,
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
        if actionCount > 0 {
            total += 76 + min(CGFloat(actionCount), 6) * 42
        }
        if gridRows > 0 {
            total += CGFloat(gridRows) * 52 + CGFloat(gridSections) * 24 + launcherListInset
        } else if actionCount == 0, suggestionCount > 0 {
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
