import Foundation

/// Lays out one of Quick Launch's *own* windows: the AI Chat window today.
///
/// `WindowManaging` cannot do this. Its target is always an external
/// application, because the resolver behind it skips this process on purpose
/// (`SelectedTextService.closestExternalWindowTarget`), and Accessibility is
/// the wrong actuator for an app's own window in any case: the supported
/// call is `NSWindow.setFrame`.
///
/// The geometry is shared, not copied: `WindowLayout`, `WindowMove` and
/// `WindowCycling` decide the frame for an own window exactly as they do for
/// an external one, so half, two thirds, third, the sixths and the cycling
/// behave identically wherever the window belongs.
@MainActor
protocol OwnWindowLaying: AnyObject {
    /// The window is on screen, not minimised, and is the ordinary window
    /// nearest the front. A layout command belongs to it then, whichever
    /// surface asked for it.
    var isFrontmost: Bool { get }
    /// What to call the window in an error line.
    var windowName: String { get }
    @discardableResult func apply(_ layout: WindowLayout) -> Bool
    @discardableResult func move(_ move: WindowMove) -> Bool
}
