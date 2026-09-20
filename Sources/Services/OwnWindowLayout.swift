import AppKit

/// Accessibility and CoreGraphics measure windows in a top-left global space
/// anchored on the primary display; AppKit measures them bottom-left. The
/// conversion lives here once, so the external window manager and the
/// own-window path below cannot drift apart on it.
enum AXSpace {
    /// The top edge of the primary display, which is where the top-left
    /// space is anchored.
    static var primaryTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// A display's usable area (no menu bar, no Dock) in the top-left space.
    static func axFrame(ofVisible screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.visibleFrame.minX,
            y: primaryTop - screen.visibleFrame.maxY,
            width: screen.visibleFrame.width,
            height: screen.visibleFrame.height
        )
    }

    static func axFrame(ofAppKit frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func appKitFrame(ofAX frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The window number of the ordinary window nearest the front, whoever
    /// owns it. Ordinary means layer zero and big enough to be a real
    /// window, which is the same test the external resolver uses; it leaves
    /// out the launcher panel, the Translator and Type to Click, which all
    /// float above layer zero.
    ///
    /// Unlike the external resolver this does *not* skip Quick Launch, which
    /// is the whole point: it is how the app recognises its own AI Chat
    /// window in front of everything else.
    static func topmostOrdinaryWindowNumber() -> Int? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  (bounds["Width"] as? NSNumber)?.doubleValue ?? 0 > 80,
                  (bounds["Height"] as? NSNumber)?.doubleValue ?? 0 > 40,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue
            else { continue }
            return number
        }
        return nil
    }
}

/// Lays out one window this app owns, through AppKit.
///
/// The window is resolved on every call rather than held, because the AI
/// Chat window is built on first open and must not be kept alive by this;
/// the provider closure captures its controller weakly.
///
/// A window's own minimum content size still wins: a third of a narrow
/// display can be narrower than `House.Layout.chatMinWidth`, and AppKit
/// clamps it. That matches the external path, which has always had to live
/// with the target app's minimum.
@MainActor
final class OwnWindowLayout: OwnWindowLaying {
    private let resolve: () -> NSWindow?
    /// What Quick Launch set last, for the half → two thirds → third cycle.
    private var lastApplied: (layout: WindowLayout, frame: CGRect)?
    /// The frame before the last change, for Restore.
    private var previousFrame: CGRect?

    init(window resolve: @escaping () -> NSWindow?) {
        self.resolve = resolve
    }

    var windowName: String { resolve()?.title ?? "the Quick Launch window" }

    var isFrontmost: Bool {
        guard let window = resolve(), window.isVisible, !window.isMiniaturized else { return false }
        return AXSpace.topmostOrdinaryWindowNumber() == window.windowNumber
    }

    func apply(_ layout: WindowLayout) -> Bool {
        guard let window = resolve() else { return false }
        let current = axFrame(of: window)
        guard let screen = screenFrame(containing: current) else { return false }
        let resolved = WindowCycling.next(
            requested: layout,
            lastLayout: lastApplied?.layout,
            lastFrame: lastApplied?.frame,
            current: current
        )
        return set(resolved.frame(in: screen), on: window, layout: resolved)
    }

    func move(_ move: WindowMove) -> Bool {
        guard let window = resolve() else { return false }
        let current = axFrame(of: window)
        switch move {
        case .toggleFullScreen:
            window.toggleFullScreen(nil)
            // Full screen is its own space; the cycle and the restore point
            // no longer describe anything.
            lastApplied = nil
            previousFrame = nil
            return true
        case .nextDisplay, .previousDisplay:
            let screens = NSScreen.screens.map(AXSpace.axFrame(ofVisible:))
            guard screens.count > 1 else { return false }
            let centre = CGPoint(x: current.midX, y: current.midY)
            let index = screens.firstIndex { $0.contains(centre) } ?? 0
            let destination = screens[move.targetIndex(current: index, count: screens.count)]
            return set(
                WindowMove.relocatedFrame(window: current, from: screens[index], to: destination),
                on: window,
                layout: nil
            )
        case .restore:
            guard let previousFrame else { return false }
            return set(previousFrame, on: window, layout: nil)
        default:
            guard let screen = screenFrame(containing: current),
                  let frame = move.adjustedFrame(window: current, screen: screen)
            else { return false }
            return set(frame, on: window, layout: nil)
        }
    }

    // MARK: - Setting

    private func set(_ frame: CGRect, on window: NSWindow, layout: WindowLayout?) -> Bool {
        // A full-screen window owns its space; resizing it is meaningless.
        guard !window.styleMask.contains(.fullScreen) else { return false }
        previousFrame = axFrame(of: window)
        window.setFrame(AXSpace.appKitFrame(ofAX: frame), display: true, animate: false)
        // What the window actually took, which is what the cycle must
        // compare against next time: AppKit clamps to the minimum size.
        lastApplied = layout.map { (layout: $0, frame: axFrame(of: window)) }
        // A layout brings the window forward, it never summons a closed one:
        // the command was aimed at a window already on screen.
        if window.isVisible { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: - Geometry

    private func axFrame(of window: NSWindow) -> CGRect {
        AXSpace.axFrame(ofAppKit: window.frame)
    }

    /// The usable area of the display holding most of `frame`, in the
    /// top-left space, falling back to the display under its centre.
    private func screenFrame(containing frame: CGRect) -> CGRect? {
        let candidates = NSScreen.screens.map(AXSpace.axFrame(ofVisible:))
        guard !candidates.isEmpty else { return nil }
        let best = candidates.max { lhs, rhs in
            lhs.intersection(frame).area < rhs.intersection(frame).area
        }
        if let best, best.intersection(frame).area > 0 { return best }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return candidates.first { $0.contains(centre) } ?? candidates.first
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
