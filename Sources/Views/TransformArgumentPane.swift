import SwiftUI

/// The Transform argument field: a required `{argument}` slot of a saved
/// transform that has no default and no options, typed in its own field so the
/// composer draft and the attached source are untouched. Return takes the
/// value (an empty Return is refused, never substituted), Escape cancels.
///
/// The field is a real text field, so IME composition owns the Return that
/// commits a candidate: that Return never reaches the submit path.
struct TransformArgumentPane: View {
    @Bindable var viewModel: QuickViewModel
    @FocusState private var fieldFocused: Bool

    private var title: String {
        viewModel.transformArgumentPrompt.map { "Enter \($0)" } ?? "Enter a value"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Text(title)
                    .font(AQDesign.TypeToken.section)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                Spacer()
                KeyHint(label: "Next", keys: ["↩"])
                KeyHint(label: "Cancel", keys: ["esc"])
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.top, AQDesign.Space.standard)

            HStack(spacing: AQDesign.Space.row) {
                Image(systemName: "text.cursor")
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityHidden(true)
                TextField("Type a value…", text: $viewModel.transformArgumentInput)
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.body)
                    .focused($fieldFocused)
                    .onSubmit { Task { await viewModel.submitTransformArgument() } }
                    .onExitCommand { viewModel.cancelTransformArguments() }
                    .accessibilityLabel(viewModel.transformArgumentPrompt ?? "Argument value")
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .frame(height: PanelSizing.paneSearchRowHeight)
        }
        .onAppear { FocusRequest.apply($fieldFocused) }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in
            FocusRequest.apply($fieldFocused)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transform argument")
    }
}
