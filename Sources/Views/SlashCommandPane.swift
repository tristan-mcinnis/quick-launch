import SwiftUI

/// The composer's `/` palette, drawn in the chooser slot above the field.
///
/// Unlike the other four panes it has no search field of its own. The draft
/// *is* the search: the user is typing a command, the `/` stays where they
/// typed it, and the rows narrow as they go. So the composer keeps the
/// keyboard throughout, and Return takes the highlighted row into the draft
/// rather than sending it, which leaves room for an argument and keeps a
/// destructive `/clear` two keystrokes away rather than one.
struct SlashCommandPane: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        let rows = viewModel.slashCommandMatches
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Text("Commands")
                    .font(AQDesign.TypeToken.section)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                Text("Keep typing to narrow")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(1)
                Spacer()
                KeyHint(label: "Move", keys: ["↑", "↓"])
                KeyHint(label: "Use", keys: ["↩"])
                KeyHint(label: "Close", keys: ["esc"])
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.top, AQDesign.Space.standard)
            .padding(.bottom, AQDesign.Space.row)

            SelectableListPane(
                items: rows,
                selectedIndex: $viewModel.slashCommandIndex,
                rowHeight: AQDesign.rowHeight,
                emptyText: "No matching command",
                scrollsToSelection: true,
                onActivate: { command in
                    viewModel.completeSlashCommand(command)
                }
            ) { _, command, _ in
                HStack(spacing: AQDesign.Space.row) {
                    IconTile {
                        Image(systemName: command.systemImage)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    }
                    Text(viewModel.settings.savedPromptPrefix + command.name)
                        .font(AQDesign.TypeToken.code)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                    Text(command.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: AQDesign.Space.row)
                    Text(command.kindLabel)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, AQDesign.Space.row)
                .contentShape(Rectangle())
            }
            .modifier(ComposerPaneListHeight(
                preferredHeight: PanelSizing.addContextListHeight(rows: rows.count),
                chromeHeight: PanelSizing.chooserChrome
            ))
            .padding(.horizontal, AQDesign.Space.standard)
            .padding(.bottom, AQDesign.Space.standard)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commands")
    }
}
