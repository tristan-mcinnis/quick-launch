import SwiftUI

/// Review Changes: the original text the transform ran on beside the text it
/// proposed, with Copy, Cancel, and Accept. Shown only for a saved transform
/// whose output behaviour is "Review before replacing"; nothing is written
/// until Accept, and Accept runs the same fail-closed live-selection check
/// every Replace Selection uses (a changed or unreadable selection copies
/// instead and says so).
///
/// Both sides are bounded and scroll, so a long multi-line or CJK source stays
/// readable in either appearance.
struct TransformReviewPane: View {
    @Bindable var viewModel: QuickViewModel

    private static let columnHeight = PanelSizing.reviewColumnHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            columns
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Review changes")
    }

    private var header: some View {
        HStack(spacing: AQDesign.Space.row) {
            Text("Review changes")
                .font(AQDesign.TypeToken.section)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
            if let review = viewModel.pendingTransformReview {
                Text(TransformReview.summary(original: review.original, proposed: review.proposed))
                    .font(House.TypeToken.meta)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
                if let app = review.sourceApp, !app.isEmpty {
                    Text("from \(app)")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            KeyHint(label: "Copy", keys: ["⌘", "C"])
            if viewModel.pendingTransformReview?.target != nil {
                KeyHint(label: "Accept", keys: ["↩"])
            }
            KeyHint(label: "Cancel", keys: ["esc"])
        }
        .padding(.horizontal, AQDesign.Space.panel)
        .padding(.top, AQDesign.Space.standard)
    }

    private var columns: some View {
        let original = TransformReview.bounded(viewModel.pendingTransformReview?.original ?? "")
        let proposed = TransformReview.bounded(viewModel.pendingTransformReview?.proposed ?? "")
        return HStack(alignment: .top, spacing: AQDesign.Space.standard) {
            column(title: "Original", bounded: original)
            column(title: "Proposed", bounded: proposed)
        }
        .padding(.horizontal, AQDesign.Space.standard)
        .padding(.top, AQDesign.Space.standard)
    }

    private func column(title: String, bounded: TransformReview.Bounded) -> some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
            Text(title)
                .font(House.TypeToken.meta)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
            ScrollView {
                Text(bounded.text)
                    .font(AQDesign.TypeToken.body)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(House.Spacing.xxs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(House.Spacing.sm)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.columnHeight)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .fill(House.ColorToken.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .strokeBorder(House.ColorToken.stroke, lineWidth: House.hairline)
            )
            if bounded.isTruncated {
                Text("Showing the first \(TransformReview.shownCharacters.formatted()) of \(bounded.text.count + bounded.omittedCharacters) characters.")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var footer: some View {
        // Accept writes back only when the review is bound to the live
        // selection it ran on. An attached or clipboard source offers Copy
        // instead, never a replacement into an unrelated app.
        let canReplace = viewModel.pendingTransformReview?.target != nil
        return HStack(spacing: House.Spacing.sm) {
            if !canReplace {
                Text("Ran on an attached source; the result copies.")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Cancel") { viewModel.cancelTransformReview() }
                .buttonStyle(CardButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Keep the result on screen; replace nothing")
            Button("Copy") { viewModel.copyTransformReview() }
                .buttonStyle(CardButtonStyle(prominent: !canReplace))
                .keyboardShortcut("c", modifiers: .command)
                .help("Copy the proposed text")
            if canReplace {
                Button("Accept") {
                    Task { _ = await viewModel.acceptTransformReview() }
                }
                .buttonStyle(CardButtonStyle(prominent: true))
                .help("Replace the selection with the proposed text")
            }
        }
        .padding(.horizontal, AQDesign.Space.standard)
        .padding(.vertical, AQDesign.Space.standard)
    }
}

/// The review pane's buttons: `Control.chip` high at `Radius.tile`. The
/// prominent one is an ink fill with inverse ink, never accent; the others
/// are outlined like key caps.
struct CardButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.tile, style: .continuous)
        configuration.label
            .font(House.TypeToken.label)
            .foregroundStyle(prominent ? House.ColorToken.textInverse : House.ColorToken.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: House.Control.chip)
            .background {
                if prominent {
                    shape.fill(House.ColorToken.textPrimary)
                } else {
                    shape.fill(configuration.isPressed ? House.ColorToken.selectionFill : House.ColorToken.keyCapFill)
                    shape.strokeBorder(House.ColorToken.keyCapStroke, lineWidth: House.hairline)
                }
            }
            .opacity(configuration.isPressed && prominent ? 0.8 : (isEnabled ? 1 : 0.45))
            .contentShape(shape)
    }
}
