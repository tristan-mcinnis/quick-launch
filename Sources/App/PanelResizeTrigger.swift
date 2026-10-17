import Foundation
import CoreGraphics
import Observation

/// What starts a panel resize pass. Only state that sets the window's
/// height or width is read here: the selected row and a streaming answer
/// are not, so arrowing through the list and a growing answer leave the
/// window alone.
@MainActor
enum PanelResizeTrigger {
    /// A shrink waits this long while the panel is visible, so a transition
    /// that dips and grows back (submit clears the list, then streams)
    /// never moves the window. Growth cancels it.
    static let shrinkHold: Duration = .milliseconds(50)

    /// Passes started since launch. A test seam: it counts the changes that
    /// start a pass, synchronously, without waiting on the run loop.
    private(set) static var passCount = 0

    enum Step: Equatable {
        /// Grow or change width now, and drop any pending shrink.
        case applyNow
        /// Shorter than the window: wait `shrinkHold`, growth cancels it.
        case holdShrink
        case none
    }

    /// The frame is compared with a 1 pt tolerance on both axes.
    static func step(frameHeight: CGFloat, frameWidth: CGFloat, targetHeight: CGFloat, targetWidth: CGFloat) -> Step {
        if targetHeight > frameHeight + 1 || abs(frameWidth - targetWidth) > 1 { return .applyNow }
        if targetHeight < frameHeight - 1 { return .holdShrink }
        return .none
    }

    static func arm(viewModel: QuickViewModel, onChange: @escaping @Sendable () -> Void) {
        withObservationTracking { [weak viewModel] in
            guard let viewModel else { return }
            _ = viewModel.errorMessage
            _ = viewModel.isActionPalettePresented
            _ = viewModel.isTransformChooserPresented
            // The model chooser and the Add Context menu are inline blocks on
            // the root surface: each one changes the window height. The Quick
            // AI surface (and Recent Chats inside it) is the size the user
            // left it at; nothing on it is measured, so a streamed answer
            // (`output`, `isStreaming`) does not start a pass.
            _ = viewModel.isModelChooserPresented
            _ = viewModel.isAddContextMenuPresented
            _ = viewModel.isQuickAIPresented
            _ = viewModel.isRecentChatsPresented
            // The remembered Quick AI size: a finished drag and Reset
            // Quick AI Size both land here.
            _ = viewModel.quickAISize
            _ = viewModel.modelChooserOptions.count
            _ = viewModel.addContextOptions.count
            _ = viewModel.isApplicationActionPanePresented
            _ = viewModel.isCatalogActionPanePresented
            _ = viewModel.catalogScope
            _ = viewModel.actionQuery
            _ = viewModel.input
            _ = viewModel.pendingImage
            _ = viewModel.activeItemActionForm
            _ = viewModel.deleteArmedItemID
            _ = viewModel.lastQuestion
            _ = viewModel.pendingContext
            // The selected row matters only when it opens or closes the
            // detail pane (a width change), never per arrow press.
            _ = viewModel.selectionShowsDetailPane
            _ = viewModel.screenshotIndexProgress
            _ = viewModel.screenshotFiles
            _ = viewModel.clipboardEntries
            _ = viewModel.settings.showMenuBar
        } onChange: {
            MainActor.assumeIsolated { passCount += 1 }
            onChange()
        }
    }
}
