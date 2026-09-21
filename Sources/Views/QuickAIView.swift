import AppKit
import SwiftUI

/// Quick AI, after Raycast's: a `panelWidth` × `quickAIHeight` surface
/// that replaces the launcher in place. The user can drag the window larger
/// (the size is remembered, `QuickAISize`); the header and composer span
/// the window, and the thread stays one centred column as wide as the
/// standard surface's, so lines stay readable. A header (back chevron,
/// conversation title over the model, expand glyph), the scrolling thread
/// (user turns as pills on the right, answers as prose on the left, one
/// tool or status line, the question card when the model asks), and the
/// composer row along the bottom edge: the Add Context circle, the pill
/// field with the primary action inside it, and the `⌘K` circle. There is
/// no footer well; the composer row is the footer.
///
/// Every chooser that floats over the launcher floats here too, anchored
/// above the composer. The field keeps focus the whole time the surface is
/// open, streaming included.
struct QuickAIView: View {
    @Bindable var viewModel: QuickViewModel
    var onComposerHeightChange: ((CGFloat) -> Void)? = nil
    @State private var composerHeight = Self.composerRowHeight
    @State private var surfaceHeight = PanelSizing.quickAIHeight

    /// The composer row from the panel's bottom edge: the pill-high row plus
    /// its inset above and below. The floating `⌘K` pane and the choosers
    /// sit on top of it.
    static let composerRowHeight = House.Control.pill + House.Spacing.xs * 2

    /// The header row. Raycast's is 60 tall; the nearest house control
    /// height is the input row.
    static let headerHeight = House.Control.input

    /// The thread's column: the width it has on the standard 750-wide
    /// surface, inside the `Spacing.lg` gutters. A window dragged wider
    /// centres this column instead of stretching it, so answer lines stay
    /// at `quickAIAnswerMaxWidth` and user pills end at the column's right
    /// edge, exactly as at 750.
    static let threadColumnWidth = PanelSizing.panelWidth - House.Spacing.lg * 2

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if viewModel.isRecentChatsPresented {
                    RecentChatsList(viewModel: viewModel)
                } else {
                    QuickAIThread(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            QuickAIComposer(viewModel: viewModel)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    composerHeight = height
                    onComposerHeightChange?(height)
                }
        }
        // Fills the window: 750 × 475 at the least, as large as the user
        // drags it. A fixed frame would pin the hosting view and stop the
        // drag.
        .frame(
            minWidth: PanelSizing.panelWidth,
            maxWidth: .infinity,
            minHeight: PanelSizing.quickAIHeight,
            maxHeight: .infinity
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { surfaceHeight = $0 }
        .overlay(alignment: .bottom) {
            QuickAIFloatingChooser(viewModel: viewModel, composerHeight: composerHeight)
                .environment(\.composerPaneMaximumHeight,
                    max(0, surfaceHeight - composerHeight - Self.headerHeight - House.Spacing.xs))
        }
        .onChange(of: viewModel.threadError) { _, error in
            guard let error else { return }
            QuickAIAnnouncement.post("Error. \(error.message)", priority: .high)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick AI")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: House.Spacing.sm) {
            // The chevron is the quiet one: secondary ink, a step smaller
            // than the expand glyph, as in Raycast.
            QuickAIGlyphButton(
                symbol: "chevron.left",
                font: AQDesign.TypeToken.glyphSmall,
                color: AQDesign.ColorToken.textSecondary,
                label: "Back to search",
                help: "Back to search, keeping this chat (esc)"
            ) {
                viewModel.closeQuickAI()
            }
            QuickAITitleBlock(viewModel: viewModel)
            Spacer(minLength: House.Spacing.sm)
            // Recent Chats, one click away. The list, its keys and its menu
            // row all existed and were still undiscoverable, so the header
            // carries a visible way in. It toggles: while the list is up the
            // same control returns to the thread.
            if viewModel.canOpenRecentChats || viewModel.isRecentChatsPresented {
                QuickAIGlyphButton(
                    symbol: viewModel.isRecentChatsPresented
                        ? "bubble.left.and.text.bubble.right"
                        : "clock.arrow.circlepath",
                    font: AQDesign.TypeToken.label,
                    color: AQDesign.ColorToken.textSecondary,
                    label: viewModel.isRecentChatsPresented ? "Back to chat" : "Recent Chats",
                    help: viewModel.isRecentChatsPresented
                        ? "Back to chat (esc)"
                        : "Recent Chats (\(viewModel.shortcutLabel(for: .recentChats)))"
                ) {
                    viewModel.toggleRecentChats()
                }
                .accessibilityValue(viewModel.isRecentChatsPresented ? "Open" : "Closed")
            }
            // Raycast's expand glyph is a boxed up-right arrow; this is the
            // nearest SF Symbol. As in Raycast it moves the chat to the AI
            // Chat window (`⌘J`), a labelled button with its key, so moving a
            // longer conversation is one obvious click. In Recent Chats it
            // moves the highlighted chat, as `⌘J` does.
            Button {
                viewModel.continueInAIChat()
            } label: {
                HStack(spacing: House.Spacing.xs) {
                    Image(systemName: "arrow.up.right.square")
                        .font(AQDesign.TypeToken.label)
                    Text(ResultAction.continueInAIChat.title)
                        .font(AQDesign.TypeToken.label)
                    KeyCapGroup(keys: viewModel.shortcutKeyCaps(for: .continueInAIChat))
                }
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .padding(.horizontal, House.Spacing.sm)
                .frame(height: House.Control.chip)
                .background(
                    RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                        .fill(AQDesign.ColorToken.chipFill)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ResultAction.continueInAIChat.title)
            .help("\(ResultAction.continueInAIChat.title) (\(viewModel.shortcutLabel(for: .continueInAIChat)))")
        }
        // A tighter left inset than right: with the compact button and the
        // row gap, the title starts where Raycast's does.
        .padding(.leading, House.Spacing.sm)
        .padding(.trailing, House.Spacing.lg)
        .frame(height: Self.headerHeight)
    }
}

// MARK: - Recent Chats

/// `⌘P`: the recent chat list in place of the thread. One column of the
/// launcher's own chat rows (the Chats catalog rows: icon tile, title,
/// question count and time), pinned first, narrowed by what the composer
/// holds; `↑↓` move, `↩` opens the chat in the thread, `esc` clears the
/// search and then returns to the thread.
private struct RecentChatsList: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        let items = viewModel.recentChatItems
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                SectionLabel(text: "Recent Chats")
                Spacer()
                KeyHint(label: "Move", keys: ["↑", "↓"])
                KeyHint(label: "Open", keys: ["↩"])
                // Escape clears a search before it leaves the list.
                KeyHint(label: viewModel.input.isEmpty ? "Back" : "Clear", keys: ["esc"])
            }
            .padding(.horizontal, House.Spacing.lg)
            .padding(.vertical, House.Spacing.xs)

            SelectableListPane(
                items: items,
                selectedIndex: $viewModel.recentChatsIndex,
                rowSpacing: PanelSizing.actionRowSpacing,
                rowHeight: House.Control.row,
                listInsets: EdgeInsets(
                    top: House.Spacing.xs,
                    leading: House.Spacing.sm,
                    bottom: House.Spacing.xs,
                    trailing: House.Spacing.sm
                ),
                emptyText: viewModel.input.isEmpty ? "No chats yet" : "No chats match",
                scrollsToSelection: true,
                onActivate: open
            ) { index, item, isSelected in
                LauncherResultRow(
                    result: .item(item),
                    isSelected: isSelected,
                    position: index + 1,
                    total: items.count
                )
                .padding(.horizontal, House.Spacing.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent Chats")
    }

    private func open(_ item: LauncherCatalogItem) {
        viewModel.recentChatsIndex = viewModel.recentChatItems.firstIndex { $0.id == item.id } ?? 0
        viewModel.openSelectedRecentChat()
    }
}

// MARK: - Change Assistant

/// ⌘K › Change Assistant (`⌥⌘A`): No Assistant, then every assistant, with
/// its alias and tools. ↑↓ move, Return picks, Esc closes. Floats above the
/// composer, like the model chooser.
struct AssistantChooserPane: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        let options = viewModel.assistantChooserOptions
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Text(ResultAction.changeAssistant.title)
                    .font(AQDesign.TypeToken.section)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                Spacer()
                KeyHint(label: "Move", keys: ["↑", "↓"])
                KeyHint(label: QuickViewModel.assistantChooserConfirmTitle, keys: ["↩"])
                KeyHint(label: "Close", keys: ["esc"])
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.top, AQDesign.Space.standard)

            SelectableListPane(
                items: options,
                selectedIndex: $viewModel.assistantChooserIndex,
                rowHeight: AQDesign.rowHeight,
                scrollsToSelection: true,
                onActivate: { option in
                    // A click picks the row it lands on, not the keyed one.
                    if let index = options.firstIndex(of: option) {
                        viewModel.assistantChooserIndex = index
                    }
                    viewModel.runAssistantChooserSelection()
                }
            ) { _, option, _ in
                HStack(spacing: AQDesign.Space.row) {
                    IconTile {
                        Image(systemName: option.assistantID == nil
                              ? "bubble.left"
                              : ResultAction.changeAssistant.systemImage)
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
            .modifier(ComposerPaneListHeight(preferredHeight: PanelSizing.actionListHeight(rows: options.count, padded: false)))
            .padding(.horizontal, AQDesign.Space.standard)
            .padding(.bottom, AQDesign.Space.standard)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ResultAction.changeAssistant.title)
    }
}
