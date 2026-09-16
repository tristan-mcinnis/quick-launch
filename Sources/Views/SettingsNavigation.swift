import SwiftUI

/// The Settings reveal a search result asks for: which pane, which group
/// anchor inside it, and a token so asking for the same anchor twice scrolls
/// again instead of being treated as no change.
struct SettingsFocus: Equatable, Hashable, Sendable {
    let pane: SettingsPane
    let anchor: String
    let token: Int

    init(pane: SettingsPane, anchor: String, token: Int = 0) {
        self.pane = pane
        self.anchor = anchor
        self.token = token
    }
}

private struct SettingsFocusKey: EnvironmentKey {
    static let defaultValue: SettingsFocus? = nil
}

extension EnvironmentValues {
    /// The group the active pane should reveal. Set once by `SettingsView`
    /// on the pane content; read by `SettingsAnchorModifier` (highlight) and
    /// `SettingsPaneScroller` (scroll).
    var settingsFocus: SettingsFocus? {
        get { self[SettingsFocusKey.self] }
        set { self[SettingsFocusKey.self] = newValue }
    }
}

/// Wraps a pane's scroll content so a searched destination can be scrolled
/// into view. The pane's own `ScrollView` is replaced by this; keep the
/// content's padding inside.
struct SettingsPaneScroller<Content: View>: View {
    let pane: SettingsPane
    @Environment(\.settingsFocus) private var focus
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content()
            }
            .task(id: focus) {
                guard let focus, focus.pane == pane, !focus.anchor.isEmpty else { return }
                // The addressed card may be laid out a turn after the pane
                // appears; one short yield is enough for `scrollTo` to land.
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(focus.anchor, anchor: .top)
                }
            }
        }
    }
}

/// Marks a card (or row) as a search destination and lights it briefly when
/// Settings search just revealed it.
private struct SettingsAnchorModifier: ViewModifier {
    let id: String
    var radius: CGFloat = AQDesign.cardCornerRadius
    @Environment(\.settingsFocus) private var focus

    private var isHighlighted: Bool {
        guard let focus, !id.isEmpty else { return false }
        return focus.anchor == id
    }

    func body(content: Content) -> some View {
        content
            .id(id)
            .overlay {
                if isHighlighted {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(AQDesign.ColorToken.accent, lineWidth: 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isHighlighted)
    }
}

extension View {
    /// Address this card or row from Settings search. The id must be unique
    /// within its pane and match a `SettingsDestination.anchor`.
    func settingsAnchor(_ id: String, radius: CGFloat = AQDesign.cardCornerRadius) -> some View {
        modifier(SettingsAnchorModifier(id: id, radius: radius))
    }
}
