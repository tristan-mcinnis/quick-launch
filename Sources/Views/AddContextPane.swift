import SwiftUI
import Combine
import HouseDesign

/// Add Context: the four captures, then, with an attachment tray, File…,
/// Link…, and Finder Selection (only when Finder is behind the overlay).
/// Opened by the control left of the composer or by typing `@`. Link…
/// turns the pane into a one-line field: `↩` attaches, `esc` goes back.
struct AddContextPane: View {
    @Bindable var viewModel: QuickViewModel
    /// Nil falls back to the environment's, then to the view model's own
    /// (`QuickViewModel.attachmentTray`).
    var tray: AttachmentTray? = nil
    @Environment(\.attachmentTray) private var environmentTray
    @FocusState private var linkFocused: Bool
    @FocusState private var searchFocused: Bool

    private var activeTray: AttachmentTray? { tray ?? environmentTray ?? viewModel.attachmentTray }

    /// The rows in order: the view model's captures, then, when files and
    /// links can be attached, File…, Link…, and Finder Selection.
    static func rows(captures: [AddContextEntry], tray: AttachmentTray?) -> [AddContextRow] {
        guard let tray else { return captures.map(AddContextRow.capture) }
        return AddContextRow.menu(captures: captures, finderIsBehind: tray.finderIsBehind)
    }

    var body: some View {
        Group {
            if viewModel.isClipboardHistoryOpen {
                ClipboardHistoryPane(viewModel: viewModel)
            } else if let tray = activeTray, tray.isEnteringLink {
                linkEntry(tray)
            } else {
                rowList
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attach")
        .onDisappear { activeTray?.cancelLinkEntry() }
    }

    private var rowList: some View {
        // The view model's own list, after the pane's search filter: the
        // drawn rows and the keys' highlight index the same array.
        let rows = viewModel.addContextRows
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Text("Attach")
                    .font(AQDesign.TypeToken.section)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                Text("Add context, then ask a question")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(1)
                Spacer()
                KeyHint(label: "Move", keys: ["↑", "↓"])
                KeyHint(label: QuickViewModel.addContextConfirmTitle, keys: ["↩"])
                KeyHint(label: "Close", keys: ["esc"])
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.top, AQDesign.Space.standard)

            // The pane's own search, as the ⌘K palette has: it takes the
            // keyboard on open, so typing narrows the rows instead of
            // reaching the composer behind them.
            HStack(spacing: AQDesign.Space.row) {
                Image(systemName: "magnifyingglass")
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityHidden(true)
                TextField("Search context…", text: $viewModel.addContextQuery)
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.body)
                    .focused($searchFocused)
                    .onSubmit { Task { await viewModel.runAddContextSelection() } }
                    .onKeyPress(.downArrow) { viewModel.moveAddContextSelection(1); return .handled }
                    .onKeyPress(.upArrow) { viewModel.moveAddContextSelection(-1); return .handled }
                    .accessibilityLabel("Search context")
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .frame(height: PanelSizing.paneSearchRowHeight)

            SelectableListPane(
                items: rows,
                selectedIndex: $viewModel.addContextIndex,
                rowHeight: AQDesign.rowHeight,
                emptyText: "No matching context",
                scrollsToSelection: true,
                onActivate: { row in activate(row) }
            ) { _, row, _ in
                HStack(spacing: AQDesign.Space.row) {
                    IconTile {
                        Image(systemName: row.systemImage)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    }
                    Text(row.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                    Text(row.detail)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                    Spacer()
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
        .onAppear { FocusRequest.apply($searchFocused) }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in
            // Back from the Link field lands in the search, never on the
            // composer behind the pane.
            guard !viewModel.attachmentTray.isEnteringLink else { return }
            FocusRequest.apply($searchFocused)
        }
    }

    private func activate(_ row: AddContextRow) {
        if row.opensClipboardHistory {
            viewModel.openClipboardHistory()
            return
        }
        if let entry = row.capture {
            Task { await viewModel.addContext(entry) }
            return
        }
        guard let tray = activeTray else { return }
        if tray === viewModel.attachmentTray {
            // The view model runs its own rows: File… through the open
            // panel, Finder Selection, and Link… as the field.
            viewModel.runAddContextRow(row)
            return
        }
        tray.run(row, clipboard: NSPasteboard.general.string(forType: .string))
        // File… and Finder Selection hand over to their owner; the menu's
        // work is done. Link… stays open as its field.
        if row != .link { viewModel.closeAddContextMenu() }
    }

    // MARK: - Link…

    private func linkEntry(_ tray: AttachmentTray) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Text("Add Link")
                    .font(AQDesign.TypeToken.section)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                Spacer()
                KeyHint(label: "Attach", keys: ["↩"])
                KeyHint(label: "Back", keys: ["esc"])
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.top, AQDesign.Space.standard)

            HStack(spacing: AQDesign.Space.standard) {
                Image(systemName: "link")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .accessibilityHidden(true)
                TextField(
                    text: Binding(
                        get: { tray.linkDraft ?? "" },
                        set: { tray.linkDraft = $0 }
                    ),
                    prompt: Text("")
                ) {
                    Text("Link")
                }
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(AQDesign.TypeToken.body)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .focused($linkFocused)
                // A styled prompt takes the field's ink on macOS; the
                // placeholder is drawn over the empty field instead.
                .overlay(alignment: .leading) {
                    if (tray.linkDraft ?? "").isEmpty {
                        Text("Paste a link")
                            .font(AQDesign.TypeToken.body)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onSubmit {
                    if tray.submitLinkEntry() { viewModel.closeAddContextMenu() }
                }
                .onExitCommand { goBack(tray) }
                .accessibilityLabel("Link")
            }
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: House.Control.pill)
            .overlay(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .strokeBorder(
                        linkFocused ? AQDesign.ColorToken.panelStrokeStrong : AQDesign.ColorToken.panelStroke,
                        lineWidth: AQDesign.hairline
                    )
            )
            .padding(.horizontal, AQDesign.Space.standard)
            .padding(.top, AQDesign.Space.standard)

            if let notice = tray.notice {
                Text(notice)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, AQDesign.Space.panel)
                    .padding(.top, AQDesign.Space.standard)
            }
        }
        .padding(.bottom, AQDesign.Space.standard)
        .onAppear { FocusRequest.apply($linkFocused) }
    }

    private func goBack(_ tray: AttachmentTray) {
        tray.cancelLinkEntry()
        viewModel.requestInputFocus()
    }
}
