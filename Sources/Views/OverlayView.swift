import SwiftUI
import Combine

struct OverlayView: View {
    @Bindable var viewModel: QuickViewModel
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The send button icon and color change based on state:
    ///  - idle: arrow.up.circle.fill (purple)
    ///  - streaming: stop.fill (purple)
    ///  - justCopied: checkmark.circle.fill (green, 2s)
    private var sendIcon: String {
        if viewModel.justCopied { return "checkmark.circle.fill" }
        if viewModel.isStreaming { return "stop.fill" }
        return "arrow.up.circle.fill"
    }

    private var sendColor: Color {
        viewModel.justCopied
            ? AQDesign.ColorToken.success
            : AQDesign.ColorToken.accent
    }

    var body: some View {
        VStack(spacing: 0) {
            // Input row
            HStack(spacing: AQDesign.Space.standard) {
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
                    .onKeyPress(.tab) {
                        viewModel.handleTab() ? .handled : .ignored
                    }
                    .onKeyPress(.downArrow) {
                        if viewModel.isAnswerActive, viewModel.input.isEmpty {
                            viewModel.browseConversations(1)
                            return .handled
                        }
                        guard !viewModel.launcherMatches.isEmpty else { return .ignored }
                        viewModel.moveSelectionVertically(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        if viewModel.isAnswerActive, viewModel.input.isEmpty {
                            viewModel.browseConversations(-1)
                            return .handled
                        }
                        guard !viewModel.launcherMatches.isEmpty else { return .ignored }
                        viewModel.moveSelectionVertically(-1)
                        return .handled
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
                    .onChange(of: viewModel.input) { _, _ in
                        viewModel.resetApplicationSelection()
                        viewModel.noteInteraction()
                        viewModel.screenHistory.inputDidChange()
                    }
                    .disabled(viewModel.isStreaming)

                // Send / stop / copied indicator — same slot, different icon
                Button {
                    if viewModel.isStreaming {
                        viewModel.cancel()
                    } else {
                        Task { await viewModel.submitResolvingFuzzyAlias() }
                    }
                } label: {
                    if viewModel.isStreaming {
                        ThinkingIndicator()
                            .frame(width: 22, height: 22)
                            .help("Working… press Escape to stop")
                    } else {
                        Image(systemName: sendIcon)
                            .foregroundStyle(sendColor)
                            .font(.title2)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(viewModel.isStreaming ? "Stop response" : "Send")
                .disabled(
                    viewModel.input.isEmpty
                        && viewModel.pendingImage == nil
                        && !viewModel.isStreaming
                )
                .help(viewModel.justCopied ? "Copied to clipboard" : "Send (or press Return)")

                moreMenu
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            if viewModel.hasPendingAttachment {
                Divider()
                HStack(spacing: AQDesign.Space.standard) {
                    HStack(spacing: 4) {
                        ForEach(Array(viewModel.pendingImages.suffix(4).enumerated()), id: \.offset) { _, image in
                            if let preview = NSImage(data: image.data) {
                                Image(nsImage: preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .accessibilityLabel(
                                        "Attached screenshot, \(image.pixelWidth) by \(image.pixelHeight) pixels"
                                    )
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.attachmentTitle)
                            .font(AQDesign.TypeToken.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(viewModel.attachmentSubtitle)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        viewModel.clearAttachments()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove attachments")
                    .help("Remove all attachments (⌫ removes the newest)")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            if !viewModel.launcherMatches.isEmpty {
                Divider()
                if viewModel.isGridCatalog {
                    EmojiGridView(viewModel: viewModel)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        launcherList
                            .frame(width: viewModel.showsDetailPane ? 380 : nil)
                        if viewModel.showsDetailPane, let item = viewModel.detailItem {
                            Divider()
                            CatalogDetailPane(viewModel: viewModel, item: item)
                        }
                    }
                }
            }

            screenHistoryStatusSurface

            // Saved-prompt autocomplete
            if !viewModel.isApplicationActionPanePresented,
               !viewModel.isCatalogActionPanePresented,
               !viewModel.savedPromptMatches.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.savedPromptMatches) { match in
                        Button {
                            viewModel.complete(savedPrompt: match)
                        } label: {
                            HStack(spacing: 10) {
                                Text(viewModel.settings.savedPromptPrefix + match.alias)
                                    .font(AQDesign.TypeToken.codeLabel)
                                    .foregroundStyle(AQDesign.ColorToken.accent)
                                Text(match.prompt)
                                    .font(AQDesign.TypeToken.detail)
                                    .foregroundStyle(.secondary)
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

            if !viewModel.output.isEmpty || viewModel.isStreaming {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.conversationMessages.count > 2 {
                        // Earlier turns, compact; the latest answer follows in full.
                        ConversationTranscript(messages: Array(viewModel.conversationMessages.dropLast(2)))
                            .frame(maxHeight: PanelSizing.transcriptHeight)
                        Divider()
                    }
                    if let question = viewModel.lastQuestion, !question.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "text.cursor")
                                .font(AQDesign.TypeToken.caption)
                            Text(question)
                                .font(AQDesign.TypeToken.label)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Question: \(question)")
                    }
                    if viewModel.isStreaming, viewModel.output.isEmpty {
                        HStack(spacing: 8) {
                            ThinkingIndicator()
                                .frame(width: 18, height: 18)
                            Text(viewModel.streamingStatus ?? "Thinking…")
                                .font(AQDesign.TypeToken.label)
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 28)
                    } else {
                        MarkdownTextView(
                            markdown: viewModel.output,
                            isStreaming: viewModel.isStreaming
                        )
                        .frame(maxHeight: PanelSizing.maxBodyHeight)
                    }
                }
                .padding(20)
                .transition(.opacity)
            }

            // Error message
            if let error = viewModel.errorMessage {
                Divider()
                HStack(spacing: AQDesign.Space.standard) {
                    Text(error)
                        .font(AQDesign.TypeToken.detail)
                        .foregroundStyle(AQDesign.ColorToken.danger)
                    Spacer()
                    if viewModel.needsAccessibilityPermission {
                        Button("Open System Settings") {
                            viewModel.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            if viewModel.showsLauncherFooter {
                Divider()
                LauncherFooter(viewModel: viewModel)
            }
        }
        .frame(width: viewModel.currentPanelWidth)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                AQDesign.ColorToken.panelTint
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AQDesign.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AQDesign.cornerRadius)
                .strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            actionPopover
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

    private func focusInput() {
        FocusRequest.apply($inputFocused)
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
        .frame(width: min(520, viewModel.currentPanelWidth - 24))
        // Chrome hugs the content: a `.frame(maxHeight:)` adopts the window's
        // proposal, so background applied outside it stretched into an empty
        // dark sheet whenever the window was tall.
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                AQDesign.ColorToken.panelTint
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius)
                .strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
        .frame(
            maxHeight: viewModel.activeItemActionForm?.minimumWindowHeight
                .map { $0 - PanelSizing.inputHeight - PanelSizing.paneBottomMargin }
                ?? 460,
            alignment: .top
        )
        // Below the input row and, when present, the attachment strip:
        // without the offset the pane covered the attachment preview.
        .padding(
            .top,
            PanelSizing.inputHeight
                + (viewModel.hasPendingAttachment ? PanelSizing.attachmentHeight : 0)
        )
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private var screenHistoryStatusSurface: some View {
        if viewModel.catalogScope == .screenHistory,
           !viewModel.isItemActionPanePresented,
           viewModel.launcherMatches.isEmpty {
            Divider()
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
            Text(launcherSectionTitle)
                .font(AQDesign.TypeToken.section)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

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
                .padding(.horizontal, 12)
                .modifier(ScreenHistoryRowFrame(result: result))
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
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
            ForEach(ScreenshotKind.allCases, id: \.rawValue) { kind in
                Button {
                    Task { await viewModel.attachScreenshot(kind, clearingInput: false) }
                } label: {
                    Label(
                        "\(kind.title)  \(kind.overlayKeyCaps.joined())",
                        systemImage: kind.systemImage
                    )
                }
            }

            Divider()
            modelSubmenu
            historySubmenu

            Divider()
            Button {
                viewModel.overlayPresenter.openSettings()
            } label: {
                Label("Settings…", systemImage: "gear")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(AQDesign.TypeToken.input)
                .foregroundStyle(viewModel.isActionPalettePresented ? sendColor : .secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(AQDesign.ColorToken.surfaceFill))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("More actions")
        .help("Actions, model, history, and settings")
    }

    private var modelSubmenu: some View {
        Menu {
            Text("Using \(viewModel.activeModelDisplay)")
            Divider()
            ForEach(viewModel.settings.providers) { provider in
                Menu(provider.name) {
                    if provider.models.isEmpty {
                        Button("Refresh models") {
                            Task { await viewModel.refreshModels(providerID: provider.id) }
                        }
                    } else {
                        ForEach(provider.models, id: \.self) { model in
                            Button {
                                viewModel.selectModel(providerID: provider.id, model: model)
                            } label: {
                                if provider.id == viewModel.settings.selectedProviderID,
                                   model == provider.selectedModel {
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

    private var historySubmenu: some View {
        Menu {
            Button("New AI Chat") { viewModel.startNewConversation() }
            if !viewModel.history.isEmpty {
                Divider()
                ForEach(viewModel.history.prefix(10)) { conversation in
                    Button(conversation.title) {
                        viewModel.loadConversation(id: conversation.id)
                    }
                }
            }
        } label: {
            Label("Recent AI Chats", systemImage: "clock.arrow.circlepath")
        }
    }
}

private struct ConversationTranscript: View {
    let messages: [QuickMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role == .user ? "You" : "Answer")
                                .font(AQDesign.TypeToken.section)
                                .foregroundStyle(
                                    message.role == .user ? AQDesign.ColorToken.accent : .secondary
                                )
                            Text(String(message.content.prefix(2_000)))
                                .font(AQDesign.TypeToken.detail)
                                .lineLimit(message.role == .user ? 3 : 8)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(message.id)
                    }
                }
                // No horizontal inset: earlier turns line up with the
                // question row and the answer below them.
                .padding(.vertical, 8)
            }
            .onAppear {
                guard let lastID = messages.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
            .onChange(of: messages.count) { _, _ in
                guard let lastID = messages.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
        .accessibilityLabel("Current quick action conversation")
    }
}

private struct LauncherResultRow: View {
    let result: LauncherSearchResult
    let isSelected: Bool
    var hotkey: ActionHotkey? = nil
    var position: Int? = nil
    var total: Int? = nil

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 24, height: 24)
            if let screenHistoryRow {
                screenHistoryRow
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(title)
                        .font(AQDesign.TypeToken.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Spacer()
            if case .item(let item) = result, item.isPinned {
                Image(systemName: "pin.fill")
                    .font(AQDesign.TypeToken.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
            if let hotkey {
                KeyCapGroup(keys: hotkey.keyCaps)
                    .accessibilityLabel("Hotkey \(hotkey.displayName)")
            } else if screenHistoryRow == nil {
                Text(resultType)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder private var icon: some View {
        switch result {
        case .application(let application):
            Image(nsImage: AppIconCache.icon(forPath: application.url.path))
                .resizable().scaledToFit()
        case .catalog(let scope, _):
            Image(systemName: scope.systemImage).foregroundStyle(AQDesign.ColorToken.accent)
        case .item(let item):
            if item.kind == .emoji {
                Text(item.value).font(AQDesign.TypeToken.glyph)
            } else if item.kind == .screenshot, let thumbnail = ScreenshotThumbnailCache.thumbnail(forPath: item.value, maximumPixels: 96) {
                Image(nsImage: thumbnail)
                    .resizable().scaledToFill()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: item.systemImage).foregroundStyle(AQDesign.ColorToken.accent)
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

    private var resultType: String {
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
            case .conversation: "AI Chat"
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
            Divider()
            if let form = viewModel.activeItemActionForm {
                formView(form)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            } else {
                list
                Divider()
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
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AQDesign.TypeToken.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(viewModel.activeItemActionForm == nil ? "Actions" : formTitle)
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var icon: some View {
        if let application {
            Image(nsImage: AppIconCache.icon(forPath: application.url.path))
                .resizable().scaledToFit()
        } else if let item, item.kind == .emoji {
            Text(item.value).font(AQDesign.TypeToken.glyph)
        } else if let item {
            Image(systemName: item.systemImage).foregroundStyle(AQDesign.ColorToken.accent)
        }
    }

    private var title: String {
        application?.name ?? item?.title ?? ""
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
        case .edit: "Edit"
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
        ) { _, action, isSelected in
            HStack(spacing: 10) {
                Image(systemName: action.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(
                        action.isDestructive
                            ? AQDesign.ColorToken.danger
                            : (isSelected ? AQDesign.ColorToken.accent : .secondary)
                    )
                Text(action.title)
                    .font(AQDesign.TypeToken.body.weight(.medium))
                    .foregroundStyle(action.isDestructive ? AQDesign.ColorToken.danger : .primary)
                Spacer()
                if let shortcut = action.shortcut {
                    KeyCapGroup(keys: shortcut.keyCaps)
                }
            }
            .padding(.horizontal, 12)
        }
        // Exactly as tall as its rows (capped at six): the pane hugs its
        // content instead of stretching into an empty dark sheet.
        .frame(height: PanelSizing.actionListHeight(rows: actions.count))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search actions…", text: $viewModel.actionQuery)
                .textFieldStyle(.plain)
                .font(AQDesign.TypeToken.body)
                .focused($searchFocused)
                .onSubmit { runSelected() }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
            KeyCapGroup(keys: ["⌘", "K"])
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
                TextField("Snippet name", text: $editedTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($formFocused)
                    .onChange(of: editedTitle) { _, _ in viewModel.noteInteraction() }
                TextEditor(text: $editedValue)
                    .font(.body.monospaced())
                    .frame(minHeight: 72, maxHeight: 130)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .onChange(of: editedValue) { _, _ in viewModel.noteInteraction() }
                HStack(spacing: AQDesign.Space.standard) {
                    Button {
                        saveEdit()
                    } label: {
                        Label("Save", systemImage: "checkmark")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") { viewModel.dismissItemActionLayer() }
                    Spacer()
                    Text("⌘↩ saves · esc cancels")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
        _ = viewModel.updateSnippet(item, title: editedTitle, value: editedValue)
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

private struct QuickActionPalette: View {
    @Bindable var viewModel: QuickViewModel
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    enum Entry: Identifiable {
        case result(ResultAction)
        case command(LauncherCatalogItem)
        case prompt(SavedPrompt)

        var id: String {
            switch self {
            case .result(let action): "result:" + action.id
            case .command(let item): "command:" + item.itemID
            case .prompt(let prompt): "prompt:" + prompt.id.uuidString
            }
        }
    }

    private var entries: [Entry] {
        viewModel.paletteResultActions.map(Entry.result)
            + viewModel.paletteCommandMatches.map(Entry.command)
            + viewModel.actionMatches.map(Entry.prompt)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search actions", text: $viewModel.actionQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { runSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Text("⌘K")
                    .font(AQDesign.TypeToken.hint.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            SelectableListPane(
                items: entries,
                selectedIndex: $selectedIndex,
                rowSpacing: PanelSizing.actionRowSpacing,
                rowHeight: PanelSizing.actionRowHeight,
                listInsets: EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6),
                emptyText: "No actions here yet",
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
            .frame(height: PanelSizing.actionListHeight(rows: entries.count, padded: false))

            HStack(spacing: 12) {
                Text("↑↓ Navigate")
                Text("↩ Run")
                Text("Tab completes aliases")
                Spacer()
                Text("Esc Close")
            }
            .font(AQDesign.TypeToken.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
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
    }

    @ViewBuilder
    private func row(for entry: Entry, isSelected: Bool) -> some View {
        switch entry {
        case .result(let action):
            HStack(spacing: 10) {
                Image(systemName: action.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? AQDesign.ColorToken.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(AQDesign.TypeToken.body.weight(.medium))
                    Text("Answer")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KeyCapGroup(keys: action.shortcut.keyCaps)
            }
        case .command(let item):
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? AQDesign.ColorToken.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(AQDesign.TypeToken.body.weight(.medium))
                    Text(item.detail)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
        case .prompt(let action):
            HStack(spacing: 10) {
                Image(systemName: action.outputBehavior == .replaceSelection
                      ? "text.cursor" : "sparkles")
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? AQDesign.ColorToken.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.name)
                        .font(AQDesign.TypeToken.body.weight(.medium))
                    Text("\(viewModel.settings.savedPromptPrefix)\(action.alias) · \(action.outputBehavior.displayName)")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let hotkey = action.hotkey {
                    KeyCapGroup(keys: hotkey.keyCaps)
                }
            }
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
        case .result(let action): title = action.title
        case .command(let item): title = item.title
        case .prompt(let prompt): title = prompt.name
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
        case .command(let item):
            Task { await viewModel.runPaletteCommand(item) }
        case .prompt(let action):
            Task { await viewModel.perform(action: action) }
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
            return [primary, actions]
        }
        return Array(hints.prefix(2))
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(viewModel.footerContext)
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                ForEach(visibleHints, id: \.label) { hint in
                    HStack(spacing: 5) {
                        Text(hint.label)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(.secondary)
                        KeyCapGroup(keys: hint.keys)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                    .fill(AQDesign.ColorToken.surfaceFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                    .strokeBorder(AQDesign.ColorToken.keyCapStroke, lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .modifier(ScreenHistoryFooterFrame(
            isActive: viewModel.catalogScope == .screenHistory,
            defaultMinHeight: AQDesign.footerHeight
        ))
        .accessibilityElement(children: .combine)
    }
}

/// A short run of key caps such as ⌥ ⌘ ←.
struct KeyCapGroup: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCap(text: key)
            }
        }
    }
}

struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AQDesign.TypeToken.keyCap)
            .foregroundStyle(.secondary)
            .padding(.horizontal, text.count > 1 ? 5 : 0)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: AQDesign.keyCapCornerRadius)
                    .fill(AQDesign.ColorToken.keyCapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AQDesign.keyCapCornerRadius)
                    .strokeBorder(AQDesign.ColorToken.keyCapStroke, lineWidth: 0.5)
            )
    }
}



/// Three dots that breathe in turn: the model is working. Subtle on purpose.
struct ThinkingIndicator: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AQDesign.ColorToken.accent)
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
