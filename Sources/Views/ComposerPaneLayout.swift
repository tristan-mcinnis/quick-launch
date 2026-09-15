import SwiftUI

extension EnvironmentValues {
    /// Space above the complete composer, excluding the surface header.
    /// Root search does not impose a composer-specific limit.
    @Entry var composerPaneMaximumHeight: CGFloat? = nil
}

/// Only the rows shrink; the pane's heading, search field, and key hints stay
/// visible. SelectableListPane already scrolls and follows keyboard selection.
struct ComposerPaneListHeight: ViewModifier {
    let preferredHeight: CGFloat
    var chromeHeight: CGFloat = PanelSizing.chooserChrome
    @Environment(\.composerPaneMaximumHeight) private var maximumHeight

    func body(content: Content) -> some View {
        content.frame(height: maximumHeight.map {
            min(preferredHeight, max(0, $0 - chromeHeight))
        } ?? preferredHeight)
    }
}
