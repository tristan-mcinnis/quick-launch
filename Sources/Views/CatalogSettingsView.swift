import SwiftUI

struct CatalogSettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var query = ""
    @State private var selection: String?

    private var items: [LauncherCatalogItem] {
        let all = viewModel.configurableCatalogItems
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            FuzzyMatcher.score(query: trimmed, candidate: $0.title) != nil
                || FuzzyMatcher.score(query: trimmed, candidate: viewModel.launcherItemAlias(for: $0)) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Catalogs").font(.headline)
            Text("Tuna snippets and Quick Links stay in Tuna. Quick Launch reads them live and never copies their values into settings.")
                .font(AQDesign.TypeToken.label).foregroundStyle(.secondary)

            HStack {
                Label("\(viewModel.snippets.count) snippets", systemImage: "text.quote")
                Label("\(viewModel.quickLinks.count) Quick Links", systemImage: "link")
                Spacer()
                Button("Reload Tuna") { viewModel.reloadTunaCatalogs() }
            }.font(AQDesign.TypeToken.label)

            GroupBox("Clipboard History") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Keep text clipboard history", isOn: $viewModel.settings.clipboardHistoryEnabled)
                    Stepper("Keep \(viewModel.settings.clipboardHistoryLimit) items",
                            value: $viewModel.settings.clipboardHistoryLimit, in: 10...200, step: 10)
                    HotkeyRecorderView(
                        keyCode: Binding(
                            get: { viewModel.settings.clipboardHistoryHotkey.keyCode },
                            set: { viewModel.settings.clipboardHistoryHotkey.keyCode = $0 }
                        ),
                        modifiers: Binding(
                            get: { viewModel.settings.clipboardHistoryHotkey.modifiers },
                            set: { viewModel.settings.clipboardHistoryHotkey.modifiers = $0 }
                        ),
                        changeNotification: .clipboardHistorySettingsChanged
                    )
                    if let conflict = viewModel.settings.clipboardHistoryHotkeyConflict()
                        ?? viewModel.clipboardHistoryHotkeyRegistrationError {
                        Text(conflict).font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.danger)
                    }
                    HStack {
                        Text("\(viewModel.clipboardEntries.count) saved text items")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear Clipboard History", role: .destructive) {
                            viewModel.clearClipboardHistory()
                        }
                    }
                }.padding(6)
            }
            .onChange(of: viewModel.settings.clipboardHistoryEnabled) { _, _ in saveClipboardSettings() }
            .onChange(of: viewModel.settings.clipboardHistoryLimit) { _, _ in saveClipboardSettings() }

            TextField("Find a snippet or Quick Link", text: $query).textFieldStyle(.roundedBorder)
            Table(items, selection: $selection) {
                TableColumn("Item") { item in Label(item.title, systemImage: item.systemImage).lineLimit(1) }
                TableColumn("Alias") { item in Text(viewModel.launcherItemAlias(for: item)) }
                TableColumn("Hotkey") { item in Text(hotkeyName(viewModel.launcherItemHotkey(for: item))) }
            }.frame(minHeight: 150)

            if let item = selectedItem {
                TextField("Search alias", text: Binding(
                    get: { viewModel.launcherItemAlias(for: item) },
                    set: { viewModel.setLauncherItemAlias($0, for: item) }
                )).textFieldStyle(.roundedBorder)
                ActionHotkeyRecorderView(
                    hotkey: Binding(
                        get: { viewModel.launcherItemHotkey(for: item) },
                        set: { viewModel.setLauncherItemHotkey($0, for: item) }
                    ),
                    changeNotification: .launcherItemHotkeysChanged
                )
                if let conflict = viewModel.launcherItemConfigurationConflict(for: item) {
                    Text(conflict).font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.danger)
                }
            }
        }.padding(AQDesign.Space.window)
    }

    private var selectedItem: LauncherCatalogItem? {
        guard let selection else { return nil }
        return viewModel.configurableCatalogItems.first { $0.id == selection }
    }
    private func saveClipboardSettings() {
        viewModel.settings.save()
        NotificationCenter.default.post(name: .clipboardHistorySettingsChanged, object: nil)
    }
    private func hotkeyName(_ hotkey: ActionHotkey?) -> String {
        guard let hotkey else { return "Not set" }
        var settings = QuickSettings()
        settings.hotkeyKeyCode = hotkey.keyCode
        settings.hotkeyModifiers = hotkey.modifiers
        return settings.hotkeyDisplayName
    }
}
