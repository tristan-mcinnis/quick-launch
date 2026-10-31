import SwiftUI
import Combine
import HouseDesign

/// Raycast-style actions for one row: a list with the shortcut on the right,
/// a search field at the bottom, and small forms for edit, alias, and hotkey.
struct ItemActionPane: View {
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
        }
        .onChange(of: viewModel.activeItemActionForm) { _, form in
            syncEditor()
            if form == nil { focusSearch() } else { focusForm() }
        }
        .onChange(of: viewModel.actionQuery) { _, _ in
            selectedIndex = 0
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
        case .application: return "Application"
        }
    }

    private var formTitle: String {
        switch viewModel.activeItemActionForm {
        case .edit: isCreatingItem ? "New" : "Edit"
        case .alias: "Alias"
        case .hotkey: "Hotkey"
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
                "\(isSelected ? "Selected, " : "")\(index + 1) of \(actions.count)"
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
    }

    private func runSelected() {
        let current = actions
        guard current.indices.contains(selectedIndex) else { return }
        Task { await viewModel.perform(current[selectedIndex], on: result) }
    }
}
