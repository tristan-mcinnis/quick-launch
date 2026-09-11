import AppKit
import SwiftUI

/// The AI Chat window: one conversation window over the same providers and
/// tools as Quick AI. Its thread and composer are Quick AI's own views
/// (`QuickAIThread`, `QuickAIComposer`), on the window's own view model;
/// the window adds a header with the chat-list and new-chat buttons, a
/// multi-line composer, find in chat (`⌘F`), and the chat list rail, hidden
/// until `⌘\` or the header button slides it in.
///
/// Settings shell geometry (DESIGN.md): an opaque `surface` ground, the rail
/// `Layout.chatRail` wide on `surfaceSunken`, rows `Control.row` high with
/// the house selection. The title bar is transparent, so the header shares
/// its row with the window's traffic lights.
struct AIChatWindowView: View {
    @Bindable var model: AIChatWindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room for the traffic lights at the window's top-left, which sit in
    /// the header row (or the rail's top row while the rail is out).
    static let trafficLightInset = House.Spacing.xxxxl + House.Spacing.xl
    /// The unified toolbar's title-bar row, which the header shares.
    static let titleBarHeight = House.Control.composer

    private var chat: QuickViewModel { model.chat }

    var body: some View {
        HStack(spacing: 0) {
            if model.isRailVisible {
                AIChatRail(model: model)
                    .frame(width: House.Layout.chatRail)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                Rectangle()
                    .fill(AQDesign.ColorToken.divider)
                    .frame(width: AQDesign.hairline)
                    .accessibilityHidden(true)
            }
            conversation
        }
        .frame(
            minWidth: House.Layout.chatMinWidth,
            maxWidth: .infinity,
            minHeight: House.Layout.chatMinHeight,
            maxHeight: .infinity
        )
        .background(AQDesign.ColorToken.windowSurface)
        // The header shares the title-bar row with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeOut(duration: AQDesign.Motion.select), value: model.isRailVisible)
        .preferredColorScheme(chat.settings.appearance.swiftUIColorScheme)
        .onChange(of: chat.threadError) { _, error in
            guard let error else { return }
            QuickAIAnnouncement.post("Error. \(error.message)", priority: .high)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI Chat")
    }

    /// The header, the find bar, the thread, and the composer.
    private var conversation: some View {
        VStack(spacing: 0) {
            header
            if model.isFindPresented {
                AIChatFindBar(model: model)
            }
            QuickAIThread(viewModel: chat, highlightedMessageID: model.currentMatchID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The scroll view would otherwise draw up under the header
                // and the transparent title bar.
                .clipped()
            QuickAIComposer(viewModel: chat, multiline: true) { focused in
                model.noteFocus(.composer, focused)
            }
        }
        .overlay(alignment: .bottom) { QuickAIFloatingChooser(viewModel: chat) }
        .overlay(alignment: .bottomTrailing) { actionPalette }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: House.Spacing.sm) {
            QuickAIGlyphButton(
                symbol: "sidebar.left",
                font: AQDesign.TypeToken.glyphSmall,
                color: AQDesign.ColorToken.textSecondary,
                label: model.isRailVisible ? "Hide Chat List" : "Show Chat List",
                help: "\(model.isRailVisible ? "Hide" : "Show") chat list (\(AIChatWindowModel.chatListShortcut.keyCaps.joined()))"
            ) {
                model.toggleRail()
            }
            .accessibilityValue(model.isRailVisible ? "Open" : "Closed")
            QuickAITitleBlock(viewModel: chat)
            Spacer(minLength: House.Spacing.sm)
            if model.isAlwaysOnTop {
                QuickAIGlyphButton(
                    symbol: QuickAISurfaceAction.keepOnTopSymbol,
                    font: AQDesign.TypeToken.glyphSmall,
                    color: AQDesign.ColorToken.textSecondary,
                    label: "Kept on top",
                    help: "Kept on top of other windows. Click to stop"
                ) {
                    model.isAlwaysOnTop = false
                }
            }
            QuickAIGlyphButton(
                symbol: "square.and.pencil",
                font: AQDesign.TypeToken.glyphMedium,
                color: AQDesign.ColorToken.textPrimary,
                label: ResultAction.newChat.title,
                help: "\(ResultAction.newChat.title) (\(ResultAction.newChat.shortcut.keyCaps.joined()))"
            ) {
                model.closeFind()
                // Live while an answer streams: it stops first and keeps it.
                chat.startNewChatKeepingAnswer()
            }
        }
        // The traffic lights share this row while the rail is in.
        .padding(.leading, model.isRailVisible || model.isWindowFullScreen ? House.Spacing.sm : Self.trafficLightInset)
        .padding(.trailing, House.Spacing.lg)
        .frame(height: Self.titleBarHeight)
        .background(AQDesign.ColorToken.windowSurface)
        // The title-bar row drags the window, as a normal title bar does.
        .gesture(WindowDragGesture())
        .zIndex(1)
    }

    // MARK: - ⌘K

    @ViewBuilder
    private var actionPalette: some View {
        if chat.isActionPalettePresented {
            QuickActionPalette(viewModel: chat)
                .frame(width: PanelSizing.actionPaletteWidth)
                .panelGlass(radius: AQDesign.cardCornerRadius)
                .panelShadows()
                .frame(maxHeight: PanelSizing.actionPaletteMaxHeight, alignment: .bottom)
                .padding(.bottom, QuickAIView.composerRowHeight)
                .padding(.trailing, House.Spacing.sm)
        }
    }
}

// MARK: - Find bar

/// `⌘F`: a search field over the thread. `↩` (or `⌘G`) the next match,
/// `⇧↩` (or `⇧⌘G`) the previous, `esc` closes. A match in a folded
/// question opens it.
struct AIChatFindBar: View {
    @Bindable var model: AIChatWindowModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(AQDesign.TypeToken.body)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $model.findQuery, prompt: Text("")) {
                Text("Find in chat")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(AQDesign.TypeToken.body)
            .foregroundStyle(AQDesign.ColorToken.textPrimary)
            .overlay(alignment: .leading) {
                if model.findQuery.isEmpty {
                    Text("Find in chat")
                        .font(AQDesign.TypeToken.body)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($focused)
            .onSubmit { model.findNext() }
            Text(model.findStatus)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(model.findStatus)
            KeyHint(label: "Next", keys: ["↩"])
            KeyHint(label: "Previous", keys: ["⇧", "↩"])
            QuickAIGlyphButton(
                symbol: "xmark",
                font: AQDesign.TypeToken.glyphSmall,
                color: AQDesign.ColorToken.textSecondary,
                label: "Close find",
                help: "Close find (esc)"
            ) {
                model.closeFind()
            }
        }
        .padding(.horizontal, House.Spacing.md)
        .frame(height: House.Control.pill)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .fill(AQDesign.ColorToken.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: AQDesign.hairline)
        )
        .padding(.horizontal, House.Spacing.lg)
        .padding(.bottom, House.Spacing.xs)
        .onAppear { focusField() }
        .onChange(of: model.findFocusRequest) { _, _ in focusField() }
        .onChange(of: focused) { _, isFocused in model.noteFocus(.find, isFocused) }
        .onChange(of: model.findStatus) { _, status in
            guard !status.isEmpty else { return }
            QuickAIAnnouncement.post(status, priority: .medium)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in chat")
    }

    private func focusField() {
        FocusRequest.apply($focused)
    }
}

// MARK: - Rail

/// The chat list: a search field, then Pinned and Recent. `↑↓` move, `↩`
/// opens, `⌘K` the highlighted row's actions (pin, rename, delete, with
/// their own keys), `⌘1`…`⌘9` jump, `esc` clears the search and then
/// slides the list out.
struct AIChatRail: View {
    @Bindable var model: AIChatWindowModel
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    var body: some View {
        let items = model.railItems
        let pinned = model.pinnedRailItems
        let recent = model.recentRailItems
        VStack(alignment: .leading, spacing: 0) {
            // The traffic lights' row.
            Color.clear.frame(height: AIChatWindowView.titleBarHeight)
            searchField
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                        if items.isEmpty {
                            Text(model.railQuery.isEmpty ? "No chats yet" : "No chats match")
                                .font(AQDesign.TypeToken.body)
                                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                                .frame(maxWidth: .infinity, minHeight: House.Control.row)
                        }
                        if !pinned.isEmpty {
                            section("Pinned", rows: pinned, offset: 0, total: items.count)
                        }
                        if !recent.isEmpty {
                            section("Recent", rows: recent, offset: pinned.count, total: items.count)
                        }
                    }
                    .padding(.horizontal, House.Spacing.xs)
                    .padding(.bottom, House.Spacing.sm)
                }
                .onChange(of: model.railIndex) { _, index in
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id)
                }
            }
            if model.railActionsPresented {
                rowActions
            }
        }
        .background(AQDesign.ColorToken.sidebarSurface)
        .clipped()
        .onAppear { if model.focus == .rail { FocusRequest.apply($searchFocused) } }
        .onChange(of: model.railFocusRequest) { _, _ in FocusRequest.apply($searchFocused) }
        .onChange(of: model.renameFocusRequest) { _, _ in FocusRequest.apply($renameFocused) }
        .onChange(of: searchFocused) { _, focused in model.noteFocus(.rail, focused) }
        .onChange(of: renameFocused) { _, focused in model.noteFocus(.rename, focused) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chats")
    }

    private var searchField: some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $model.railQuery, prompt: Text("")) {
                Text("Search chats")
            }
            .textFieldStyle(.plain)
            .labelsHidden()
            .font(AQDesign.TypeToken.body)
            .foregroundStyle(AQDesign.ColorToken.textPrimary)
            .overlay(alignment: .leading) {
                if model.railQuery.isEmpty {
                    Text(QuickViewModel.recentChatsPlaceholder)
                        .font(AQDesign.TypeToken.body)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focused($searchFocused)
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                model.handleRailArrow(press.key == .upArrow ? -1 : 1) ? .handled : .ignored
            }
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(height: House.Control.chip)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .fill(AQDesign.ColorToken.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                .strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: AQDesign.hairline)
        )
        .padding(.horizontal, House.Spacing.sm)
        .padding(.bottom, House.Spacing.xs)
    }

    private func section(_ title: String, rows: [LauncherCatalogItem], offset: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SectionLabel(text: title)
                .padding(.horizontal, House.Spacing.xs)
                .padding(.top, House.Spacing.sm)
                .padding(.bottom, House.Spacing.xxs)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                row(item, index: offset + index, total: total)
                    .id(item.id)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: LauncherCatalogItem, index: Int, total: Int) -> some View {
        let isSelected = index == model.railIndex
        let isOpen = item.itemID == model.chat.currentConversation?.id.uuidString
        let isRenaming = item.itemID == model.renamingChatID?.uuidString
        Button {
            model.railIndex = index
            model.openChat(itemID: item.itemID)
        } label: {
            HStack(spacing: House.Spacing.xs) {
                VStack(alignment: .leading, spacing: 0) {
                    if isRenaming {
                        TextField(text: $model.renameText, prompt: Text("")) {
                            Text("Chat name")
                        }
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .focused($renameFocused)
                        .onSubmit { model.commitRename() }
                    } else {
                        Text(item.title)
                            .font(AQDesign.TypeToken.label)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(model.railDetail(for: item))
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if index < AIChatWindowModel.jumpRowCount, isSelected || isOpen {
                    KeyCap(text: "⌘\(index + 1)")
                }
            }
            .padding(.horizontal, House.Spacing.xs)
            .frame(height: House.Control.row)
            .background { RowHighlight(isSelected: isSelected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(model.railDetail(for: item))\(item.isPinned ? ", pinned" : "")\(isOpen ? ", open" : "")")
        .accessibilityValue(isSelected ? "Selected, \(index + 1) of \(total)" : "\(index + 1) of \(total)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// `⌘K` on a row: its actions, over the foot of the rail.
    private var rowActions: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            ForEach(Array(model.railActions.enumerated()), id: \.element.id) { index, action in
                Button {
                    model.railActionIndex = index
                    model.performRailAction(action)
                } label: {
                    HStack(spacing: House.Spacing.xs) {
                        Image(systemName: action.systemImage)
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(action == .delete
                                ? AQDesign.ColorToken.danger
                                : AQDesign.ColorToken.textSecondary)
                            .frame(width: House.Control.keyCap)
                        Text(model.title(of: action))
                            .font(AQDesign.TypeToken.label)
                            .foregroundStyle(action == .delete
                                ? AQDesign.ColorToken.danger
                                : AQDesign.ColorToken.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        KeyCapGroup(keys: action.shortcut.keyCaps)
                    }
                    .padding(.horizontal, House.Spacing.xs)
                    .frame(height: House.Control.railRow)
                    .background { RowHighlight(isSelected: index == model.railActionIndex) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == model.railActionIndex ? .isSelected : [])
            }
        }
        .padding(House.Spacing.xs)
        .raisedCard(radius: AQDesign.cardCornerRadius, fill: AQDesign.ColorToken.raisedSurface)
        .houseShadow(AQDesign.Shadow.card)
        .padding(House.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat actions")
    }
}
