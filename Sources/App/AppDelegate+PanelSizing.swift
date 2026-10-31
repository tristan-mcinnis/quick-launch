import AppKit
import Darwin
import SwiftUI
import HouseDesign

extension AppDelegate {
    // MARK: - Panel auto-resize observer

    /// Observe the QuickViewModel reactively (Observation framework) and resize
    /// the panel only when something that sets its height or width changes
    /// (`PanelResizeTrigger` lists them).
    /// Replaces an earlier 80ms polling loop that kept the menu bar app at
    /// 7-8% CPU even when idle (issue #24).
    func startPanelSizeObserver(viewModel: QuickViewModel) {
        resizePanelForContent()
        armPanelSizeObserver(viewModel: viewModel)
    }

    private func armPanelSizeObserver(viewModel: QuickViewModel) {
        PanelResizeTrigger.arm(viewModel: viewModel) { [weak self, weak viewModel] in
            // Observation calls this before the new value lands (willSet), so
            // the pass cannot run on this stack: it would read the old state.
            // The main-actor hop runs when this run-loop turn's main queue
            // drains, which is before Core Animation commits the turn's
            // layout, so growth still reaches the window in the same frame.
            Task { @MainActor in
                guard let self, let viewModel else { return }
                self.syncStatusItemVisibilityAndPresentation(viewModel: viewModel)
                self.resizePanelForContent()
                self.armPanelSizeObserver(viewModel: viewModel)
            }
        }
    }

    private func resizePanelForContent() {
        guard let panel, let vm = viewModel else { return }
        // The user is dragging the Quick AI surface's edges: the content
        // must not fight the drag. The size lands when the drag ends
        // (`windowDidEndLiveResize`), and the next pass agrees with it.
        guard !panel.inLiveResize else { return }
        syncPanelResizeLimits()
        // The Quick AI size is held to the display first, so a stored size
        // from a larger display compares equal to the frame the display
        // already capped and is not re-applied on every tick.
        let target = targetPanelSize(vm)
        let total = target.height
        let width = target.width
        let frame = panel.frame
        let step = PanelResizeTrigger.step(frameHeight: frame.height, frameWidth: frame.width, targetHeight: total, targetWidth: width)
        if step == .applyNow {
            // Growth (and width changes) apply on the spot.
            panelShrinkTask?.cancel()
            panelShrinkTask = nil
            applyPanelFrame(height: total, width: width)
        } else if step == .holdShrink {
            // Shrinks wait one beat while the panel is visible: transitions
            // pass through short-lived states (submit clears the list before
            // streaming starts), and applying those made the window dip and
            // then grow back. A growth within the beat cancels the shrink.
            guard panel.isVisible else {
                applyPanelFrame(height: total, width: width)
                return
            }
            panelShrinkTask?.cancel()
            panelShrinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: PanelResizeTrigger.shrinkHold)
                guard !Task.isCancelled, let self, let vm = self.viewModel else { return }
                self.panelShrinkTask = nil
                let target = self.targetPanelSize(vm)
                self.applyPanelFrame(height: target.height, width: target.width)
            }
        }
    }

    private func applyPanelFrame(height: CGFloat, width: CGFloat) {
        guard let panel, !panel.inLiveResize else { return }
        var frame = panel.frame
        guard abs(frame.height - height) > 1 || abs(frame.width - width) > 1 else { return }
        let centreX = frame.midX
        if let panelAnchor {
            // Hang from the fixed top edge: only the bottom moves. A Quick
            // AI surface the user sized taller than the room under the
            // anchor rises to fit instead of being cut. Root search (and
            // Quick AI back at 750 × 475) centres on the anchor: a drag of
            // one edge moved the frame's centre, and root must not follow.
            frame = panelAnchor.frame(
                width: width,
                height: height,
                current: frame,
                keepsCurrentCentre: viewModel?.keepsUserSizedFrame == true,
                risingToFit: viewModel?.isQuickAIPresented == true
            )
        } else {
            let delta = height - frame.height
            frame.size.height = height
            frame.size.width = width
            frame.origin.x = (centreX - width / 2).rounded()
            frame.origin.y -= delta  // grow down from the top
            if let screen = panel.screen ?? screenContainingMouse() {
                frame = ScreenPlacement.clamped(frame: frame, within: screen.visibleFrame)
            }
        }
        panel.setFrame(frame, display: true, animate: false)
    }

    /// The drag limits for the surface on screen, on the display the panel
    /// hangs on: the Quick AI range while that surface is up, nil at root
    /// search.
    private var panelResizeLimits: PanelSizing.ResizeLimits? {
        guard let vm = viewModel, let visibleFrame = panelVisibleFrame else { return nil }
        return PanelSizing.userResizeLimits(
            isQuickAIPresented: vm.isQuickAIPresented,
            visibleFrame: visibleFrame
        )
    }

    /// The display the panel hangs on: the anchor's, fixed at show time.
    /// Every Quick AI size and frame decision reads this one display, so
    /// the limits, the drag, and the frame pass never disagree.
    private var panelVisibleFrame: CGRect? {
        guard let panel else { return nil }
        return panelAnchor?.visibleFrame
            ?? (panel.screen ?? screenContainingMouse())?.visibleFrame
    }

    /// The display a live drag happens on: the one the panel is on now (the
    /// user may have moved it there by its background), else the anchor's.
    /// The drag limits stay the anchor's, so a size stored from the drag
    /// always matches the frame the next resize pass would apply.
    private var panelDragVisibleFrame: CGRect? {
        panel?.screen?.visibleFrame ?? panelVisibleFrame
    }

    /// The window size for the surface on screen: the measured root size,
    /// or the Quick AI size held to the display.
    func targetPanelSize(_ vm: QuickViewModel) -> CGSize {
        let requested = CGSize(width: vm.currentPanelWidth, height: targetPanelHeight(vm))
        guard vm.isQuickAIPresented, let visibleFrame = panelVisibleFrame else { return requested }
        return PanelSizing.quickAIPlacedSize(requested, visibleFrame: visibleFrame)
    }

    /// Resizable between the Quick AI limits while that surface is up, not
    /// resizable at root search.
    func syncPanelResizeLimits() {
        panel?.applyUserResizeLimits(panelResizeLimits)
    }

    // MARK: - NSWindowDelegate (the launcher panel)

    /// A drag on the Quick AI surface's edges starts: note which edges
    /// move (from where the pointer is) and how far each may go before it
    /// leaves the display. AppKit does not keep a borderless window's edges
    /// off the Dock or the menu bar.
    func windowWillStartLiveResize(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel,
              viewModel?.isQuickAIPresented == true,
              let visibleFrame = panelDragVisibleFrame
        else {
            liveResizeRoom = nil
            return
        }
        let edges = ScreenPlacement.DragEdges(pointer: NSEvent.mouseLocation, frame: panel.frame)
        liveResizeRoom = ScreenPlacement.dragRoom(from: panel.frame, moving: edges, within: visibleFrame)
    }

    /// The drag's last word on size, beside `minSize` and `maxSize`: the
    /// hosting view's own constraints must never carry the surface past
    /// the display or under 750 × 475, and the moving edges stop at the
    /// display's margin. Only a user's drag is clamped; every other resize
    /// (the content's own, AppKit's) passes untouched.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let panel, sender === panel, panel.inLiveResize,
              let limits = panelResizeLimits
        else { return frameSize }
        return limits.clamp(frameSize, room: liveResizeRoom)
    }

    /// A drag on the Quick AI surface's edges ended: fit the frame inside
    /// the display (a backstop for the drag clamp above), then remember the
    /// size, so the next open and the next launch use it. Root search is
    /// never resizable, and the view model ignores a size off the Quick AI
    /// surface anyway.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        liveResizeRoom = nil
        guard let vm = viewModel, vm.isQuickAIPresented else { return }
        var frame = panel.frame
        if let visibleFrame = panelDragVisibleFrame {
            let fitted = ScreenPlacement.clamped(frame: frame, within: visibleFrame)
            if fitted != frame {
                panel.setFrame(fitted, display: true, animate: false)
                frame = fitted
            }
        }
        vm.rememberQuickAISize(frame.size)
    }

    private func targetPanelHeight(_ vm: QuickViewModel) -> CGFloat {
        // Base height as if no pane were floating: the launcher list stays
        // fully visible behind the ⌘K pane, so opening or closing a pane
        // does not move the window unless the pane itself needs more room.
        // The math lives on the view model so the render-proof tests hold
        // the drawn view and the window to the same numbers.
        vm.estimatedWindowHeight
    }
}
