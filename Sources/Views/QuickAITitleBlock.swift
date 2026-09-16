import AppKit
import SwiftUI

/// The chat title over the model line, as the Quick AI header draws it and
/// the AI Chat window's header reuses it: the title in `subheading`, then
/// the assistant's name (a button for Change Assistant) and the model (a
/// button for Change Model), or the source of an answer that is not the
/// model's.
struct QuickAITitleBlock: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            Text(viewModel.quickAITitle)
                .font(AQDesign.TypeToken.subheading)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let source = viewModel.answerSourceTitle {
                // A command's output or a Vault Search is not the model's:
                // the line names where the answer came from.
                Text(source)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Source: \(source)")
            } else {
                HStack(spacing: House.Spacing.xxs) {
                    // An assistant chat names its assistant ahead of the
                    // model, in full ink: the name opens Change Assistant.
                    if let assistant = viewModel.activeAssistant {
                        assistantName(assistant.name)
                        Text("·")
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .accessibilityHidden(true)
                    }
                    // The model line is a button: it opens the model chooser
                    // to change the model for the next message.
                    Button {
                        viewModel.toggleModelChooserFromHeader()
                    } label: {
                        Text(viewModel.activeModelDisplay)
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Model: \(viewModel.activeModelDisplay)")
                    .accessibilityHint("Change the model")
                    .accessibilityValue(viewModel.isModelChooserPresented ? "Open" : "Closed")
                    .help("Change model (\(viewModel.shortcutLabel(for: .changeModel)))")
                }
            }
        }
    }

    /// The assistant's name on the model line: a button for Change
    /// Assistant, never truncated ahead of the model.
    private func assistantName(_ name: String) -> some View {
        Button {
            viewModel.toggleAssistantChooser()
        } label: {
            Text(name)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Assistant: \(name)")
        .accessibilityHint("Change the assistant")
        .accessibilityValue(viewModel.isAssistantChooserPresented ? "Open" : "Closed")
        .help("Change assistant (\(viewModel.shortcutLabel(for: .changeAssistant)))")
    }
}

/// A header glyph button: a `Control.compact` square around one symbol.
struct QuickAIGlyphButton: View {
    let symbol: String
    let font: Font
    let color: Color
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(color)
                .frame(width: House.Control.compact, height: House.Control.compact)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(help)
    }
}

/// A VoiceOver announcement from the Quick AI surfaces.
enum QuickAIAnnouncement {
    @MainActor
    static func post(_ text: String, priority: NSAccessibilityPriorityLevel) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: priority.rawValue,
            ]
        )
    }
}
