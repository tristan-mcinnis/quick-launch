import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Every item that can carry an alias or a global hotkey, in one table you
/// can read at a glance and edit in place: apps, snippets, quick links,
/// window layouts, and commands. Modelled on Raycast's Extensions table.
struct ItemsSettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var filter: Filter = .all
    @State private var query = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all, apps, folders, snippets, quickLinks, windows, commands
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
            }
        }
    }

    /// One row: an app or a catalog item, with the same editing surface.
    enum Row: Identifiable {
        case application(LaunchableApplication)
        case item(LauncherCatalogItem)

        var id: String {
            switch self {
            case .application(let application): "application:" + application.id
            case .item(let item): item.id
            }
        }

        var name: String {
            switch self {
            case .application(let application): application.name
            case .item(let item): item.title
            }
        }

        var typeLabel: String {
            switch self {
            case .application: "App"
            case .item(let item):
                switch item.kind {
                case .snippet: "Snippet"
                case .quickLink: "Quicklink"
                case .command: item.value.hasPrefix("window.") ? "Window" : "Command"
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
    }

    private var rows: [Row] {
        var all: [Row] = []
        if filter == .all || filter == .apps {
            all += viewModel.applications.map(Row.application)
        }
        if filter == .all || filter == .folders {
            all += viewModel.folderItems.map(Row.item)
        }
        if filter == .all || filter == .snippets {
            all += viewModel.snippets.map(Row.item)
        }
        if filter == .all || filter == .quickLinks {
            all += viewModel.quickLinks.map(Row.item)
        }
        if filter == .all || filter == .windows {
            all += viewModel.systemCommands.filter { $0.value.hasPrefix("window.") }.map(Row.item)
        }
        if filter == .all || filter == .commands {
            all += [Row.item(viewModel.askAIItem(query: ""))]
            all += viewModel.systemCommands.filter { !$0.value.hasPrefix("window.") }.map(Row.item)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        let folded = FuzzyMatcher.fold(trimmed)
        return all.filter { row in
            FuzzyMatcher.score(foldedQuery: folded, foldedCandidate: FuzzyMatcher.fold(row.name)) != nil
                || FuzzyMatcher.score(foldedQuery: folded, foldedCandidate: FuzzyMatcher.fold(alias(for: row))) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
                Spacer()
                Menu {
                    Button("Add Folder…") { addFolder() }
                    Button("Add App…") { addApplication() }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a folder or an app that is not in the list")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                // Flexible: a fixed width made the toolbar wider than the
                // window minimum and cropped the pane at both edges.
                .frame(minWidth: 120, idealWidth: 200, maxWidth: 200)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(AQDesign.ColorToken.keyCapFill)
                )
            }

            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                        Divider()
                    }
                }
            }
            Text("\(rows.count) items. Aliases are words you type to reach an item first. Hotkeys run the item from anywhere.")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(.secondary)
        }
        .padding(AQDesign.Space.window)
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
        HStack(spacing: 12) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Type").frame(width: 84, alignment: .leading)
            Text("Alias").frame(width: 150, alignment: .leading)
            Text("Hotkey").frame(width: 150, alignment: .leading)
        }
        .font(AQDesign.TypeToken.label)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    icon(for: row).frame(width: 18, height: 18)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.typeLabel)
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
                TextField("None", text: aliasBinding(for: row))
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.body)
                    .padding(.horizontal, 6)
                    .frame(width: 150, height: 24)
                    .background(RoundedRectangle(cornerRadius: 5).fill(AQDesign.ColorToken.keyCapFill))
                CompactHotkeyRecorder(hotkey: hotkeyBinding(for: row))
                    .frame(width: 150, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            if let conflict = conflict(for: row) {
                Text(conflict)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.danger)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func icon(for row: Row) -> some View {
        switch row {
        case .application(let application):
            Image(nsImage: AppIconCache.icon(forPath: application.url.path))
                .resizable().scaledToFit()
        case .item(let item):
            Image(systemName: item.systemImage).foregroundStyle(.secondary)
        }
    }

    private func alias(for row: Row) -> String {
        switch row {
        case .application(let application): viewModel.applicationAlias(for: application)
        case .item(let item): viewModel.launcherItemAlias(for: item)
        }
    }

    private func aliasBinding(for row: Row) -> Binding<String> {
        Binding(
            get: { alias(for: row) },
            set: { value in
                switch row {
                case .application(let application): viewModel.setApplicationAlias(value, for: application)
                case .item(let item): viewModel.setLauncherItemAlias(value, for: item)
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
                }
            },
            set: { value in
                switch row {
                case .application(let application): viewModel.setApplicationHotkey(value, for: application)
                case .item(let item): viewModel.setLauncherItemHotkey(value, for: item)
                }
            }
        )
    }

    private func conflict(for row: Row) -> String? {
        switch row {
        case .application(let application): viewModel.applicationConfigurationConflict(for: application)
        case .item(let item): viewModel.launcherItemConfigurationConflict(for: item)
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
        HStack(spacing: 6) {
            if isRecording {
                HotkeyCapture { captured in
                    let rawMods = captured.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
                    guard QuickSettings.isValidHotkey(keyCode: captured.keyCode, modifiers: rawMods) else {
                        validationError = "Add ⌃, ⌥, or ⌘"
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
                .frame(width: 120, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(AQDesign.ColorToken.emphasis, lineWidth: 1)
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
                            .foregroundStyle(validationError == nil ? .secondary : AQDesign.ColorToken.danger)
                    }
                }
                .buttonStyle(.plain)
                .frame(height: 24)
                .help("Click, then press the keys")
                if hotkey != nil {
                    Button {
                        hotkey = nil
                        NotificationCenter.default.post(name: .launcherItemHotkeysChanged, object: nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear hotkey")
                }
            }
        }
    }
}
