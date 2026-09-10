import SwiftUI

/// Fallback Commands: the commands unmatched root-search text runs on Return,
/// in order. The first one runs; the rest are the ranking behind it.
///
/// The list is ordered and edited in place: drag a row, or use its move
/// buttons, because a drag-only control is not reachable from the keyboard.
/// Removing every row is allowed and means something: Return then runs
/// nothing, which the note under the list says in as many words.
struct FallbackCommandsView: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        SettingsCard("Fallback Commands") {
            SettingsRow(
                title: "Run on Return",
                detail: "Unmatched text runs the first command. Drag a row to reorder it, or use its arrows.",
                isFirst: true
            ) {
                addMenu
            }

            ForEach(
                Array(viewModel.fallbackCommandEntries.enumerated()),
                id: \.element.id
            ) { index, entry in
                row(entry, index: index)
            }

            CardNote {
                CardText(listNote)
            }
        }
    }

    private var listNote: String {
        viewModel.fallbackCommandEntries.isEmpty
            ? "Nothing is listed, so Return on text that matches no row does nothing at all. Tab still opens Quick AI. Add a command to give unmatched text something to run."
            : "The first command runs. Tab opens Quick AI whatever this list holds."
    }

    private var addMenu: some View {
        Menu {
            ForEach(viewModel.fallbackCommandChoiceGroups) { group in
                Section(group.title) {
                    ForEach(group.choices) { choice in
                        Button(choice.title) { viewModel.addFallbackCommand(choice.id) }
                    }
                }
            }
        } label: {
            Label("Add command", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(viewModel.fallbackCommandChoiceGroups.isEmpty)
        .accessibilityLabel("Add a fallback command")
    }

    private func row(_ entry: QuickViewModel.FallbackCommandEntry, index: Int) -> some View {
        let entries = viewModel.fallbackCommandEntries
        return VStack(spacing: 0) {
            if index > 0 { HouseDivider() }
            HStack(spacing: House.Spacing.sm) {
                Image(systemName: "line.3.horizontal")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .frame(width: 14)
                    .contentShape(Rectangle())
                    .draggable(entry.id)
                    .accessibilityHidden(true)
                IconTile {
                    Image(systemName: entry.systemImage)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.detail)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: House.Spacing.sm)
                controls(for: entry, index: index, count: entries.count)
            }
            .frame(minHeight: AQDesign.rowHeight)
            .dropDestination(for: String.self) { identifiers, _ in
                guard let identifier = identifiers.first, identifier != entry.id else {
                    return false
                }
                viewModel.moveFallbackCommand(identifier, toIndex: index)
                return true
            }
        }
    }

    private func controls(
        for entry: QuickViewModel.FallbackCommandEntry,
        index: Int,
        count: Int
    ) -> some View {
        HStack(spacing: AQDesign.Space.standard) {
            arrow(
                "chevron.up",
                label: "Move \(entry.title) up",
                enabled: index > 0
            ) {
                viewModel.moveFallbackCommand(entry.id, toIndex: index - 1)
            }

            arrow(
                "chevron.down",
                label: "Move \(entry.title) down",
                enabled: index < count - 1
            ) {
                viewModel.moveFallbackCommand(entry.id, toIndex: index + 1)
            }

            Button {
                viewModel.removeFallbackCommand(entry.id)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(entry.title)")
        }
        .font(AQDesign.TypeToken.caption)
        .foregroundStyle(AQDesign.ColorToken.textSecondary)
        .frame(minHeight: AQDesign.tileSize)
    }

    /// One arrow button. The row's own `foregroundStyle` would otherwise hide
    /// the disabled state, so a disabled arrow is also drawn back.
    private func arrow(
        _ systemImage: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}
