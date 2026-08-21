import SwiftUI
import AppKit

/// Tabbed, scrollable Settings window. Each tab is its own focused pane so
/// the view fits on a laptop display without clipping.
struct SettingsView: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        TabView {
            ProviderSettingsView(viewModel: viewModel)
                .tabItem { Label("Models", systemImage: "cpu") }

            GeneralTab(viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gear") }

            ApplicationSettingsView(viewModel: viewModel)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }

            CatalogSettingsView(viewModel: viewModel)
                .tabItem { Label("Catalogs", systemImage: "tray.full") }

            SavedPromptsTab(viewModel: viewModel)
                .tabItem { Label("Prompts", systemImage: "text.quote") }

            MCPTab(viewModel: viewModel)
                .tabItem { Label("MCP", systemImage: "puzzlepiece.extension") }

            AboutTab(viewModel: viewModel)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 600, height: 560)
        .background(Color(NSColor.windowBackgroundColor))
        .preferredColorScheme(viewModel.settings.appearance.swiftUIColorScheme)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("General").font(.headline)

                HotkeyRecorderView(
                    keyCode: $viewModel.settings.hotkeyKeyCode,
                    modifiers: $viewModel.settings.hotkeyModifiers
                )
                .onChange(of: viewModel.settings.hotkeyKeyCode) { _, _ in viewModel.settings.save() }
                .onChange(of: viewModel.settings.hotkeyModifiers) { _, _ in viewModel.settings.save() }
                if let error = viewModel.hotkeyRegistrationError {
                    Text(error)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.danger)
                }

                Divider()

                Toggle("Copy result to clipboard automatically", isOn: $viewModel.settings.autoCopy)
                    .onChange(of: viewModel.settings.autoCopy) { _, _ in viewModel.settings.save() }

                Toggle("Launch at login", isOn: $viewModel.settings.launchAtLogin)
                    .onChange(of: viewModel.settings.launchAtLogin) { [weak viewModel] _, _ in
                        viewModel?.settings.save()
                        viewModel?.applyLaunchAtLogin()
                    }

                Toggle("Show menu bar icon", isOn: $viewModel.settings.showMenuBar)
                    .onChange(of: viewModel.settings.showMenuBar) { _, _ in viewModel.settings.save() }

                Toggle("Keep quick-action history", isOn: $viewModel.settings.historyEnabled)
                    .onChange(of: viewModel.settings.historyEnabled) { _, enabled in
                        viewModel.settings.save()
                        if enabled {
                            viewModel.loadHistory()
                        } else {
                            viewModel.history = []
                        }
                    }

                HStack {
                    Text("Saved history")
                    Spacer()
                    Button("Clear history", role: .destructive) {
                        viewModel.clearHistory()
                    }
                }

                HStack {
                    Text("Start a new thread after")
                    Spacer()
                    Picker("", selection: $viewModel.settings.newConversationAfterMinutes) {
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: viewModel.settings.newConversationAfterMinutes) { _, _ in
                        viewModel.settings.save()
                    }
                }

                HStack {
                    Text("Keep the last result after closing")
                    Spacer()
                    Picker("", selection: $viewModel.settings.reopenRetentionSeconds) {
                        Text("Do not keep").tag(0)
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: viewModel.settings.reopenRetentionSeconds) { _, _ in
                        viewModel.settings.save()
                    }
                }

                Toggle("Show welcome screen on next launch", isOn: Binding(
                    get: { !viewModel.settings.hasSeenWelcome },
                    set: { newValue in
                        viewModel.settings.hasSeenWelcome = !newValue
                        viewModel.settings.save()
                    }
                ))

                Divider()

                HStack {
                    Text("Appearance")
                    Spacer()
                    Picker("", selection: $viewModel.settings.appearance) {
                        ForEach(AppearancePreference.allCases, id: \.self) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                    .onChange(of: viewModel.settings.appearance) { _, _ in viewModel.settings.save() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Prompts

private struct SavedPromptsTab: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SavedPromptsEditor(viewModel: viewModel)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - MCP

private struct MCPTab: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                MCPServersEditor(viewModel: viewModel)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("About").font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick Launch")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Version \(viewModel.currentVersion)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    updateStatusView
                    Spacer()
                    Button("Check for update") {
                        Task { await viewModel.checkForUpdateManual() }
                    }
                    .disabled(viewModel.updateState == .checking)
                }

                Divider()

                Link(
                    "Source on GitHub",
                    destination: URL(string: "https://github.com/tristan-mcinnis/quick-launch")!
                )
                .font(.system(size: 12))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch viewModel.updateState {
        case .checking:
            Text("Checking…").font(.system(size: 12)).foregroundStyle(.secondary)
        case .upToDate:
            Text("Up to date").font(.system(size: 12)).foregroundStyle(AQDesign.ColorToken.success)
        case .updateAvailable(let v):
            Button("Update to \(v)") { [weak viewModel] in viewModel?.installUpdate() }
                .font(.system(size: 12))
                .foregroundStyle(AQDesign.ColorToken.accent)
                .buttonStyle(.plain)
        case .installing(let v):
            Text("Installing \(v)…").font(.system(size: 12)).foregroundStyle(.secondary)
        case .installed(let v):
            Text("Installed \(v)").font(.system(size: 12)).foregroundStyle(AQDesign.ColorToken.success)
        case .error(let msg):
            Text(msg).font(.system(size: 12)).foregroundStyle(AQDesign.ColorToken.danger)
        case .idle:
            EmptyView()
        }
    }
}
