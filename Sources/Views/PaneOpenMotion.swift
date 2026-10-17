import SwiftUI

/// DESIGN.md Motion.open: a pane that appears fades in over 0.12 s with a
/// 0.98 to 1 scale. Reduce Motion keeps the fade and drops the scale, and
/// the appearance is never delayed: the pane is in the layout at once, so
/// focus and panel sizing do not wait on the animation.
enum PaneOpenMotion: Equatable {
    case fadeAndScale
    case fadeOnly

    static let startScale: CGFloat = 0.98

    static func style(reduceMotion: Bool) -> PaneOpenMotion {
        reduceMotion ? .fadeOnly : .fadeAndScale
    }

    var transition: AnyTransition {
        switch self {
        case .fadeAndScale: .opacity.combined(with: .scale(scale: Self.startScale))
        case .fadeOnly: .opacity
        }
    }

    static var animation: Animation { .easeOut(duration: AQDesign.Motion.open) }
}

private struct PaneOpenTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(PaneOpenMotion.style(reduceMotion: reduceMotion).transition)
    }
}

private struct PaneOpenAnimation<V: Equatable>: ViewModifier {
    let value: V

    // Reduce Motion still fades, so the animation stays on; only the
    // transition drops its scale.
    func body(content: Content) -> some View {
        content.animation(PaneOpenMotion.animation, value: value)
    }
}

extension View {
    /// Marks a conditionally shown pane, strip or badge as one that opens
    /// with `PaneOpenMotion`. Pair it with `paneOpenAnimation(value:)` on
    /// the container whose condition changes.
    func paneOpenTransition() -> some View { modifier(PaneOpenTransition()) }

    /// Animates the insertion and removal of `paneOpenTransition()` children
    /// when `value` changes.
    func paneOpenAnimation<V: Equatable>(value: V) -> some View {
        modifier(PaneOpenAnimation(value: value))
    }
}
