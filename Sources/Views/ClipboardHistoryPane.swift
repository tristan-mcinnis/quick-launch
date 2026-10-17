import SwiftUI
import HouseDesign

/// The Clipboard History submenu inside Add Context. Its rows are the app's
/// own clipboard catalog, so each carries the type and pinned metadata the
/// store already made; the store has already dropped concealed and transient
/// copies and never keeps anything the pasteboard marked private.
///
/// Keyboard-first, one continuous flow with Add Context: typing searches,
/// the arrows move, Return attaches the highlighted item, Escape goes back to
/// the Add Context rows. Attaching never sends and never touches the draft.
struct ClipboardHistoryPane: View {
    @Bindable var viewModel: QuickViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchRow
            list
        }
        .onAppear { FocusRequest.apply($searchFocused) }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in
            FocusRequest.apply($searchFocused)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard History")
    }

    private var header: some View {
        HStack(spacing: AQDesign.Space.row) {
            Button {
                viewModel.closeClipboardHistory()
            } label: {
                Image(systemName: "chevron.left")
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .frame(width: AQDesign.controlHeight, height: AQDesign.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Attach")
            Text("Clipboard History")
                .font(AQDesign.TypeToken.section)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
            Text("Text, images, or files you copied")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
            Spacer()
            KeyHint(label: "Move", keys: ["↑", "↓"])
            KeyHint(label: "Attach", keys: ["↩"])
            KeyHint(label: "Back", keys: ["esc"])
        }
        .padding(.horizontal, AQDesign.Space.panel)
        .padding(.top, AQDesign.Space.standard)
    }

    private var searchRow: some View {
        HStack(spacing: AQDesign.Space.row) {
            Image(systemName: "magnifyingglass")
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .accessibilityHidden(true)
            TextField("Search clipboard…", text: $viewModel.clipboardHistoryQuery)
                .textFieldStyle(.plain)
                .font(AQDesign.TypeToken.body)
                .focused($searchFocused)
                .onSubmit { Task { await viewModel.runClipboardHistorySelection() } }
                .onKeyPress(.downArrow) { viewModel.moveClipboardHistorySelection(1); return .handled }
                .onKeyPress(.upArrow) { viewModel.moveClipboardHistorySelection(-1); return .handled }
                .onExitCommand { viewModel.closeClipboardHistory() }
                .accessibilityLabel("Search clipboard history")
        }
        .padding(.horizontal, AQDesign.Space.panel)
        .frame(height: PanelSizing.paneSearchRowHeight)
    }

    private var list: some View {
        let rows = viewModel.clipboardHistoryRows
        return SelectableListPane(
            items: rows,
            selectedIndex: $viewModel.clipboardHistoryIndex,
            rowHeight: AQDesign.rowHeight,
            emptyText: viewModel.clipboardHistoryQuery.isEmpty
                ? "Nothing on the clipboard yet"
                : "No matching clipboard items",
            scrollsToSelection: true,
            onActivate: { _ in
                Task { await viewModel.runClipboardHistorySelection() }
            }
        ) { _, item, _ in
            HStack(spacing: AQDesign.Space.row) {
                IconTile {
                    Image(systemName: item.systemImage)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                }
                VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                    Text(item.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                    Text(item.detail)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        .accessibilityLabel("Pinned")
                }
            }
            .padding(.horizontal, AQDesign.Space.row)
            .contentShape(Rectangle())
        }
        .modifier(ComposerPaneListHeight(
            preferredHeight: PanelSizing.addContextListHeight(rows: rows.count),
            chromeHeight: PanelSizing.chooserChrome + PanelSizing.paneSearchRowHeight
        ))
        .padding(.horizontal, AQDesign.Space.standard)
        .padding(.bottom, AQDesign.Space.standard)
    }
}
