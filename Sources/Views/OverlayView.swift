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
                TextField(
                    viewModel.inputPlaceholder,
                    text: $viewModel.input,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.input)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await viewModel.submitResolvingFuzzyAlias() } }
                    .onKeyPress(.tab) {
                        if viewModel.inputMode == .translate {
                            viewModel.flipTranslationDirection()
                            return .handled
                        }
                        guard !viewModel.savedPromptMatches.isEmpty else { return .ignored }
                        viewModel.completeFirstFuzzyAlias()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !viewModel.launcherMatches.isEmpty else { return .ignored }
                        viewModel.moveSelectionVertically(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
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
                    .onKeyPress(.delete) {
                        viewModel.popLayerForEmptyBackspace() ? .handled : .ignored
                    }
                    .onChange(of: viewModel.input) { _, _ in
                        viewModel.resetApplicationSelection()
                        viewModel.noteInteraction()
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
                    Image(systemName: sendIcon)
                        .foregroundStyle(sendColor)
                        .font(.system(size: 20))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
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
                    if let image = viewModel.pendingImage, let preview = NSImage(data: image.data) {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel(
                                "Attached screenshot, \(image.pixelWidth) by \(image.pixelHeight) pixels"
                            )
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
                        viewModel.removePendingImage()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove attached screenshot")
                    .help("Remove screenshot")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }

            if viewModel.isItemActionPanePresented,
               let result = viewModel.focusedLauncherResult {
                Divider()
                ItemActionPane(viewModel: viewModel, result: result)
            } else if viewModel.isActionPalettePresented {
                Divider()
                QuickActionPalette(viewModel: viewModel)
            }

            if !viewModel.isActionPalettePresented,
               !viewModel.isApplicationActionPanePresented,
               !viewModel.isCatalogActionPanePresented,
               !viewModel.launcherMatches.isEmpty {
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
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(AQDesign.ColorToken.accent)
                                Text(match.prompt)
                                    .font(.system(size: 12))
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

            if viewModel.isConversationHistoryPresented {
                Divider()
                ConversationTranscript(messages: viewModel.conversationMessages)
                    .transition(.opacity)
            } else if !viewModel.output.isEmpty || viewModel.isStreaming {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
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
                    MarkdownTextView(
                        attributedString: MarkdownRenderer.render(viewModel.output),
                        isStreaming: viewModel.isStreaming
                    )
                    .frame(maxHeight: 380)
                }
                .padding(20)
                .transition(.opacity)
            }

            // Error message
            if let error = viewModel.errorMessage {
                Divider()
                HStack(spacing: AQDesign.Space.standard) {
                    Text(error)
                        .font(.system(size: 12))
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
        .preferredColorScheme(viewModel.settings.appearance.swiftUIColorScheme)
        .animation(
            reduceMotion ? nil : .easeOut(duration: AQDesign.motionDuration),
            value: viewModel.output.isEmpty
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: AQDesign.motionDuration),
            value: viewModel.isConversationHistoryPresented
        )
        .onAppear { focusInput() }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in focusInput() }
        .onKeyPress(.escape) {
            if viewModel.isStreaming {
                viewModel.cancel()
            } else if viewModel.isItemActionPanePresented {
                viewModel.dismissItemActionLayer()
            } else {
                // Raycast convention: Escape closes the window from anywhere.
                // Backspace on an empty field is the way back to the root.
                NotificationCenter.default.post(name: .dismissOverlay, object: nil)
            }
            return .handled
        }
    }

    private func focusInput() {
        Task { @MainActor in
            await Task.yield()
            inputFocused = true
        }
    }

    private var launcherList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(
                Array(viewModel.launcherMatches.enumerated()),
                id: \.element.id
            ) { index, result in
                Button {
                    Task { await viewModel.performLauncherResult(result) }
                } label: {
                    LauncherResultRow(
                        result: result,
                        isSelected: index == viewModel.applicationSelectionIndex,
                        hotkey: viewModel.hotkey(for: result)
                    )
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                            .fill(
                                index == viewModel.applicationSelectionIndex
                                    ? AQDesign.ColorToken.selectionFill
                                    : .clear
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                viewModel.toggleActionPalette()
            } label: {
                Label("Quick Actions…", systemImage: "wand.and.stars")
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

            if !viewModel.conversationMessages.isEmpty {
                Divider()
                Button {
                    viewModel.toggleConversationHistory()
                } label: {
                    Label(
                        viewModel.isConversationHistoryPresented
                            ? "Show Latest Result"
                            : "Show Conversation",
                        systemImage: "text.bubble"
                    )
                }
            }

            Divider()
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Label("Settings…", systemImage: "gear")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16))
                .foregroundStyle(viewModel.isActionPalettePresented ? sendColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
        } label: {
            Label("Model: \(viewModel.activeModelDisplay)", systemImage: "cpu")
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var historySubmenu: some View {
        Menu {
            Button("New quick action") { viewModel.startNewConversation() }
            if !viewModel.history.isEmpty {
                Divider()
                ForEach(viewModel.history.prefix(10)) { conversation in
                    Button(conversation.title) {
                        viewModel.loadConversation(id: conversation.id)
                    }
                }
            }
        } label: {
            Label("Recent Quick Actions", systemImage: "clock.arrow.circlepath")
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
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(
                                    message.role == .user ? AQDesign.ColorToken.accent : .secondary
                                )
                            Text(String(message.content.prefix(8_000)))
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(message.id)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 380)
            .onAppear {
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

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(AQDesign.TypeToken.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(detail).font(AQDesign.TypeToken.caption)
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let hotkey {
                KeyCapGroup(keys: hotkey.keyCaps)
                    .accessibilityLabel("Hotkey \(hotkey.displayName)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isSelected ? "Selected, \(action) with Return" : "")
    }

    @ViewBuilder private var icon: some View {
        switch result {
        case .application(let application):
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                .resizable().scaledToFit()
        case .catalog(let scope, _):
            Image(systemName: scope.systemImage).foregroundStyle(AQDesign.ColorToken.accent)
        case .item(let item):
            if item.kind == .emoji {
                Text(item.value).font(.system(size: 18))
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
        case .catalog(_, let count): "\(count) items"
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
}

/// Raycast-style actions for one row: a list with the shortcut on the right,
/// a search field at the bottom, and small forms for edit, alias, and hotkey.
private struct ItemActionPane: View {
    @Bindable var viewModel: QuickViewModel
    let result: LauncherSearchResult
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool
    @State private var editedTitle = ""
    @State private var editedValue = ""
    @FocusState private var formFocused: Bool

    private var actions: [ItemAction] {
        let all = viewModel.focusedItemActions
        let query = viewModel.actionQuery
        guard !query.isEmpty else { return all }
        return all.filter { FuzzyMatcher.score(query: query, candidate: $0.title) != nil }
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
                .frame(height: 44)
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
        }
        .onChange(of: viewModel.activeItemActionForm) { _, form in
            syncEditor()
            if form == nil { focusSearch() } else { focusForm() }
        }
        .onChange(of: viewModel.actionQuery) { _, _ in selectedIndex = 0 }
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
            Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                .resizable().scaledToFit()
        } else if let item, item.kind == .emoji {
            Text(item.value).font(.system(size: 18))
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
        case .application: return "Application"
        }
    }

    private var formTitle: String {
        switch viewModel.activeItemActionForm {
        case .edit: "Edit"
        case .alias: "Alias"
        case .hotkey: "Hotkey"
        case nil: ""
        }
    }

    // MARK: Action list

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    Button {
                        Task { await viewModel.perform(action, on: result) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: action.systemImage)
                                .frame(width: 18)
                                .foregroundStyle(
                                    action.isDestructive
                                        ? AQDesign.ColorToken.danger
                                        : (index == selectedIndex ? AQDesign.ColorToken.accent : .secondary)
                                )
                            Text(action.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(action.isDestructive ? AQDesign.ColorToken.danger : .primary)
                            Spacer()
                            if let shortcut = action.shortcut {
                                KeyCapGroup(keys: shortcut.keyCaps)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                                .fill(index == selectedIndex ? AQDesign.ColorToken.selectionFill : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 6 * 42 + 12)
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
        .frame(height: 40)
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
        Task { @MainActor in
            await Task.yield()
            searchFocused = true
        }
    }

    private func focusForm() {
        Task { @MainActor in
            await Task.yield()
            formFocused = true
        }
    }

    private func move(_ delta: Int) {
        let count = actions.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
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
        case prompt(SavedPrompt)

        var id: String {
            switch self {
            case .result(let action): "result:" + action.id
            case .prompt(let prompt): "prompt:" + prompt.id.uuidString
            }
        }
    }

    private var resultActions: [ResultAction] {
        let query = viewModel.actionQuery
        return viewModel.resultActions.filter { action in
            query.isEmpty || FuzzyMatcher.score(query: query, candidate: action.title) != nil
        }
    }

    private var entries: [Entry] {
        resultActions.map(Entry.result) + viewModel.actionMatches.map(Entry.prompt)
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
                    .onKeyPress(.escape) {
                        viewModel.closeActionPalette()
                        return .handled
                    }
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        Button { run(entry) } label: {
                            row(for: entry, isSelected: index == selectedIndex)
                                .padding(.horizontal, 20)
                                .frame(height: 42)
                                .background(
                                    index == selectedIndex ? AQDesign.ColorToken.selectionFill : .clear,
                                    in: RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 252)

            HStack(spacing: 12) {
                Text("↑↓ Navigate")
                Text("↩ Run")
                Text("Tab completes aliases")
                Spacer()
                Text("Esc Close")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .onAppear { focusSearch() }
        .onChange(of: viewModel.actionQuery) { _, _ in selectedIndex = 0 }
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
                        .font(.system(size: 13, weight: .medium))
                    Text("Answer")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                KeyCapGroup(keys: action.shortcut.keyCaps)
            }
        case .prompt(let action):
            HStack(spacing: 10) {
                Image(systemName: action.outputBehavior == .replaceSelection
                      ? "text.cursor" : "sparkles")
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? AQDesign.ColorToken.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.name)
                        .font(.system(size: 13, weight: .medium))
                    Text("\(viewModel.settings.savedPromptPrefix)\(action.alias) · \(action.outputBehavior.displayName)")
                        .font(.system(size: 10))
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
        Task { @MainActor in
            await Task.yield()
            searchFocused = true
        }
    }

    private func move(_ delta: Int) {
        let count = entries.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
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
        case .prompt(let action):
            Task { await viewModel.perform(action: action) }
        }
    }
}

/// Raycast-style key hints: context on the left, actions on the right.
private struct LauncherFooter: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        HStack(spacing: 14) {
            Text(viewModel.footerContext)
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            ForEach(viewModel.footerHints, id: \.label) { hint in
                HStack(spacing: 5) {
                    Text(hint.label)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                    KeyCapGroup(keys: hint.keys)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: AQDesign.footerHeight)
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

extension Notification.Name {
    static let dismissOverlay = Notification.Name("QuickLaunch.dismissOverlay")
    static let presentOverlay = Notification.Name("QuickLaunch.presentOverlay")
    static let screenAwarenessSettingsChanged = Notification.Name("QuickLaunch.screenAwarenessSettingsChanged")
    static let openSettings = Notification.Name("QuickLaunch.openSettings")
    static let hotkeyChanged = Notification.Name("QuickLaunch.hotkeyChanged")
    static let actionHotkeysChanged = Notification.Name("QuickLaunch.actionHotkeysChanged")
    static let launcherItemHotkeysChanged = Notification.Name("QuickLaunch.launcherItemHotkeysChanged")
    static let clipboardHistorySettingsChanged = Notification.Name("QuickLaunch.clipboardHistorySettingsChanged")
    static let providerChanged = Notification.Name("QuickLaunch.providerChanged")
}
