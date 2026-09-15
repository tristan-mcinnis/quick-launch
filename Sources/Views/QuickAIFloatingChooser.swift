import SwiftUI

/// The Transform chooser, the model chooser, Change Assistant, and Add
/// Context, floating above the composer. Shared by the Quick AI surface and
/// the AI Chat window.
struct QuickAIFloatingChooser: View {
    @Bindable var viewModel: QuickViewModel
    var composerHeight: CGFloat = QuickAIView.composerRowHeight

    // MARK: - Floating choosers

    /// The Transform chooser, the model chooser, and Add Context float above
    /// the composer here, where at root they sit inline under the input row.
    var body: some View {
        if viewModel.isTransformChooserPresented
            || viewModel.isModelChooserPresented
            || viewModel.isAssistantChooserPresented
            || viewModel.isAddContextMenuPresented {
            Group {
                if viewModel.isTransformChooserPresented {
                    TransformChooserPane(viewModel: viewModel)
                } else if viewModel.isModelChooserPresented {
                    ModelChooserPane(viewModel: viewModel)
                } else if viewModel.isAssistantChooserPresented {
                    AssistantChooserPane(viewModel: viewModel)
                } else {
                    AddContextPane(viewModel: viewModel)
                }
            }
            // The window's full inner width, at any size.
            .frame(maxWidth: .infinity)
            .panelGlass(radius: AQDesign.cardCornerRadius)
            .panelShadows()
            .padding(.horizontal, House.Spacing.xs)
            .padding(.bottom, composerHeight)
        }
    }
}
