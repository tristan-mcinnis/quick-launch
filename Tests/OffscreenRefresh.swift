import AppKit

/// What a screen refresh does for a window that is on screen: lay out and
/// draw whatever is pending. The hosted test windows are never shown, so no
/// refresh comes; on a busy main thread a scroll the view asked for could
/// then wait with nothing left to apply it, and a test would see the view
/// stuck where it was. Waits that read a hosted view's scroll position call
/// this on each poll.
@MainActor
enum OffscreenRefresh {
    static func tick(_ window: NSWindow) {
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
}
