import CoreFoundation

/// Pure layout calculation for the apfel-quick overlay panel height.
/// Extracted from AppDelegate so it can be unit-tested without AppKit
/// and reused by the observation-driven resize path.
enum PanelSizing {

    static let inputHeight: CGFloat = 60
    static let maxBodyHeight: CGFloat = 380
    static let errorBannerHeight: CGFloat = 40

    static func panelHeight(
        output: String,
        isStreaming: Bool,
        errorMessage: String?,
        actionCount: Int = 0,
        suggestionCount: Int = 0,
        showsResultActions: Bool = false
    ) -> CGFloat {
        var total = inputHeight
        if actionCount > 0 {
            total += 76 + min(CGFloat(actionCount), 6) * 42
        }
        if actionCount == 0, suggestionCount > 0 {
            total += min(CGFloat(suggestionCount), 6) * 42
        }
        if !output.isEmpty || isStreaming {
            let approxLines = max(1, output.count / 60 + 1)
            let bodyHeight = min(maxBodyHeight, CGFloat(approxLines) * 22 + 40)
            total += bodyHeight
        }
        if errorMessage != nil {
            total += errorBannerHeight
        }
        if showsResultActions {
            total += AQDesign.controlHeight + 1
        }
        return total
    }
}
