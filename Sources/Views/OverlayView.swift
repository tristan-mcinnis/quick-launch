import SwiftUI
import Combine

struct OverlayView: View {
    @Bindable var viewModel: QuickViewModel
    /// The composer's attachment tray. Passed down through the environment,
    /// so the Quick AI composer and Add Context pane find it.
    var tray: AttachmentTray? = nil
    @State private var quickAIComposerHeight = QuickAIView.composerRowHeight
    @State private var surfaceHeight = PanelSizing.quickAIHeight
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.attachmentTray) private var inheritedTray

    /// The tray passed in, else the environment's, else the view model's
    /// own: the composer's attachments always have a home.
    private var activeTray: AttachmentTray? { tray ?? inheritedTray ?? viewModel.attachmentTray }

    var body: some View {
        Group {
            if viewModel.isQuickAIPresented {
                // Quick AI replaces the launcher in place: its own header,
                // thread, and bottom composer, and no footer well. The whole
                // surface takes a drop.
                QuickAIView(viewModel: viewModel) { quickAIComposerHeight = $0 }
                    .attachmentDropTarget(activeTray)
            } else {
                rootSurface
            }
        }
        .environment(\.attachmentTray, activeTray)
        // Root search is exactly its measured width. Quick AI fills the
        // window, which the user can drag larger than 750 × 475: a fixed
        // width would pin the hosting view and stop the drag.
        .frame(
            minWidth: viewModel.isQuickAIPresented ? PanelSizing.panelWidth : viewModel.currentPanelWidth,
            maxWidth: viewModel.isQuickAIPresented ? .infinity : viewModel.currentPanelWidth,
            minHeight: rootSurfaceMinimumHeight,
            alignment: .top
        )
        .panelGlass()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { surfaceHeight = $0 }
        .overlay(alignment: viewModel.isQuickAIPresented ? .bottomTrailing : .topTrailing) {
            actionPopover
                .environment(\.composerPaneMaximumHeight, viewModel.isQuickAIPresented
                    ? max(0, surfaceHeight - quickAIComposerHeight - QuickAIView.headerHeight - House.Spacing.xs)
                    : nil)
        }
        .preferredColorScheme(viewModel.settings.appearance.swiftUIColorScheme)
        .onAppear { focusInput() }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in focusInput() }
        .onChange(of: viewModel.launcherMatches.map(\.id)) { _, matches in
            if !matches.isEmpty { viewModel.announceCurrentLauncherSelection() }
        }
        .onChange(of: viewModel.launcherSelectionAnnouncementRevision) { _, _ in
            announceLauncherSelection(viewModel.launcherSelectionAnnouncement)
        }
        .onChange(of: viewModel.screenHistory.announcementRevision) { _, _ in
            announceScreenHistoryResult(viewModel.screenHistory.resultAnnouncement)
        }
        .onChange(of: viewModel.errorMessage) { _, error in
            guard let error, !error.isEmpty else { return }
            postAccessibilityAnnouncement("Error. \(error)", priority: .high)
        }
    }

    /// While a ⌘K pane floats over root search, the surface claims the whole
    /// window the panel was sized to. Without it a short surface (an empty
    /// catalog, one row) sits centred in a taller window and the pane, which
    /// hangs from the surface's top edge, runs off the bottom of the glass.
    private var rootSurfaceMinimumHeight: CGFloat? {
        guard !viewModel.isQuickAIPresented, viewModel.isItemActionPanePresented else { return nil }
        return viewModel.estimatedWindowHeight
    }

    /// Root search: the input row, the launcher list, the catalogs, and the
    /// footer well. Model answers never draw here; they live on the Quick AI
    /// surface, and a thread kept behind root search stays out of sight.
    /// The one answer root draws is a local one (math, a conversion, a date,
    /// a system fact), under the input row as v1.3.0 drew it.
    private var rootSurface: some View {
        VStack(spacing: 0) {
            // Input row: the Add Context control, a leading glyph, the field,
            // and one square menu button. No send circle and no accent
            // anywhere — Return sends.
            HStack(spacing: AQDesign.Space.row) {
                Button {
                    viewModel.toggleAddContextMenu()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(AQDesign.TypeToken.glyph)
                        .foregroundStyle(
                            viewModel.isAddContextMenuPresented
                                ? AQDesign.ColorToken.textPrimary
                                : AQDesign.ColorToken.textTertiary
                        )
                        .frame(width: House.Control.tile, height: House.Control.tile)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Context")
                .accessibilityValue(viewModel.isAddContextMenuPresented ? "Open" : "Closed")
                .help("Add context: a window, a selection, an area, or a screen (or type @)")

                Image(systemName: "magnifyingglass")
                    .font(AQDesign.TypeToken.glyph)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityHidden(true)

                // Single line, scrolling horizontally like Raycast. A
                // vertical-axis field capped at one line scrolled long text
                // upward until only the descenders were visible.
                TextField(
                    viewModel.inputPlaceholder,
                    text: $viewModel.input
                )
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.input)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await viewModel.submitResolvingFuzzyAlias() } }
                    .modifier(ComposerKeyRouting(viewModel: viewModel))
                    .onChange(of: viewModel.input) { _, newValue in
                        viewModel.resetApplicationSelection()
                        viewModel.noteInteraction()
                        viewModel.rootInputDidChange(newValue)
                        viewModel.screenHistory.inputDidChange()
                        // Typing `@` opens the same Add Context menu the
                        // control left of the field does.
                        viewModel.addContextTriggerDidChange(newValue)
                    }
                    .disabled(viewModel.isStreaming && !viewModel.isAskQuestionActive)

                // Working / copied lives in the same slot; at rest the row
                // carries one control, the menu, exactly as the design does.
                if viewModel.isStreaming {
                    Button { viewModel.cancel() } label: {
                        ThinkingIndicator().frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop response")
                    .help("Working… press Escape to stop")
                } else if viewModel.justCopied {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AQDesign.TypeToken.input)
                        .foregroundStyle(AQDesign.ColorToken.success)
                        .accessibilityLabel("Copied to clipboard")
                        .help("Copied to clipboard")
                }

                moreMenu
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .frame(minHeight: AQDesign.inputHeight)

            if viewModel.launchSelection != nil {
                HouseDivider()
                LaunchSelectionStrip(viewModel: viewModel)

                if viewModel.isTransformChooserPresented {
                    TransformChooserPane(viewModel: viewModel)
                }
            }

            if viewModel.isModelChooserPresented {
                HouseDivider()
                ModelChooserPane(viewModel: viewModel)
            }

            if viewModel.isCaptureChooserPresented {
                HouseDivider()
                CaptureChooserPane(viewModel: viewModel)
            }

            if viewModel.isAddContextMenuPresented {
                HouseDivider()
                AddContextPane(viewModel: viewModel)
            }

            if ComposerAttachmentStrip.hasChips(viewModel: viewModel, tray: activeTray)
                || activeTray?.notice != nil {
                HouseDivider()
                ComposerAttachmentStrip(viewModel: viewModel, tray: activeTray, sideInset: AQDesign.Space.panel)
            }

            if !viewModel.isTransformChooserPresented,
               !viewModel.isModelChooserPresented,
               !viewModel.isCaptureChooserPresented,
               !viewModel.isAddContextMenuPresented,
               (!viewModel.launcherMatches.isEmpty || (viewModel.isHistoryCatalog && viewModel.showsDetailPane)) {
                HouseDivider()
                if viewModel.launcherMatches.isEmpty {
                    Text(viewModel.input.isEmpty
                         ? (viewModel.catalogScope == .screenshots ? "Take a screenshot to see it here" : "Copy text or an image to see it here")
                         : "No matches. Try a different search.")
                        .font(House.TypeToken.body)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        // Same guardrail as the list block: fill the preview
                        // space when the display has it, shrink to the room
                        // when it does not, so the footer stays on screen.
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(maxHeight: PanelSizing.launcherListMaximumHeight)
                        .layoutPriority(1)
                } else if viewModel.isGridCatalog {
                    EmojiGridView(viewModel: viewModel)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        launcherList
                            .frame(width: viewModel.showsDetailPane ? PanelSizing.detailListWidth : nil)
                        if viewModel.showsDetailPane, let item = viewModel.detailItem {
                            Rectangle().fill(AQDesign.ColorToken.divider).frame(width: AQDesign.hairline)
                            // The ⌘K pane takes this column while it is open,
                            // so the preview withdraws rather than being left
                            // half-covered and cut mid-word behind the card.
                            if viewModel.isItemActionPanePresented {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                CatalogDetailPane(viewModel: viewModel, item: item)
                            }
                        }
                    }
                    // A fixed height here pushed the footer past the window's
                    // bottom edge on a short display, where the hung frame is
                    // capped to the room under the anchor. A flexible block
                    // takes what is left, so the list scrolls and the footer
                    // keeps the bottom edge.
                    .frame(
                        minHeight: 0,
                        maxHeight: viewModel.isHistoryCatalog && viewModel.showsDetailPane
                            ? PanelSizing.launcherListMaximumHeight : nil
                    )
                    .layoutPriority(1)
                }
            }

            screenHistoryStatusSurface

            // Saved-prompt autocomplete
            if !viewModel.isApplicationActionPanePresented,
               !viewModel.isCatalogActionPanePresented,
               !viewModel.isTransformChooserPresented,
               !viewModel.savedPromptMatches.isEmpty {
                HouseDivider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.savedPromptMatches) { match in
                        Button {
                            viewModel.complete(savedPrompt: match)
                        } label: {
                            HStack(spacing: 10) {
                                Text(viewModel.settings.savedPromptPrefix + match.alias)
                                    .font(AQDesign.TypeToken.codeLabel)
                                    .foregroundStyle(AQDesign.ColorToken.emphasis)
                                Text(match.prompt)
                                    .font(AQDesign.TypeToken.detail)
                                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let answer = viewModel.rootAnswer {
                HouseDivider()
                RootAnswerBlock(answer: answer)
            }

            // Error message
            if let error = viewModel.errorMessage {
                HouseDivider()
                HStack(spacing: AQDesign.Space.standard) {
                    Text(error)
                        .font(AQDesign.TypeToken.detail)
                        .foregroundStyle(AQDesign.ColorToken.danger)
                    Spacer()
                    if viewModel.needsAccessibilityPermission {
                        Button("Open System Settings") {
                            viewModel.openAccessibilitySettings()
                        }
                        .buttonStyle(InkButtonStyle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            // Claimed height goes here, so the footer keeps the bottom edge
            // and everything above it keeps its own place.
            Spacer(minLength: 0)

            if viewModel.showsLauncherFooter {
                FooterWell { LauncherFooter(viewModel: viewModel) }
            }
        }
    }

    private func focusInput() {
        // The Quick AI composer owns focus while the surface is up; asking
        // the hidden root field would move nothing.
        guard !viewModel.isQuickAIPresented else { return }
        // A chooser with its own search field owns the keys while it is up.
        guard !viewModel.searchablePaneOwningFocus else { return }
        FocusRequest.apply($inputFocused)
    }

    private var actionPaneWidth: CGFloat {
        PanelSizing.itemActionPaneWidth(
            panelWidth: viewModel.currentPanelWidth,
            showsDetailPane: viewModel.showsDetailPane
        )
    }

    @ViewBuilder
    private var actionPopover: some View {
        Group {
            if viewModel.isItemActionPanePresented,
               let result = viewModel.focusedLauncherResult {
                ItemActionPane(viewModel: viewModel, result: result)
            } else if viewModel.isActionPalettePresented {
                QuickActionPalette(viewModel: viewModel)
            }
        }
        .frame(width: actionPaneWidth)
        // Chrome hugs the content: a `.frame(maxHeight:)` adopts the window's
        // proposal, so background applied outside it stretched into an empty
        // dark sheet whenever the window was tall.
        .panelGlass(radius: AQDesign.cardCornerRadius)
        .panelShadows()
        // At root the pane hangs from the input row; on the Quick AI
        // surface it hugs the composer, so the flexible frame fills the
        // surface's proposal and the palette sits at its bottom edge, not
        // over the header.
        .frame(
            maxHeight: viewModel.activeItemActionForm?.minimumWindowHeight
                .map { $0 - PanelSizing.inputHeight - PanelSizing.paneBottomMargin }
                ?? PanelSizing.actionPaletteMaxHeight,
            alignment: viewModel.isQuickAIPresented ? .bottom : .top
        )
        // Below the input row and, when present, the attachment strip:
        // without the offset the pane covered the attachment preview. On the
        // Quick AI surface the pane floats above the bottom composer instead.
        .padding(
            .top,
            viewModel.isQuickAIPresented
                ? 0
                : PanelSizing.inputHeight
                    + (viewModel.hasPendingAttachment ? PanelSizing.attachmentHeight : 0)
        )
        .padding(.bottom, viewModel.isQuickAIPresented ? quickAIComposerHeight : 0)
        .padding(.trailing, House.Spacing.sm)
    }

    @ViewBuilder
    private var screenHistoryStatusSurface: some View {
        if viewModel.catalogScope == .screenHistory,
           !viewModel.isItemActionPanePresented,
           viewModel.launcherMatches.isEmpty {
            HouseDivider()
            ScreenHistoryEmptyState(viewModel: viewModel)
        }
        if viewModel.catalogScope == .screenHistory,
           !viewModel.screenHistory.resultAnnouncement.isEmpty {
            Text(viewModel.screenHistory.resultAnnouncement)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .accessibilityLabel(viewModel.screenHistory.resultAnnouncement)
        }
    }

    private func announceScreenHistoryResult(_ announcement: String) {
        guard viewModel.catalogScope == .screenHistory, !announcement.isEmpty else { return }
        postAccessibilityAnnouncement(announcement, priority: .medium)
    }

    private func announceLauncherSelection(_ announcement: String) {
        guard !announcement.isEmpty else { return }
        postAccessibilityAnnouncement(announcement, priority: .medium)
    }

    private func postAccessibilityAnnouncement(
        _ announcement: String,
        priority: NSAccessibilityPriorityLevel
    ) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: priority.rawValue,
            ]
        )
    }

    private var launcherList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: launcherSectionTitle)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)

            SelectableListPane(
                items: viewModel.launcherMatches,
                selectedIndex: $viewModel.applicationSelectionIndex,
                scrollsToSelection: true,
                onActivate: { result in
                    Task { await viewModel.performLauncherResult(result) }
                }
            ) { index, result, isSelected in
                LauncherResultRow(
                    result: result,
                    isSelected: isSelected,
                    hotkey: viewModel.hotkey(for: result),
                    position: index + 1,
                    total: viewModel.launcherMatches.count
                )
                .padding(.horizontal, 10)
                .modifier(ScreenHistoryRowFrame(result: result))
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, AQDesign.Space.standard)
        .padding(.bottom, AQDesign.Space.standard)
        .frame(maxHeight: PanelSizing.launcherListMaximumHeight)
    }

    private var launcherSectionTitle: String {
        if let scope = viewModel.catalogScope { return scope.title }
        return viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Suggestions"
            : "Results"
    }

    private var moreMenu: some View {
        Menu {
            Button {
                viewModel.toggleActionPalette()
            } label: {
                Label("Actions…", systemImage: "wand.and.stars")
            }

            Divider()
            Button {
                viewModel.openCaptureChooser()
            } label: {
                Label(
                    "Capture…  \(ScreenshotKind.window.overlayKeyCaps(viewModel.shortcuts).joined())",
                    systemImage: "camera.viewfinder"
                )
            }
            ForEach(ScreenshotKind.allCases, id: \.rawValue) { kind in
                Button {
                    Task { await viewModel.attachScreenshot(kind, clearingInput: false) }
                } label: {
                    // The window key opens the chooser, so it is not shown
                    // beside this row's direct capture.
                    Label(
                        kind == .window
                            ? kind.title
                            : "\(kind.title)  \(kind.overlayKeyCaps(viewModel.shortcuts).joined())",
                        systemImage: kind.systemImage
                    )
                }
            }

            Divider()
            modelSubmenu

            Divider()
            ForEach(viewModel.chatMenuEntries) { entry in
                Button {
                    viewModel.performChatMenuEntry(entry)
                } label: {
                    Label(entry.menuTitle(viewModel.shortcuts), systemImage: entry.systemImage)
                }
                .disabled(!viewModel.isChatMenuEntryEnabled(entry))
            }

            Divider()
            Button {
                viewModel.overlayPresenter.openSettings()
            } label: {
                Label("Settings…", systemImage: "gear")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(
                    viewModel.isActionPalettePresented
                        ? AQDesign.ColorToken.textPrimary
                        : AQDesign.ColorToken.textSecondary
                )
                .frame(width: House.Control.compact, height: House.Control.compact)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // The tile is drawn around the menu, not inside its label: a
        // borderless menu style discards a background set on the label.
        .frame(width: House.Control.compact, height: House.Control.compact)
        .background(
            RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                .fill(AQDesign.ColorToken.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                .strokeBorder(AQDesign.ColorToken.tileStroke, lineWidth: AQDesign.hairline)
        )
        .accessibilityLabel("More actions")
        .help("Actions, model, chats, and settings")
    }

    private var modelSubmenu: some View {
        Menu {
            Text("Using \(viewModel.activeModelDisplay)")
            Divider()
            ForEach(viewModel.settings.providers) { provider in
                Menu(provider.name) {
                    let models = viewModel.visibleModels(for: provider)
                    if models.isEmpty {
                        Button("Refresh models") {
                            Task { await viewModel.refreshModels(providerID: provider.id) }
                        }
                    } else {
                        ForEach(models, id: \.self) { model in
                            Button {
                                viewModel.selectModel(providerID: provider.id, model: model)
                            } label: {
                                if viewModel.isActiveModel(provider: provider, model: model) {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Refresh detected models") {
                Task { await viewModel.refreshDetectedModels() }
            }
            Button("Model settings…") {
                viewModel.overlayPresenter.openSettings()
            }
        } label: {
            Label("Model: \(viewModel.activeModelDisplay)", systemImage: "cpu")
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// One launcher row: the 26 pt icon tile, `label` title, `meta` detail,
/// and the trailing hotkey, status light, or type. The Quick AI surface
/// draws Recent Chats with the same row.
struct LauncherResultRow: View {
    let result: LauncherSearchResult
    let isSelected: Bool
    var hotkey: ActionHotkey? = nil
    var position: Int? = nil
    var total: Int? = nil

    var body: some View {
        HStack(spacing: AQDesign.Space.row) {
            icon
            if let screenHistoryRow {
                screenHistoryRow
            } else if let chatSnippet {
                ChatSnippetRowText(title: title, detail: detail, snippet: chatSnippet)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: AQDesign.Space.standard) {
                    Text(title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            // A snippet row runs its own count and time to the trailing edge.
            if chatSnippet == nil { Spacer(minLength: AQDesign.Space.standard) }
            if case .item(let item) = result, item.isPinned {
                Image(systemName: "pin.fill")
                    .font(AQDesign.TypeToken.footnote.weight(.semibold))
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityLabel("Pinned")
            }
            if let hotkey {
                KeyCapGroup(keys: hotkey.keyCaps)
                    .accessibilityLabel("Hotkey \(hotkey.displayName)")
            } else if let statusLight {
                StatusLightLabel(light: statusLight)
            } else if screenHistoryRow == nil, chatSnippet == nil {
                Text(resultType)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: AQDesign.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    /// Every row glyph sits in the same 26 pt tile, so titles line up
    /// whatever the symbol or icon width.
    @ViewBuilder private var icon: some View {
        switch result {
        case .application(let application):
            IconTile(fillsTile: true) {
                Image(nsImage: AppIconCache.icon(forPath: application.url.path))
                    .resizable().scaledToFit()
            }
        case .catalog(let scope, _):
            IconTile {
                Image(systemName: scope.systemImage)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
            }
        case .item(let item):
            if item.kind == .emoji {
                IconTile {
                    Text(item.value).font(AQDesign.TypeToken.body)
                }
            } else if item.kind == .screenshot,
                      let thumbnail = ScreenshotThumbnailCache.thumbnail(forPath: item.value, maximumPixels: 96) {
                IconTile(fillsTile: true) {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                }
            } else {
                IconTile {
                    Image(systemName: item.systemImage)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                }
            }
        }
    }

    private var title: String {
        switch result {
        case .application(let app): app.name
        case .catalog(let scope, _): scope.title
        case .item(let item): item.title
        }
    }
    private var statusLight: LauncherStatusLight? {
        if case .item(let item) = result { return item.statusLight }
        return nil
    }
    /// A chat a search found by its text: the row shows where.
    private var chatSnippet: ChatSnippet? {
        if case .item(let item) = result { return item.chatSnippet }
        return nil
    }
    private var detail: String {
        switch result {
        case .application: "Application"
        case .catalog(let scope, let count): scope == .screenHistory ? "Search local screen activity" : "\(count) items"
        case .item(let item): item.detail
        }
    }
    private var action: String {
        switch result {
        case .application: "Open"
        case .catalog: "Browse"
        case .item(let item): item.defaultActionTitle
        }
    }

    private var resultType: String { Self.typeLabel(for: result) }

    /// The `meta` type label on a row's right edge. A chat row reads "Chat";
    /// "AI Chat" names only the window.
    static func typeLabel(for result: LauncherSearchResult) -> String {
        switch result {
        case .application: "Application"
        case .catalog: "Catalog"
        case .item(let item):
            switch item.kind {
            case .application: "Application"
            case .snippet: "Snippet"
            case .quickLink: "Quicklink"
            case .clipboard: "Clipboard"
            case .emoji: "Emoji"
            case .screenshot: "Screenshot"
            case .conversation: "Chat"
            case .askAI: "AI Command"
            case .folder: "Folder"
            case .answer: "Answer"
            case .screenHistory: "Screen History"
            case .color: "Color"
            case .command: "Command"
            }
        }
    }

    private var screenHistoryRow: ScreenHistoryResultRow? {
        ScreenHistoryResultRow(
            result: result,
            isSelected: isSelected,
            position: position,
            total: total,
            primaryAction: action
        )
    }

    private var accessibilityValue: String {
        if let screenHistoryRow { return screenHistoryRow.accessibilityValue }
        var parts: [String] = []
        if isSelected { parts.append("Selected") }
        if let position, let total { parts.append("\(position) of \(total)") }
        if isSelected { parts.append("\(action) with Return") }
        return parts.joined(separator: ", ")
    }
}

/// Raycast-style actions for one row: a list with the shortcut on the right,
/// a search field at the bottom, and small forms for edit, alias, and hotkey.
private struct ItemActionPane: View {
    @Bindable var viewModel: QuickViewModel
    let result: LauncherSearchResult
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool
    @State private var editedTitle = ""
    @State private var editedValue = ""
    @FocusState private var formFocused: Bool

    private var actions: [ItemAction] {
        viewModel.filteredFocusedItemActions
    }

    private var item: LauncherCatalogItem? {
        if case .item(let item) = result { return item }
        return nil
    }

    private var application: LaunchableApplication? {
        if case .application(let application) = result { return application }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .frame(height: PanelSizing.paneHeaderHeight)
            HouseDivider()
            if let form = viewModel.activeItemActionForm {
                formView(form)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            } else {
                list
                HouseDivider()
                searchField
            }
        }
        .onAppear {
            syncEditor()
            focusSearch()
            announceSelectedAction()
        }
        .onChange(of: viewModel.activeItemActionForm) { _, form in
            syncEditor()
            if form == nil { focusSearch() } else { focusForm() }
        }
        .onChange(of: viewModel.actionQuery) { _, _ in
            selectedIndex = 0
            announceSelectedAction()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: AQDesign.Space.row) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            SectionLabel(text: viewModel.activeItemActionForm == nil ? "Actions" : formTitle)
        }
    }

    @ViewBuilder private var icon: some View {
        if let application {
            IconTile(fillsTile: true) {
                Image(nsImage: AppIconCache.icon(forPath: application.url.path))
                    .resizable().scaledToFit()
            }
        } else if let item, item.kind == .emoji {
            IconTile { Text(item.value).font(AQDesign.TypeToken.body) }
        } else if let item {
            IconTile {
                Image(systemName: item.systemImage)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
            }
        }
    }

    private var title: String {
        // A draft has no name yet, so its header says what is being made.
        if let item, item.title.isEmpty { return item.detail }
        return application?.name ?? item?.title ?? ""
    }

    private var isEditingQuickLink: Bool { item?.kind == .quickLink }

    /// The form is also where the placeholder grammar is taught, in one line.
    private var editFormHint: String {
        // The keys are in the footer while the form is open, so the hint
        // teaches the placeholders and nothing else: it has to fit whole.
        isEditingQuickLink
            ? "{query} asks for words first"
            : "{cursor} {clipboard} {date} {argument} expand on paste"
    }

    private var isCreatingItem: Bool {
        item.map(viewModel.isDraftItem) ?? false
    }

    private var subtitle: String {
        if application != nil { return "Application" }
        guard let item else { return "" }
        switch item.kind {
        case .snippet: return "Snippet"
        case .clipboard: return item.detail
        case .quickLink: return "Quick Link"
        case .command: return item.detail
        case .emoji: return "Emoji"
        case .screenshot: return item.detail
        case .conversation: return item.detail
        case .askAI: return item.detail
        case .folder: return item.detail
        case .answer: return item.detail
        case .screenHistory: return item.detail
        case .color: return item.detail
        case .application: return "Application"
        }
    }

    private var formTitle: String {
        switch viewModel.activeItemActionForm {
        case .edit: isCreatingItem ? "New" : "Edit"
        case .alias: "Alias"
        case .hotkey: "Hotkey"
        case .screenHistorySave: "Save to Vault"
        case nil: ""
        }
    }

    // MARK: Action list

    private var list: some View {
        SelectableListPane(
            items: actions,
            selectedIndex: $selectedIndex,
            rowSpacing: PanelSizing.actionRowSpacing,
            rowHeight: PanelSizing.actionRowHeight,
            listInsets: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8),
            emptyText: "No matching actions",
            scrollsToSelection: true,
            accessibilityValue: { index, isSelected in
                ScreenHistoryAccessibilityPresentation.actionValue(
                    isSelected: isSelected,
                    position: index + 1,
                    total: actions.count
                )
            },
            onActivate: { action in
                Task { await viewModel.perform(action, on: result) }
            }
        ) { _, action, _ in
            HStack(spacing: AQDesign.Space.row) {
                IconTile {
                    Image(systemName: action.systemImage)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(
                            action.isDestructive
                                ? AQDesign.ColorToken.danger
                                : AQDesign.ColorToken.textPrimary
                        )
                }
                Text(action.title)
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(
                        action.isDestructive
                            ? AQDesign.ColorToken.danger
                            : AQDesign.ColorToken.textPrimary
                    )
                Spacer()
                if let shortcut = action.shortcut {
                    KeyCapGroup(keys: shortcut.keyCaps)
                }
            }
            .padding(.horizontal, 10)
        }
        // Exactly as tall as its rows (capped at six): the pane hugs its
        // content instead of stretching into an empty dark sheet.
        .modifier(ComposerPaneListHeight(
            preferredHeight: PanelSizing.actionListHeight(rows: actions.count),
            chromeHeight: PanelSizing.itemActionPaneHeight(rows: 1) - PanelSizing.actionListHeight(rows: 1)
        ))
    }

    private var searchField: some View {
        HStack(spacing: AQDesign.Space.row) {
            Image(systemName: "magnifyingglass")
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
            TextField("Search actions…", text: $viewModel.actionQuery)
                .textFieldStyle(.plain)
                .font(AQDesign.TypeToken.body)
                .focused($searchFocused)
                .onSubmit { runSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            KeyCapGroup(keys: viewModel.shortcutKeyCaps(for: .commandPalette))
        }
        .padding(.horizontal, 20)
        .frame(height: PanelSizing.paneSearchRowHeight)
    }

    // MARK: Forms

    @ViewBuilder
    private func formView(_ form: ItemActionForm) -> some View {
        switch form {
        case .edit:
            VStack(alignment: .leading, spacing: 8) {
                TextField(isEditingQuickLink ? "Quicklink name" : "Snippet name", text: $editedTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($formFocused)
                    .onChange(of: editedTitle) { _, _ in viewModel.noteInteraction() }
                if isEditingQuickLink {
                    // An address is one line, so it gets a field, not a sheet
                    // of text. Everything else about the form is the same.
                    TextField("https://example.com/search?q={query}", text: $editedValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onChange(of: editedValue) { _, _ in viewModel.noteInteraction() }
                } else {
                    TextEditor(text: $editedValue)
                        .font(.body.monospaced())
                        .frame(minHeight: 72, maxHeight: 130)
                        .overlay(
                            RoundedRectangle(cornerRadius: AQDesign.fieldCornerRadius, style: .continuous)
                                .stroke(AQDesign.ColorToken.fieldStroke, lineWidth: AQDesign.hairline)
                        )
                        .onChange(of: editedValue) { _, _ in viewModel.noteInteraction() }
                }
                HStack(spacing: AQDesign.Space.standard) {
                    Button {
                        saveEdit()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(InkButtonStyle())
                    Button("Cancel") { viewModel.dismissItemActionLayer() }
                    Spacer()
                    Text(editFormHint)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                }
            }
        case .alias:
            VStack(alignment: .leading, spacing: 8) {
                TextField("Alias, for example: work chat", text: aliasBinding)
                    .textFieldStyle(.roundedBorder)
                    .focused($formFocused)
                    .onSubmit { viewModel.dismissItemActionLayer() }
                if let conflict = conflictMessage {
                    Text(conflict)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.danger)
                }
                HStack {
                    Text("An alias is a short word you type to reach this item first.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    Spacer()
                    Button("Done") { viewModel.dismissItemActionLayer() }
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        case .hotkey:
            VStack(alignment: .leading, spacing: 8) {
                ActionHotkeyRecorderView(
                    hotkey: hotkeyBinding,
                    label: "Global hotkey",
                    changeNotification: .launcherItemHotkeysChanged
                )
                if let conflict = conflictMessage {
                    Text(conflict)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.danger)
                }
                HStack {
                    Text("A global hotkey runs this item from anywhere.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    Spacer()
                    Button("Done") { viewModel.dismissItemActionLayer() }
                        .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        case .screenHistorySave:
            ScreenHistorySaveForm(viewModel: viewModel, result: result, formFocused: $formFocused)
        }
    }

    private var aliasBinding: Binding<String> {
        Binding(
            get: {
                if let application { return viewModel.applicationAlias(for: application) }
                if let item { return viewModel.launcherItemAlias(for: item) }
                return ""
            },
            set: { value in
                if let application { viewModel.setApplicationAlias(value, for: application) }
                else if let item { viewModel.setLauncherItemAlias(value, for: item) }
            }
        )
    }

    private var hotkeyBinding: Binding<ActionHotkey?> {
        Binding(
            get: {
                if let application { return viewModel.applicationHotkey(for: application) }
                if let item { return viewModel.launcherItemHotkey(for: item) }
                return nil
            },
            set: { value in
                if let application { viewModel.setApplicationHotkey(value, for: application) }
                else if let item { viewModel.setLauncherItemHotkey(value, for: item) }
            }
        )
    }

    private var conflictMessage: String? {
        if let application { return viewModel.applicationConfigurationConflict(for: application) }
        if let item { return viewModel.launcherItemConfigurationConflict(for: item) }
        return nil
    }

    // MARK: Helpers

    private func syncEditor() {
        guard let item else { return }
        editedTitle = item.title
        editedValue = item.value
    }

    private func saveEdit() {
        guard let item else { return }
        viewModel.commitItemEdit(item, title: editedTitle, value: editedValue)
    }

    private func focusSearch() {
        FocusRequest.apply($searchFocused)
    }

    private func focusForm() {
        FocusRequest.apply($formFocused)
    }

    private func move(_ delta: Int) {
        guard !actions.isEmpty else { return }
        selectedIndex = ListSelection.wrappedIndex(selectedIndex, by: delta, count: actions.count)
        announceSelectedAction()
    }

    private func announceSelectedAction() {
        guard actions.indices.contains(selectedIndex) else { return }
        viewModel.screenHistory.announceActionSelection(
            actions[selectedIndex],
            position: selectedIndex + 1,
            total: actions.count
        )
    }

    private func runSelected() {
        let current = actions
        guard current.indices.contains(selectedIndex) else { return }
        Task { await viewModel.perform(current[selectedIndex], on: result) }
    }
}

/// The `⌘K` palette: answer actions, the window's own actions, attach
/// commands, and saved prompts. Floats over the launcher, the Quick AI
/// surface, and the AI Chat window.
struct QuickActionPalette: View {
    @Bindable var viewModel: QuickViewModel
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    enum Entry: Identifiable {
        case result(ResultAction)
        case surface(QuickAISurfaceAction)
        case command(LauncherCatalogItem)
        case prompt(SavedPrompt)
        /// `⌘K` › Tools: one of the chat's tools, toggled by Return.
        case tool(ChatToolKind)
        case searchProvider(WebSearchProvider)
        /// `⌘K` › Open Source: one of the answer's sources.
        case source(ChatSource)
        /// `⌘K` › Copy Message or Capture Message to Memory: one message.
        case message(QuickMessage)

        var id: String {
            switch self {
            case .result(let action): "result:" + action.id
            case .surface(let action): "surface:" + action.id
            case .command(let item): "command:" + item.itemID
            case .prompt(let prompt): "prompt:" + prompt.id.uuidString
            case .tool(let kind): "tool:" + kind.rawValue
            case .searchProvider(let provider): "search-provider:" + provider.rawValue
            case .source(let source): "source:" + source.id
            case .message(let message): "message:" + message.id.uuidString
            }
        }
    }

    private var entries: [Entry] {
        switch viewModel.actionPaletteSubmenu {
        case .tools:
            return viewModel.paletteToolRows.map(Entry.tool)
        case .searchProviders:
            return viewModel.paletteSearchProviders.map(Entry.searchProvider)
        case .sources:
            return viewModel.paletteSourceRows.map(Entry.source)
        case .messages:
            return viewModel.paletteMessageRows.map(Entry.message)
        case nil:
            return viewModel.paletteResultActions.map(Entry.result)
                + viewModel.paletteSurfaceActions.map(Entry.surface)
                + viewModel.paletteCommandMatches.map(Entry.command)
                + viewModel.actionMatches.map(Entry.prompt)
        }
    }

    private var searchPrompt: String {
        switch viewModel.actionPaletteSubmenu {
        case .tools: "Search tools"
        case .searchProviders: "Search providers"
        case .sources: "Search sources"
        case .messages: "Search messages"
        case nil: "Search actions"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(searchPrompt, text: $viewModel.actionQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { runSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                KeyCapGroup(keys: viewModel.shortcutKeyCaps(for: .commandPalette))
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.vertical, 10)

            SelectableListPane(
                items: entries,
                selectedIndex: $selectedIndex,
                rowSpacing: PanelSizing.actionRowSpacing,
                rowHeight: PanelSizing.actionRowHeight,
                listInsets: EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6),
                emptyText: "No actions here yet",
                scrollsToSelection: true,
                accessibilityValue: { index, isSelected in
                    isSelected
                        ? "Selected, \(index + 1) of \(entries.count)"
                        : "\(index + 1) of \(entries.count)"
                },
                onActivate: run
            ) { _, entry, isSelected in
                row(for: entry, isSelected: isSelected)
                    .padding(.horizontal, 20)
            }
            // Hug the rows (capped at six); an empty palette shows one quiet
            // placeholder row instead of a stretched dark sheet.
            .modifier(ComposerPaneListHeight(
                preferredHeight: PanelSizing.actionListHeight(rows: entries.count, padded: false),
                chromeHeight: PanelSizing.actionPaletteHeight(rows: 1) - PanelSizing.actionListHeight(rows: 1, padded: false)
            ))

            HStack(spacing: AQDesign.Space.row) {
                Text("↑↓ Navigate")
                switch viewModel.actionPaletteSubmenu {
                case .tools:
                    Text("↩ Turn on or off")
                    Text("For this chat")
                case .searchProviders:
                    Text("↩ Use provider")
                    Text("All chats")
                case .sources:
                    Text("↩ Open")
                case .messages(let action):
                    Text(action == .copy ? "↩ Copy" : "↩ Capture")
                case nil:
                    Text("↩ Run")
                    Text("Tab completes aliases")
                }
                Spacer()
                Text(viewModel.actionPaletteSubmenu == nil ? "Esc Close" : "Esc Back")
            }
            .font(AQDesign.TypeToken.metadata)
            .foregroundStyle(AQDesign.ColorToken.textTertiary)
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.bottom, 10)
        }
        .onAppear {
            focusSearch()
            announceSelected()
        }
        .onChange(of: viewModel.actionQuery) { _, _ in
            selectedIndex = 0
            announceSelected()
        }
        .onChange(of: viewModel.actionPaletteSubmenu) { _, _ in
            selectedIndex = 0
            announceSelected()
        }
    }

    @ViewBuilder
    private func row(for entry: Entry, isSelected: Bool) -> some View {
        switch entry {
        case .result(let action):
            paletteRow(symbol: viewModel.resultActionSystemImage(action), title: viewModel.resultActionTitle(action), detail: viewModel.resultActionDetail(action) ?? action.paletteGroup) {
                // The row names the key the router answers, not the default.
                KeyCapGroup(keys: viewModel.shortcutKeyCaps(for: ShortcutAction.forResultAction(action)))
            }
        case .surface(let action):
            paletteRow(symbol: action.systemImage, title: action.title, detail: action.detail) {
                if let actionName = action.shortcutAction {
                    KeyCapGroup(keys: viewModel.shortcutKeyCaps(for: actionName))
                } else if let shortcut = action.shortcut {
                    KeyCapGroup(keys: shortcut.keyCaps)
                }
            }
        case .command(let item):
            paletteRow(symbol: item.systemImage, title: item.title, detail: item.detail) {
                EmptyView()
            }
        case .prompt(let action):
            // An assistant row picks the assistant for the chat; every other
            // row runs its prompt on the text.
            paletteRow(
                symbol: action.isAssistant
                    ? ResultAction.changeAssistant.systemImage
                    : (action.outputBehavior == .replaceSelection ? "text.cursor" : "sparkles"),
                title: action.name,
                detail: "\(viewModel.settings.savedPromptPrefix)\(action.alias) · "
                    + (action.isAssistant ? "Assistant" : action.outputBehavior.displayName)
            ) {
                if let hotkey = action.hotkey {
                    KeyCapGroup(keys: hotkey.keyCaps)
                }
            }
        case .searchProvider(let provider):
            paletteRow(symbol: "magnifyingglass", title: provider.title, detail: provider.detail) {
                if viewModel.settings.webSearchProvider == provider {
                    Image(systemName: "checkmark")
                        .accessibilityLabel("Current provider")
                }
            }
        case .tool(let kind):
            let isAvailable = viewModel.isChatToolAvailable(kind)
            // A tool this Mac cannot run is never offered, whatever the chat
            // chose, so its row says so instead of "On".
            let isOn = isAvailable && viewModel.chatTools.contains(kind)
            paletteRow(
                symbol: kind.systemImage,
                title: kind.displayName,
                detail: isAvailable ? kind.detail : "Not available on this Mac"
            ) {
                HStack(spacing: AQDesign.Space.compact) {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                            .accessibilityHidden(true)
                    }
                    Text(isAvailable ? (isOn ? "On" : "Off") : "Unavailable")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(isOn ? AQDesign.ColorToken.textPrimary : AQDesign.ColorToken.textTertiary)
                }
            }
        case .source(let source):
            paletteRow(
                symbol: "doc.text",
                title: source.title,
                detail: source.day ?? "Source"
            ) {
                EmptyView()
            }
        case .message(let message):
            paletteRow(
                symbol: message.role == .user ? "text.bubble" : "sparkles",
                title: QuickViewModel.messagePreview(message),
                detail: viewModel.messageDetail(message)
            ) {
                EmptyView()
            }
        }
    }

    /// Every palette row is the same shape: tile, title, detail, keys.
    @ViewBuilder
    private func paletteRow<Trailing: View>(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: AQDesign.Space.row) {
            IconTile {
                Image(systemName: symbol)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
            }
            HStack(alignment: .firstTextBaseline, spacing: AQDesign.Space.standard) {
                Text(title)
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: AQDesign.Space.standard)
            trailing()
        }
    }

    private func focusSearch() {
        FocusRequest.apply($searchFocused)
    }

    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = ListSelection.wrappedIndex(selectedIndex, by: delta, count: entries.count)
        announceSelected()
    }

    private func announceSelected() {
        let current = entries
        guard current.indices.contains(selectedIndex) else { return }
        let title: String
        switch current[selectedIndex] {
        case .result(let action): title = viewModel.resultActionTitle(action)
        case .surface(let action): title = action.title
        case .command(let item): title = item.title
        case .prompt(let prompt): title = prompt.name
        case .searchProvider(let provider):
            title = provider.title + (viewModel.settings.webSearchProvider == provider ? ", current provider" : "")
        case .tool(let kind):
            title = "\(kind.displayName), \(viewModel.chatTools.contains(kind) ? "on" : "off")"
        case .source(let source): title = "Source \(source.title)"
        case .message(let message):
            title = "\(viewModel.messageDetail(message)), \(QuickViewModel.messagePreview(message))"
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(title), selected, \(selectedIndex + 1) of \(current.count).",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func runSelected() {
        let current = entries
        guard current.indices.contains(selectedIndex) else { return }
        run(current[selectedIndex])
    }

    private func run(_ entry: Entry) {
        switch entry {
        case .result(let action):
            Task { await viewModel.performResultAction(action) }
        case .surface(let action):
            viewModel.performQuickAISurfaceAction(action)
        case .command(let item):
            Task { await viewModel.runPaletteCommand(item) }
        case .prompt(let action):
            Task { await viewModel.perform(action: action) }
        case .tool(let kind):
            // The palette stays open so several tools can change at once.
            viewModel.toggleChatTool(kind)
            announceSelected()
        case .searchProvider(let provider):
            viewModel.selectWebSearchProvider(provider)
        case .source(let source):
            viewModel.requestOpenSource(source)
        case .message(let message):
            guard case .messages(let action) = viewModel.actionPaletteSubmenu else { return }
            Task { await viewModel.performMessageAction(action, on: message) }
        }
    }
}

/// Raycast-style key hints: context on the left, actions on the right.
private struct LauncherFooter: View {
    @Bindable var viewModel: QuickViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var visibleHints: [QuickViewModel.FooterHint] {
        let hints = viewModel.footerHints
        if dynamicTypeSize.isAccessibilitySize {
            return Array(hints.prefix(1))
        }
        guard let primary = hints.first else { return [] }
        if let actions = hints.first(where: { $0.label == "Actions" }) {
            // Show the primary destination, the next concrete action (the
            // paste/copy destination), then Actions — so a selection transform's
            // Replace and Paste destinations are both visible, not just ⌘K.
            let others = hints.filter { $0.label != "Actions" }
            return Array(([primary] + others.dropFirst()).prefix(2) + [actions])
        }
        return Array(hints.prefix(2))
    }

    var body: some View {
        HStack(spacing: AQDesign.Space.row) {
            StatusDot(color: viewModel.isStreaming
                ? AQDesign.ColorToken.warning
                : AQDesign.ColorToken.success)
            Text(viewModel.footerContext)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AQDesign.Space.row)
            HStack(spacing: AQDesign.Space.row) {
                ForEach(visibleHints, id: \.label) { hint in
                    KeyHint(label: hint.label, keys: hint.keys)
                }
            }
        }
        .modifier(ScreenHistoryFooterFrame(
            isActive: viewModel.catalogScope == .screenHistory,
            defaultMinHeight: AQDesign.footerHeight
        ))
        .accessibilityElement(children: .combine)
    }
}

/// A coloured light and its word: "● On" in the success colour, "● Off" in
/// the danger colour, "● Paused" in the warning colour while a live session's
/// assertion is released by the battery. Read at a glance before the row text.
struct StatusLightLabel: View {
    let light: LauncherStatusLight

    private var color: Color {
        switch light {
        case .on: AQDesign.ColorToken.success
        case .paused: AQDesign.ColorToken.warning
        case .off: AQDesign.ColorToken.danger
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(light.label)
                .font(AQDesign.TypeToken.metadata.weight(.medium))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(light.label)
    }
}

/// Three dots that breathe in turn: the model is working. Subtle on purpose.
struct ThinkingIndicator: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `@State`, not a stored `let`: a stored publisher is rebuilt on every
    /// view init during streaming, which resets the subscription and can
    /// freeze the dots at phase 0. State keeps one publisher per identity.
    @State private var timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AQDesign.ColorToken.textPrimary)
                    .frame(width: 5, height: 5)
                    .opacity(reduceMotion ? 0.55 : (index == phase ? 0.95 : 0.3))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: phase)
        .onReceive(timer) { _ in
            guard !reduceMotion else { return }
            phase = (phase + 1) % 3
        }
        .accessibilityLabel("Working")
    }
}

// MARK: - Shared composer pieces
//
// The root input row and the Quick AI composer are two fields with one
// keyboard contract; the strips and choosers under them are the same views
// on both surfaces (inline at root, floating over the Quick AI thread).

/// The arrow keys and Tab, routed in one fixed precedence: a live question,
/// the Transform chooser, the model chooser, Add Context, Recent Chats, the
/// answer's chat browsing, then the launcher list.
struct ComposerKeyRouting: ViewModifier {
    @Bindable var viewModel: QuickViewModel

    func body(content: Content) -> some View {
        content
            .onKeyPress(.tab) {
                viewModel.handleTab() ? .handled : .ignored
            }
            .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown], phases: [.down, .repeat]) { press in
                arrow(press)
            }
            .onKeyPress(.rightArrow) {
                guard viewModel.isGridCatalog, !viewModel.launcherMatches.isEmpty else { return .ignored }
                viewModel.moveApplicationSelection(1)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard viewModel.isGridCatalog, !viewModel.launcherMatches.isEmpty else { return .ignored }
                viewModel.moveApplicationSelection(-1)
                return .handled
            }
    }

    /// ↑ ↓ PageUp PageDown. On the Quick AI thread, PageUp and PageDown,
    /// ⌥↑ ⌥↓, and ⌘↑ ⌘↓ scroll it (the panel's shortcut path usually takes
    /// the modified arrows first; this is the same rule for the field).
    /// Plain ↑ ↓ move whatever list is up.
    private func arrow(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers == .command
        let option = press.modifiers == .option
        let key: QuickViewModel.ThreadKey
        switch press.key {
        case .pageUp: key = .pageUp
        case .pageDown: key = .pageDown
        case .upArrow: key = .up
        default: key = .down
        }
        let pages = key == .pageUp || key == .pageDown
        if pages || command || option {
            if viewModel.handleThreadKey(key, command: command, option: option) { return .handled }
            // Off the thread PageUp and PageDown are the field's; a modified
            // arrow moves a list as a plain one does.
            if pages { return .ignored }
        }
        return move(key == .up ? -1 : 1)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        if viewModel.isAskQuestionActive {
            viewModel.moveAskQuestionSelection(delta)
            return .handled
        }
        if viewModel.isTransformChooserPresented {
            viewModel.moveTransformChooserSelection(delta)
            return .handled
        }
        if viewModel.isModelChooserPresented {
            viewModel.moveModelChooserSelection(delta)
            return .handled
        }
        if viewModel.isAssistantChooserPresented {
            viewModel.moveAssistantChooserSelection(delta)
            return .handled
        }
        if viewModel.isCaptureChooserPresented {
            viewModel.moveCaptureChooserSelection(delta)
            return .handled
        }
        if viewModel.isAddContextMenuPresented {
            viewModel.moveAddContextSelection(delta)
            return .handled
        }
        if viewModel.isRecentChatsPresented {
            viewModel.moveRecentChatsSelection(delta)
            return .handled
        }
        // On the Quick AI surface ↑ on an empty composer recalls the last
        // question and ↓ does nothing; with text the keys are the field's.
        if viewModel.isQuickAIPresented {
            return viewModel.handleComposerArrow(delta) ? .handled : .ignored
        }
        guard !viewModel.launcherMatches.isEmpty else { return .ignored }
        viewModel.moveSelectionVertically(delta)
        return .handled
    }
}

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
                Text("Transform selected text")
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
                items: viewModel.chipTransformOptions,
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
                preferredHeight: PanelSizing.actionListHeight(rows: viewModel.chipTransformOptions.count, padded: false)
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
            if let tray = activeTray, tray.isEnteringLink {
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
