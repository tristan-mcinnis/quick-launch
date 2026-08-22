import SwiftUI
import AppKit

/// Settings window: a top tab strip (no system tab view, which overflows
/// into a "»" menu on narrow windows) over one scrollable pane per tab.
/// Modelled on Raycast's settings: wide, flat, everything visible.
struct SettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var tab: SettingsTab

    init(viewModel: QuickViewModel, initialTab: SettingsTab = .general) {
        self.viewModel = viewModel
        _tab = State(initialValue: initialTab)
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, items, models, clipboard, prompts, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "General"
            case .items: "Items"
            case .models: "Models"
            case .clipboard: "Clipboard & Links"
            case .prompts: "Prompts"
            case .about: "About"
            }
        }
        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .items: "square.grid.2x2"
            case .models: "cpu"
            case .clipboard: "clipboard"
            case .prompts: "text.quote"
            case .about: "info.circle"
            }
        }
    }

    static let windowSize = NSSize(width: 860, height: 620)

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
            Group {
                switch tab {
                case .general: GeneralTab(viewModel: viewModel)
                case .items: ItemsSettingsView(viewModel: viewModel)
                case .models: ProviderSettingsView(viewModel: viewModel)
                case .clipboard: ClipboardLinksSettingsView(viewModel: viewModel)
                case .prompts: SavedPromptsTab(viewModel: viewModel)
                case .about: AboutTab(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(Color(NSColor.windowBackgroundColor))
        .preferredColorScheme(viewModel.settings.appearance.swiftUIColorScheme)
        .background {
            // ⌘1…⌘6 switch tabs, like Raycast.
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element.id) { index, item in
                Button("") { tab = item }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                    .hidden()
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 16, weight: .medium))
                        Text(item.title)
                            .font(AQDesign.TypeToken.label)
                    }
                    .frame(minWidth: 92)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 6)
                    .foregroundStyle(tab == item ? AQDesign.ColorToken.accent : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                            .fill(tab == item ? AQDesign.ColorToken.selectionFill : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                    modifiers: $viewModel.settings.hotkeyModifiers,
                    label: "Open Quick Launch"
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

                Toggle("Learn from my choices", isOn: $viewModel.settings.launcherLearningEnabled)
                    .onChange(of: viewModel.settings.launcherLearningEnabled) { _, _ in
                        viewModel.settings.save()
                    }
                HStack {
                    Text("Items you pick for a search rise to the top next time. Stored only on this Mac.")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget learned ranking", role: .destructive) {
                        viewModel.forgetLearnedRanking()
                    }
                }

                Toggle("Double-tap right ⌘ sends the focused window to AI", isOn: $viewModel.settings.screenAwarenessDoubleTap)
                    .onChange(of: viewModel.settings.screenAwarenessDoubleTap) { _, _ in
                        viewModel.settings.save()
                        NotificationCenter.default.post(name: .screenAwarenessSettingsChanged, object: nil)
                    }
                Toggle("Search text inside screenshots (on-device OCR)", isOn: $viewModel.settings.screenshotTextSearch)
                    .onChange(of: viewModel.settings.screenshotTextSearch) { _, _ in viewModel.settings.save() }

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
