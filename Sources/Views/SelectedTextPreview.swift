import SwiftUI

/// Full, in-memory text behind a selected-text chip. Reading this preview
/// never fetches a new selection and never submits a question.
struct SelectedTextPreview: View {
    let text: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            Text(title)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
            ScrollView {
                Text(text)
                    .font(House.TypeToken.body)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: House.Control.input * 5)
            .accessibilityLabel("Complete selected text")
            Text("\(text.count.formatted()) characters · Included with your next message")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textPrimary)
        }
        .padding(House.Spacing.md)
        .frame(width: House.Layout.chatRail * 2)
        .background(House.ColorToken.surface)
    }
}

/// The same preview affordance for the launch snapshot and an explicitly
/// attached selection. The native popover owns Escape and restores focus.
struct SelectedTextPreviewButton: View {
    let text: String
    let title: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Preview", systemImage: "doc.text.magnifyingglass")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textPrimary)
                .padding(.horizontal, House.Spacing.xs)
                .frame(height: House.Control.chip)
                .background(House.ColorToken.chipFill, in: RoundedRectangle(cornerRadius: House.Radius.sm))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("i", modifiers: [.command, .option])
        .help("Read the complete selected text (⌥⌘I)")
        .accessibilityLabel("Preview selected text")
        .popover(isPresented: $isPresented) {
            SelectedTextPreview(text: text, title: title)
        }
    }
}
