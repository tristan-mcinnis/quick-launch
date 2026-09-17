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
    @State private var composerHeight = QuickAIView.composerRowHeight
    @State private var conversationHeight = House.Layout.chatMinHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A tray from the environment (render proofs) wins over the chat's own.
    @Environment(\.attachmentTray) private var environmentTray

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
        // Holding ⌘ shows every rail row's ⌘1…⌘9 number.
        .onModifierKeysChanged(mask: .command) { _, keys in
            model.isCommandHeld = keys.contains(.command)
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
            QuickAIThread(viewModel: chat, find: model.findHighlights) { hit, offset in
                model.noteFindHitOffset(offset, for: hit)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The scroll view would otherwise draw up under the header
                // and the transparent title bar.
                .clipped()
                // A file, link, or picture dropped on the thread attaches to
                // the next question, as on the composer.
                .attachmentDropTarget(environmentTray ?? chat.attachmentTray)
            QuickAIComposer(viewModel: chat, multiline: true) { focused in
                model.noteFocus(.composer, focused)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { conversationHeight = $0 }
        .overlay(alignment: .bottom) { QuickAIFloatingChooser(viewModel: chat, composerHeight: composerHeight) }
        .overlay(alignment: .bottomTrailing) { actionPalette }
        .environment(\.composerPaneMaximumHeight,
            max(0, conversationHeight - composerHeight - Self.titleBarHeight - House.Spacing.xs))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: House.Spacing.sm) {
            QuickAIGlyphButton(
                symbol: "sidebar.left",
                font: AQDesign.TypeToken.glyphSmall,
                color: AQDesign.ColorToken.textSecondary,
                label: model.isRailVisible ? "Hide Chat List" : "Show Chat List",
                help: "\(model.isRailVisible ? "Hide" : "Show") chat list (\(chat.shortcutLabel(for: .chatList)))"
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
                help: "\(ResultAction.newChat.title) (\(chat.shortcutLabel(for: .newChat)))"
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
                .padding(.bottom, composerHeight)
                .padding(.trailing, House.Spacing.sm)
        }
    }
}

// MARK: - Find bar

/// `⌘F`: a search field over the thread. `↩` (or `⌘G`) the next hit,
/// `⇧↩` (or `⇧⌘G`) the previous, across messages; `esc` closes. The count
/// is hits ("3 of 17"), each highlighted in the text. A hit in a folded
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

/// The chat list: a search field, then Pinned and Recent, or one ranked
/// "Results" list while a query is typed. `↑↓` move, `↩` opens, `⌘K` the
/// highlighted row's actions (pin, rename, delete, with their own keys, and
/// on the row's context menu and VoiceOver actions too), `⌘1`…`⌘9` jump
/// (every number shows while `⌘` is held), `esc` clears the search and
/// then slides the list out. The open chat carries an ink bar on its
/// leading edge, apart from the keyboard highlight.
struct AIChatRail: View {
    @Bindable var model: AIChatWindowModel
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool
    @FocusState private var actionSearchFocused: Bool
    /// The archive's size for the footer, and the last export's outcome.
    @State private var storageLine: String?
    @State private var actionNotice: String?

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
                            Text(model.railEmptyText)
                                .font(AQDesign.TypeToken.body)
                                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                                .frame(maxWidth: .infinity, minHeight: House.Control.row)
                        }
                        if model.isRailSearching {
                            if !items.isEmpty {
                                section("Results", rows: items, offset: 0, total: items.count)
                            }
                        } else {
                            if !pinned.isEmpty {
                                section("Pinned", rows: pinned, offset: 0, total: items.count)
                            }
                            if !recent.isEmpty {
                                section("Recent", rows: recent, offset: pinned.count, total: items.count)
                            }
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
            railFooter
        }
        .background(AQDesign.ColorToken.sidebarSurface)
        .clipped()
        .task(id: model.railItems.count) { await refreshStorage() }
        .onAppear { if model.focus == .rail { FocusRequest.apply($searchFocused) } }
        .onChange(of: model.railFocusRequest) { _, _ in FocusRequest.apply($searchFocused) }
        .onChange(of: model.renameFocusRequest) { _, _ in FocusRequest.apply($renameFocused) }
        .onChange(of: searchFocused) { _, focused in model.noteFocus(.rail, focused) }
        .onChange(of: actionSearchFocused) { _, focused in model.noteFocus(.rail, focused) }
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
        let isOpen = item.itemID == model.openChatItemID
        let detail = model.railDetail(for: item)
        let snippet = model.railSnippet(for: item)
        let number = model.railNumber(at: index)
        let showsNumber = number != nil && (model.isCommandHeld || isSelected || isOpen)
        // In one Results list a pinned row keeps its pin, as Pinned would say.
        let showsPin = item.isPinned && model.isRailSearching
        Group {
            if item.itemID == model.renamingChatID?.uuidString {
                // The rename field sits outside the row's button, so a click
                // in it edits the name and never opens the chat.
                rowLayout(isSelected: isSelected, isOpen: isOpen, isPinned: showsPin, number: showsNumber ? number : nil) {
                    TextField(text: $model.renameText, prompt: Text("")) {
                        Text("Chat name")
                    }
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .focused($renameFocused)
                    .onSubmit { model.commitRename() }
                    rowSecondLine(detail: detail, snippet: snippet)
                }
            } else {
                Button {
                    model.railIndex = index
                    model.openChat(itemID: item.itemID)
                } label: {
                    rowLayout(isSelected: isSelected, isOpen: isOpen, isPinned: showsPin, number: showsNumber ? number : nil) {
                        Text(item.title)
                            .font(AQDesign.TypeToken.label)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        rowSecondLine(detail: detail, snippet: snippet)
                    }
                }
                .buttonStyle(.plain)
                // A row found by its text shows the snippet; the count and
                // time move here.
                .help(snippet == nil ? item.title : "\(item.title), \(detail)")
            }
        }
        .contextMenu {
            ForEach(AIChatWindowModel.RailAction.allCases) { action in
                Button(role: action == .delete ? .destructive : nil) {
                    model.performRailAction(action, itemID: item.itemID)
                } label: {
                    Label(model.title(of: action, for: item), systemImage: action.systemImage)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.title), \(snippet?.plainText ?? detail)\(item.isPinned ? ", pinned" : "")\(isOpen ? ", open" : "")"
        )
        .accessibilityValue(isSelected ? "Selected, \(index + 1) of \(total)" : "\(index + 1) of \(total)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            ForEach(AIChatWindowModel.RailAction.allCases) { action in
                Button(model.title(of: action, for: item)) {
                    model.performRailAction(action, itemID: item.itemID)
                }
            }
        }
    }

    /// One rail row: the open-chat bar, two lines, and the `⌘` number.
    private func rowLayout<Lines: View>(
        isSelected: Bool,
        isOpen: Bool,
        isPinned: Bool,
        number: Int?,
        @ViewBuilder lines: () -> Lines
    ) -> some View {
        HStack(spacing: House.Spacing.xs) {
            VStack(alignment: .leading, spacing: 0) {
                lines()
            }
            Spacer(minLength: 0)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(AQDesign.TypeToken.footnote.weight(.semibold))
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityHidden(true)
            }
            if let number {
                KeyCap(text: "⌘\(number)")
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(height: House.Control.row)
        .background { RowHighlight(isSelected: isSelected) }
        .overlay(alignment: .leading) {
            if isOpen { OpenChatMarker() }
        }
        .contentShape(Rectangle())
    }

    /// The row's second line: the snippet while a search found the chat by
    /// its text, else the question count and time.
    @ViewBuilder
    private func rowSecondLine(detail: String, snippet: ChatSnippet?) -> some View {
        if let snippet {
            ChatSnippetText(snippet: snippet)
        } else {
            Text(detail)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// `⌘K` on a row: its actions, over the foot of the rail.
    private var rowActions: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            TextField("Search actions", text: $model.railActionQuery)
                .textFieldStyle(.plain)
                .font(AQDesign.TypeToken.body)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .padding(.horizontal, House.Spacing.xs)
                .frame(height: House.Control.chip)
                .focused($actionSearchFocused)
                .onSubmit { model.activateRailSelection() }
                .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    model.handleRailArrow(press.key == .upArrow ? -1 : 1) ? .handled : .ignored
                }
                .onAppear { FocusRequest.apply($actionSearchFocused) }
            if model.filteredRailActions.isEmpty {
                Text("No matching actions")
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .padding(House.Spacing.xs)
            }
            ForEach(Array(model.filteredRailActions.enumerated()), id: \.element.id) { index, action in
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
                        Text(model.compactTitle(of: action))
                            .font(AQDesign.TypeToken.label)
                            .foregroundStyle(action == .delete
                                ? AQDesign.ColorToken.danger
                                : AQDesign.ColorToken.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        KeyCapGroup(keys: model.chat.shortcutKeyCaps(for: action.shortcutAction))
                    }
                    .padding(.horizontal, House.Spacing.xs)
                    .frame(height: House.Control.railRow)
                    .background { RowHighlight(isSelected: index == model.railActionIndex) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.title(of: action))
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

    // MARK: - Export and storage

    /// Export and storage sit under the rows: the rail stays the one chat
    /// library, and nothing here duplicates it. Export writes the archived
    /// record, not the in-memory projection.
    private var railFooter: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            Rectangle()
                .fill(AQDesign.ColorToken.divider)
                .frame(height: AQDesign.hairline)
            Button {
                exportChat()
            } label: {
                HStack(spacing: House.Spacing.xs) {
                    Image(systemName: "square.and.arrow.up")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        .frame(width: House.Control.keyCap)
                        .accessibilityHidden(true)
                    Text("Export Chat")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, House.Spacing.xs)
                .frame(height: House.Control.railRow)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(exportableChatID == nil)
            .accessibilityLabel("Export Chat")
            .help("Export the highlighted chat as JSON")
            if let storageLine {
                Text(storageLine)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, House.Spacing.xs)
            }
            if let actionNotice {
                Text(actionNotice)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, House.Spacing.xs)
            }
        }
        .padding(.bottom, House.Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat storage")
    }

    private var exportableChatID: String? {
        model.highlightedRailItem?.itemID ?? model.openChatItemID
    }

    private func exportChat() {
        guard let archive = model.chat.chatArchive, let id = exportableChatID else {
            actionNotice = "No chat to export."
            return
        }
        let title = (model.highlightedRailItem ?? model.railItems.first { $0.itemID == id })?.title ?? "Chat"
        Task {
            do {
                let data = try await archive.export(id: id)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(title).json"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                actionNotice = "Exported \(panel.nameFieldStringValue)"
            } catch {
                actionNotice = "Could not export: \(error.localizedDescription)"
            }
        }
    }

    private func refreshStorage() async {
        guard let archive = model.chat.chatArchive else {
            storageLine = nil
            return
        }
        guard let usage = try? await archive.usage() else {
            storageLine = "Storage unavailable"
            return
        }
        var parts = ["\(usage.conversationCount) chat\(usage.conversationCount == 1 ? "" : "s")"]
        if usage.artifactBytes > 0 {
            parts.append(usage.artifactBytes.formatted(.byteCount(style: .file)))
        }
        if usage.damagedConversationCount > 0 {
            parts.append("\(usage.damagedConversationCount) damaged")
        }
        storageLine = parts.joined(separator: " · ")
    }
}

/// The open chat's mark in the rail: a short ink bar on the row's leading
/// edge. Ink, not colour, and apart from the keyboard highlight's fill.
private struct OpenChatMarker: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(AQDesign.ColorToken.textPrimary)
            .frame(width: House.Spacing.xxs / 2, height: House.Control.keyCap)
            .accessibilityHidden(true)
    }
}
