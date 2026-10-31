import SwiftUI
import Combine
import HouseDesign

/// A local answer in root search, as v1.3.0 drew an answer under the input
/// row: the question as a chip, the answer as prose under it. Math, a
/// conversion, a date, or a system fact; never a model answer.
struct RootAnswerBlock: View {
    let answer: QuickViewModel.RootAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: PanelSizing.rootAnswerGap) {
            HouseChip(text: answer.question)
                .frame(height: PanelSizing.rootAnswerChipHeight)
                .accessibilityLabel("Question: \(answer.question)")
            MarkdownTextView(
                markdown: answer.answer,
                isStreaming: false,
                scrolls: false,
                instanceID: "local-answer"
            )
            .frame(
                maxWidth: PanelSizing.rootAnswerTextWidth(panelWidth: PanelSizing.panelWidth),
                alignment: .leading
            )
            .accessibilityLabel("Answer: \(answer.answer)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PanelSizing.rootAnswerSideInset)
        .padding(.top, PanelSizing.rootAnswerTopInset)
        .padding(.bottom, PanelSizing.rootAnswerBottomInset)
        .accessibilityElement(children: .contain)
    }
}

/// The selected text captured at launch: its title, a preview, the Transform
/// control, and a remove button.
struct LaunchSelectionStrip: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        HStack(spacing: AQDesign.Space.standard) {
            Image(systemName: "text.cursor")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
            VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
                Text(viewModel.launchSelectionTitle)
                    .font(AQDesign.TypeToken.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(viewModel.launchSelectionPreview)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: AQDesign.Space.standard)
            if let selection = viewModel.launchSelection {
                SelectedTextPreviewButton(text: selection.text, title: viewModel.launchSelectionTitle)
            }
            if !viewModel.chipTransformOptions.isEmpty {
                Button {
                    viewModel.toggleTransformChooser()
                } label: {
                    Label("Transform", systemImage: "wand.and.stars")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        .padding(.horizontal, AQDesign.Space.standard)
                        .frame(height: AQDesign.controlHeight)
                        .background(
                            RoundedRectangle(
                                cornerRadius: AQDesign.fieldCornerRadius,
                                style: .continuous
                            )
                            .fill(AQDesign.ColorToken.chipFill)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Transform selected text")
                .help("Transform the selected text (\(viewModel.shortcutLabel(for: .transformChooser)))")
            }
            Button {
                viewModel.clearLaunchSelection()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: AQDesign.controlHeight, height: AQDesign.controlHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove selected text")
            .help("Remove the selected text from the next request")
        }
        .padding(.horizontal, AQDesign.Space.panel)
        .padding(.vertical, AQDesign.Space.standard)
    }
}

/// Keyboard-first Transform chooser: ↑↓ move, Return runs, Esc closes.
/// Opened by the Transform chip or ⌘⌥T. Every row is a saved rewrite action
/// (or the Translator) acting on the captured selection snapshot. Inline
/// under the root input row; floating above the Quick AI composer.
struct TransformChooserPane: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Text(viewModel.transformChooserTitle)
                    .font(AQDesign.TypeToken.section)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                Spacer()
                KeyHint(label: "Move", keys: ["↑", "↓"])
                KeyHint(label: QuickViewModel.transformChooserConfirmTitle, keys: ["↩"])
                KeyHint(label: "Close", keys: ["esc"])
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.top, AQDesign.Space.standard)

            SelectableListPane(
                items: viewModel.transformChooserOptions,
                selectedIndex: $viewModel.transformChooserIndex,
                rowHeight: AQDesign.rowHeight,
                scrollsToSelection: true,
                onActivate: { _ in
                    Task { await viewModel.runTransformChooserSelection() }
                }
            ) { _, option, isSelected in
                HStack(spacing: AQDesign.Space.row) {
                    IconTile {
                        Image(systemName: option.systemImage)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    }
                    Text(option.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, AQDesign.Space.row)
                .contentShape(Rectangle())
            }
            .modifier(ComposerPaneListHeight(
                preferredHeight: PanelSizing.actionListHeight(rows: viewModel.transformChooserOptions.count, padded: false)
            ))
            .padding(.horizontal, AQDesign.Space.standard)
            .padding(.bottom, AQDesign.Space.standard)
        }
        .accessibilityElement(children: .contain)
    }
}

/// The keyboard model chooser (`⇧⌘R`, Change Model): ↑↓ move, Return picks,
/// Esc closes. Inline under the root input row; floating above the Quick AI
/// composer.
struct ModelChooserPane: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Text(viewModel.modelChooserPurpose.title)
                    .font(AQDesign.TypeToken.section)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                Spacer()
                KeyHint(label: "Move", keys: ["↑", "↓"])
                KeyHint(label: viewModel.modelChooserPurpose.confirmTitle, keys: ["↩"])
                KeyHint(label: "Close", keys: ["esc"])
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.top, AQDesign.Space.standard)

            SelectableListPane(
                items: viewModel.modelChooserOptions,
                selectedIndex: $viewModel.modelChooserIndex,
                rowHeight: AQDesign.rowHeight,
                scrollsToSelection: true,
                onActivate: { _ in
                    Task { await viewModel.runModelChooserSelection() }
                }
            ) { _, option, _ in
                HStack(spacing: AQDesign.Space.row) {
                    IconTile {
                        Image(systemName: "cpu")
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    }
                    Text(option.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                    Text(option.detail)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, AQDesign.Space.row)
                .contentShape(Rectangle())
            }
            .modifier(ComposerPaneListHeight(
                preferredHeight: PanelSizing.actionListHeight(rows: viewModel.modelChooserOptions.count, padded: false)
            ))
            .padding(.horizontal, AQDesign.Space.standard)
            .padding(.bottom, AQDesign.Space.standard)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(viewModel.modelChooserPurpose.title)
    }
}

/// Capture chooser: the four captures only, in the order `⇧⌘S` lists them
/// (Selected Text first), and only the ones this surface can run. Opened by
/// `⇧⌘S`; Return attaches exactly the highlighted capture. Files, links, and
/// Finder Selection are Add Context's (`⇧⌘A`), never this pane's.
struct CaptureChooserPane: View {
    @Bindable var viewModel: QuickViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let rows = viewModel.captureChooserOptions
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Text("Capture")
                    .font(AQDesign.TypeToken.section)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                Text("What to attach")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(1)
                Spacer()
                KeyHint(label: "Move", keys: ["↑", "↓"])
                KeyHint(label: "Attach", keys: ["↩"])
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
                TextField("Search captures…", text: $viewModel.captureChooserQuery)
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.body)
                    .focused($searchFocused)
                    .onSubmit { Task { await viewModel.runCaptureChooserSelection() } }
                    .onKeyPress(.downArrow) { viewModel.moveCaptureChooserSelection(1); return .handled }
                    .onKeyPress(.upArrow) { viewModel.moveCaptureChooserSelection(-1); return .handled }
                    .accessibilityLabel("Search captures")
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .frame(height: PanelSizing.paneSearchRowHeight)

            SelectableListPane(
                items: rows,
                selectedIndex: $viewModel.captureChooserIndex,
                rowHeight: AQDesign.rowHeight,
                emptyText: "No matching captures",
                scrollsToSelection: true,
                onActivate: { entry in
                    // A click attaches the row it lands on, not whichever row
                    // the keyboard last highlighted.
                    if let index = rows.firstIndex(of: entry) {
                        viewModel.captureChooserIndex = index
                    }
                    Task { await viewModel.runCaptureChooserSelection() }
                }
            ) { _, entry, _ in
                HStack(spacing: AQDesign.Space.row) {
                    IconTile {
                        Image(systemName: entry.systemImage)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    }
                    Text(entry.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                    Text(entry.detail)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Capture")
        .onAppear { FocusRequest.apply($searchFocused) }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in
            // The composer behind must not take the keys back while the
            // chooser is up; a Back from a deeper field lands here.
            FocusRequest.apply($searchFocused)
        }
    }
}
