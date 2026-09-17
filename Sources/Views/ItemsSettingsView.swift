import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Every item that can carry an alias or a global hotkey, in one table you
/// can read at a glance and edit in place: apps, snippets, quick links,
/// window layouts, and commands. The table sits in a raised card; rows are
/// separated by house dividers and lit by the house hover fill.
struct ItemsSettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var filter: Filter
    @State private var query = ""
    @State private var hoveredRow: String?
    /// A custom folder or app waiting for the remove confirmation.
    @State private var pendingRemoval: Row?

    /// `initialFilter` lets a render proof open straight on Hidden; the app
    /// always starts on All.
    init(viewModel: QuickViewModel, initialFilter: Filter = .all) {
        self.viewModel = viewModel
        _filter = State(initialValue: initialFilter)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, apps, folders, snippets, quickLinks, windows, commands, hidden
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .apps: "Apps"
            case .folders: "Folders"
            case .snippets: "Snippets"
            case .quickLinks: "Quicklinks"
            case .windows: "Windows"
            case .commands: "Commands"
            case .hidden: "Hidden"
            }
        }
    }

    /// One row: an app or a catalog item, with the same editing surface.
    enum Row: Identifiable {
        case application(LaunchableApplication)
        case item(LauncherCatalogItem)
        /// A hidden record from settings. Its item may be missing or
        /// uninstalled, so the label comes from what was stored at hide time.
        case hidden(LauncherItemConfiguration)

        var id: String {
            switch self {
            case .application(let application): "application:" + application.id
            case .item(let item): item.id
            case .hidden(let configuration): "hidden:" + configuration.id
            }
        }

        var name: String {
            switch self {
            case .application(let application): application.name
            case .item(let item): item.title
            case .hidden(let configuration):
                configuration.hiddenTitle ?? LauncherItemHiding.placeholderTitle(for: configuration.kind)
            }
        }

        var typeLabel: String {
            switch self {
            case .application: "App"
            case .item(let item): Row.typeLabel(for: item.kind, value: item.value)
            case .hidden(let configuration): Row.typeLabel(for: configuration.kind, value: nil)
            }
        }

        /// One label table for live and hidden rows, so a kind reads the
        /// same in both lists.
        static func typeLabel(for kind: LauncherItemKind, value: String?) -> String {
            switch kind {
            case .snippet: "Snippet"
            case .quickLink: "Quicklink"
            case .command: (value?.hasPrefix("window.") ?? false) ? "Window" : "Command"
            case .clipboard: "Clipboard"
            case .emoji: "Emoji"
            case .screenshot: "Screenshot"
            case .conversation: "Chat"
            case .askAI: "AI"
            case .folder: "Folder"
            case .answer: "Answer"
            case .screenHistory: "Screen History"
            case .color: "Color"
            case .application: "App"
            }
        }
    }

    private var rows: [Row] {
        var all: [Row] = []
        if filter == .hidden {
            all += viewModel.hiddenLauncherItems.map(Row.hidden)
        } else {
            if filter == .all || filter == .apps {
                all += viewModel.applications
                    .filter { !viewModel.isApplicationHidden($0) }
                    .map(Row.application)
            }
            if filter == .all || filter == .folders {
                all += viewModel.folderItems
                    .filter { !viewModel.isLauncherItemHidden($0) }
                    .map(Row.item)
            }
            if filter == .all || filter == .snippets {
                all += viewModel.snippets
                    .filter { !viewModel.isLauncherItemHidden($0) }
                    .map(Row.item)
            }
            if filter == .all || filter == .quickLinks {
                all += viewModel.quickLinks
                    .filter { !viewModel.isLauncherItemHidden($0) }
                    .map(Row.item)
            }
            if filter == .all || filter == .windows {
                all += viewModel.systemCommands
                    .filter { $0.value.hasPrefix("window.") && !viewModel.isLauncherItemHidden($0) }
                    .map(Row.item)
            }
            if filter == .all || filter == .commands {
                let askAI = viewModel.askAIItem(query: "")
                if !viewModel.isLauncherItemHidden(askAI) { all += [Row.item(askAI)] }
                all += viewModel.systemCommands
                    .filter { !$0.value.hasPrefix("window.") && !viewModel.isLauncherItemHidden($0) }
                    .map(Row.item)
            }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        let folded = FuzzyMatcher.fold(trimmed)
        return all.filter { row in
            FuzzyMatcher.score(foldedQuery: folded, foldedCandidate: FuzzyMatcher.fold(row.name)) != nil
                || FuzzyMatcher.score(foldedQuery: folded, foldedCandidate: FuzzyMatcher.fold(alias(for: row))) != nil
                || row.typeLabel.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            toolbar

            VStack(alignment: .leading, spacing: 0) {
                header
                HouseDivider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { HouseDivider() }
                            rowView(row)
                        }
                    }
                }
            }
            .raisedCard()
            .settingsAnchor("items.list")

            Text(footerText)
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
        }
        .padding(.horizontal, SettingsMetrics.paneInset)
        .padding(.bottom, House.Spacing.md)
        .confirmationDialog(
            pendingRemoval.map { removeHelp(for: $0) } ?? "Remove",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { row in
            Button(removeHelp(for: row), role: .destructive) {
                remove(row)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { row in
            Text("\(row.name) also loses its alias, hotkey, and pin.")
        }
    }

    private var footerText: String {
        if filter == .hidden {
            if viewModel.hiddenLauncherItems.isEmpty {
                return "Nothing is hidden. Use \u{201C}Hide from Quick Launch\u{201D} in a result\u{2019}s actions."
            }
            return "\(rows.count) hidden \(rows.count == 1 ? "item" : "items"). Restoring puts the item back without deleting anything."
        }
        return "\(rows.count) items. Aliases are words you type to reach an item first. Hotkeys run the item from anywhere."
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            // The whole filter strip gets its own row: eight segments with
            // their labels need the pane width, and sharing the row with Add
            // and Search truncated every title.
            InkSegmentedControl(
                selection: $filter,
                options: Filter.allCases.map { InkSegment(value: $0, title: $0.title) }
            )
            .frame(maxWidth: .infinity)
            HStack(spacing: House.Spacing.sm) {
                if filter == .hidden, !viewModel.hiddenLauncherItems.isEmpty {
                    Button {
                        viewModel.restoreAllHiddenItems()
                    } label: {
                        Label("Restore All", systemImage: "arrow.uturn.backward")
                            .font(AQDesign.TypeToken.label)
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Bring every hidden item back into Quick Launch")
                }
                Spacer()
                Menu {
                    Button("Add Folder…") { addFolder() }
                    Button("Add App…") { addApplication() }
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a folder or an app that is not in the list")
                searchField
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: AQDesign.Space.standard) {
            Image(systemName: "magnifyingglass")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .accessibilityLabel("Search")
            }
        }
        .padding(.horizontal, AQDesign.Space.standard)
        // Flexible: a fixed width made the toolbar wider than the
        // window minimum and cropped the pane at both edges.
        .frame(minWidth: 120, idealWidth: 200, maxWidth: 200)
        .frame(height: House.Control.small)
        .background(
            RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                .fill(AQDesign.ColorToken.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                .strokeBorder(AQDesign.ColorToken.tileStroke, lineWidth: AQDesign.hairline)
        )
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose folders to open from Quick Launch. Give each an alias or hotkey below."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { viewModel.addCustomFolder(url) }
        filter = .folders
    }

    private func addApplication() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add App"
        panel.message = "Choose apps that live outside the Applications folders."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { viewModel.addCustomApplication(url) }
        filter = .apps
    }

    private var header: some View {
        HStack(spacing: House.Spacing.sm) {
            SectionLabel(text: "Name").frame(maxWidth: .infinity, alignment: .leading)
            SectionLabel(text: "Type").frame(width: 84, alignment: .leading)
            if filter != .hidden {
                SectionLabel(text: "Alias").frame(width: 150, alignment: .leading)
                SectionLabel(text: "Hotkey").frame(width: 150, alignment: .leading)
            }
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(minHeight: House.Control.chip)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if case .hidden(let configuration) = row {
                hiddenRowView(row, configuration: configuration)
            } else {
                editingRowView(row)
            }
            if let conflict = conflict(for: row) {
                Text(conflict)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.danger)
                    .padding(.horizontal, House.Spacing.sm)
                    .padding(.bottom, AQDesign.Space.compact)
            }
        }
        .background(RowHighlight(isSelected: false, isHovering: hoveredRow == row.id))
        .onHover { inside in
            if inside {
                hoveredRow = row.id
            } else if hoveredRow == row.id {
                hoveredRow = nil
            }
        }
    }

    /// A hidden record: name, kind, availability, and Restore. Its item may
    /// be gone, so there is no alias or hotkey control to show.
    private func hiddenRowView(_ row: Row, configuration: LauncherItemConfiguration) -> some View {
        let isAvailable = viewModel.hiddenLauncherItemExists(configuration)
        return HStack(spacing: House.Spacing.sm) {
            HStack(spacing: AQDesign.Space.standard) {
                IconTile(fillsTile: false) { icon(for: row) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !isAvailable {
                        Text("Source unavailable")
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.typeLabel)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .frame(width: 84, alignment: .leading)
            Button {
                viewModel.restoreHiddenItem(configuration)
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
            }
            .buttonStyle(.plain)
            .help("Bring \(row.name) back into Quick Launch")
            .accessibilityLabel("Restore \(row.name)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(minHeight: House.Control.railRow)
    }

    private func editingRowView(_ row: Row) -> some View {
        HStack(spacing: House.Spacing.sm) {
            HStack(spacing: AQDesign.Space.standard) {
                IconTile(fillsTile: isApplication(row)) { icon(for: row) }
                Text(row.name)
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.typeLabel)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .frame(width: 84, alignment: .leading)
            TextField("None", text: aliasBinding(for: row))
                .textFieldStyle(.plain)
                .font(AQDesign.TypeToken.body)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .padding(.horizontal, AQDesign.Space.standard)
                .frame(width: 150, height: AQDesign.tileSize)
                .background(
                    RoundedRectangle(cornerRadius: AQDesign.fieldCornerRadius, style: .continuous)
                        .fill(AQDesign.ColorToken.surfaceFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AQDesign.fieldCornerRadius, style: .continuous)
                        .strokeBorder(AQDesign.ColorToken.tileStroke, lineWidth: AQDesign.hairline)
                )
            CompactHotkeyRecorder(hotkey: hotkeyBinding(for: row))
                .frame(width: 150, alignment: .leading)
            if isCustom(row) {
                Button {
                    pendingRemoval = row
                } label: {
                    Image(systemName: "trash")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                }
                .buttonStyle(.plain)
                .help(removeHelp(for: row))
                .accessibilityLabel(removeHelp(for: row))
            }
        }
        .padding(.horizontal, House.Spacing.sm)
        .frame(minHeight: House.Control.railRow)
    }

    private func isApplication(_ row: Row) -> Bool {
        if case .application = row { return true }
        return false
    }

    /// Only a folder or app the user added can be removed here; the built-in
    /// folders and the scanned Applications folders are not this list's to edit.
    private func isCustom(_ row: Row) -> Bool {
        switch row {
        case .application(let application):
            return viewModel.settings.customApplicationPaths.contains(
                application.url.standardizedFileURL.path
            )
        case .item(let item):
            return item.kind == .folder
                && !FolderLocationService.builtIn.contains { $0.id == item.itemID }
        case .hidden:
            return false
        }
    }

    private func removeHelp(for row: Row) -> String {
        isApplication(row) ? "Remove this app" : "Remove this folder"
    }

    private func remove(_ row: Row) {
        switch row {
        case .application(let application):
            viewModel.removeCustomApplication(application)
        case .item(let item):
            viewModel.removeCustomFolder(item)
        case .hidden:
            break
        }
    }

    @ViewBuilder
    private func icon(for row: Row) -> some View {
        switch row {
        case .application(let application):
            Image(nsImage: AppIconCache.icon(forPath: application.url.path))
                .resizable().scaledToFit()
        case .item(let item):
            Image(systemName: item.systemImage)
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
        case .hidden(let configuration):
            Image(systemName: LauncherCatalogItem(
                kind: configuration.kind,
                itemID: configuration.itemID,
                title: "",
                detail: "",
                value: ""
            ).systemImage)
            .font(AQDesign.TypeToken.caption)
            .foregroundStyle(AQDesign.ColorToken.textSecondary)
        }
    }

    private func alias(for row: Row) -> String {
        switch row {
        case .application(let application): viewModel.applicationAlias(for: application)
        case .item(let item): viewModel.launcherItemAlias(for: item)
        case .hidden: ""
        }
    }

    private func aliasBinding(for row: Row) -> Binding<String> {
        Binding(
            get: { alias(for: row) },
            set: { value in
                switch row {
                case .application(let application): viewModel.setApplicationAlias(value, for: application)
                case .item(let item): viewModel.setLauncherItemAlias(value, for: item)
                case .hidden: break
                }
            }
        )
    }

    private func hotkeyBinding(for row: Row) -> Binding<ActionHotkey?> {
        Binding(
            get: {
                switch row {
                case .application(let application): viewModel.applicationHotkey(for: application)
                case .item(let item): viewModel.launcherItemHotkey(for: item)
                case .hidden: nil
                }
            },
            set: { value in
                switch row {
                case .application(let application): viewModel.setApplicationHotkey(value, for: application)
                case .item(let item): viewModel.setLauncherItemHotkey(value, for: item)
                case .hidden: break
                }
            }
        )
    }

    private func conflict(for row: Row) -> String? {
        switch row {
        case .application(let application): viewModel.applicationConfigurationConflict(for: application)
        case .item(let item): viewModel.launcherItemConfigurationConflict(for: item)
        case .hidden: nil
        }
    }
}

/// A one-line hotkey control: key caps when set, "Record" when not. Click to
/// capture the next combination; Escape cancels; the × clears.
struct CompactHotkeyRecorder: View {
    @Binding var hotkey: ActionHotkey?
    @State private var isRecording = false
    @State private var validationError: String?

    var body: some View {
        HStack(spacing: AQDesign.Space.standard) {
            if isRecording {
                HotkeyCapture { captured in
                    let rawMods = captured.modifierFlags.overlayRelevant.rawValue
                    guard QuickSettings.isValidHotkey(keyCode: captured.keyCode, modifiers: rawMods) else {
                        validationError = "Add \u{2303}, \u{2325}, or \u{2318}"
                        isRecording = false
                        return
                    }
                    hotkey = ActionHotkey(keyCode: captured.keyCode, modifiers: rawMods)
                    validationError = nil
                    isRecording = false
                    NotificationCenter.default.post(name: .launcherItemHotkeysChanged, object: nil)
                } onCancel: {
                    isRecording = false
                }
                .frame(width: 120, height: AQDesign.tileSize)
                .overlay(
                    RoundedRectangle(cornerRadius: AQDesign.keyCapCornerRadius, style: .continuous)
                        .strokeBorder(
                            AQDesign.ColorToken.panelStrokeStrong,
                            lineWidth: AQDesign.hairline
                        )
                )
            } else {
                Button {
                    validationError = nil
                    isRecording = true
                } label: {
                    if let hotkey {
                        KeyCapGroup(keys: hotkey.keyCaps)
                    } else {
                        Text(validationError ?? "Record")
                            .font(AQDesign.TypeToken.label)
                            .foregroundStyle(
                                validationError == nil
                                    ? AQDesign.ColorToken.textSecondary
                                    : AQDesign.ColorToken.danger
                            )
                    }
                }
                .buttonStyle(.plain)
                .frame(height: AQDesign.tileSize)
                .help("Click, then press the keys")
                if hotkey != nil {
                    Button {
                        hotkey = nil
                        NotificationCenter.default.post(name: .launcherItemHotkeysChanged, object: nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear hotkey")
                }
            }
        }
    }
}
