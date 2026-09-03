import SwiftUI
import AppKit

/// Settings window: a top tab strip (no system tab view, which overflows
/// into a "»" menu on narrow windows) over one scrollable pane per tab.
/// Modelled on Raycast's settings: wide, flat, everything visible.
struct SettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var tab: SettingsTab
    @State private var settingsQuery = ""

    init(viewModel: QuickViewModel, initialTab: SettingsTab = .general) {
        self.viewModel = viewModel
        _tab = State(initialValue: initialTab)
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, items, models, clipboard, screenHistory, prompts, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "General"
            case .items: "Items"
            case .models: "Models"
            case .clipboard: "Clipboard & Capture"
            case .screenHistory: "Screen History"
            case .prompts: "AI Commands"
            case .about: "About"
            }
        }
        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .items: "square.grid.2x2"
            case .models: "cpu"
            case .clipboard: "clipboard"
            case .screenHistory: "clock.arrow.circlepath"
            case .prompts: "text.quote"
            case .about: "info.circle"
            }
        }
    }

    static let windowSize = NSSize(width: 1_040, height: 680)
    /// Wide enough for the widest tab's fixed chrome (the Items filter
    /// strip). A smaller window makes the HStack overflow and crop the
    /// sidebar and content at both edges.
    static let minimumWindowSize = NSSize(width: 980, height: 600)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch tab {
                case .general: GeneralTab(viewModel: viewModel)
                case .items: ItemsSettingsView(viewModel: viewModel)
                case .models: ProviderSettingsView(viewModel: viewModel)
                case .clipboard: ClipboardLinksSettingsView(viewModel: viewModel)
                case .screenHistory: ScreenHistorySettingsView(viewModel: viewModel)
                case .prompts: SavedPromptsTab(viewModel: viewModel)
                case .about: AboutTab(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            minWidth: Self.minimumWindowSize.width,
            idealWidth: Self.windowSize.width,
            minHeight: Self.minimumWindowSize.height,
            idealHeight: Self.windowSize.height
        )
        .background(AQDesign.ColorToken.windowSurface)
        .preferredColorScheme(viewModel.settings.appearance.swiftUIColorScheme)
        .background {
            // ⌘1…⌘7 switch tabs, like Raycast.
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element.id) { index, item in
                Button("") { tab = item }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command])
                    .hidden()
            }
        }
    }

    private var filteredTabs: [SettingsTab] {
        let query = settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search settings…", text: $settingsQuery)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                    .fill(AQDesign.ColorToken.surfaceFill)
            )

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(filteredTabs) { item in
                Button {
                    tab = item
                } label: {
                            HStack(spacing: 10) {
                        Image(systemName: item.systemImage)
                                    .font(AQDesign.TypeToken.icon)
                                    .frame(width: 18)
                        Text(item.title)
                            .font(AQDesign.TypeToken.label)
                                Spacer()
                                if let index = SettingsTab.allCases.firstIndex(of: item) {
                                    Text("⌘\(index + 1)")
                                        .font(AQDesign.TypeToken.caption)
                                        .foregroundStyle(.tertiary)
                                }
                    }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .foregroundStyle(tab == item ? AQDesign.ColorToken.emphasis : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                            .fill(tab == item ? AQDesign.ColorToken.selectionFill : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? [.isSelected] : [])
            }
                }
            }

            Spacer(minLength: 0)
            Text("Quick Launch")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 220)
        .background(AQDesign.ColorToken.sidebarSurface)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("General").font(AQDesign.TypeToken.heading)

                HotkeyRecorderView(
                    keyCode: viewModel.settingsBinding(\.hotkeyKeyCode),
                    modifiers: viewModel.settingsBinding(\.hotkeyModifiers),
                    label: "Open Quick Launch"
                )
                if let error = viewModel.hotkeyRegistrationError {
                    Text(error)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.danger)
                }

                Divider()

                Toggle("Copy result to clipboard automatically", isOn: viewModel.settingsBinding(\.autoCopy))

                Toggle(
                    "Launch at login",
                    isOn: viewModel.settingsBinding(\.launchAtLogin) { _ in viewModel.applyLaunchAtLogin() }
                )

                Toggle("Show menu bar icon", isOn: viewModel.settingsBinding(\.showMenuBar))
                    .disabled(!viewModel.screenHistory.menuBarCanBeHidden)
                if !viewModel.screenHistory.menuBarCanBeHidden {
                    Text("The menu bar status stays visible while Screen History capture is on.")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(.secondary)
                }

                Toggle("Learn from my choices", isOn: viewModel.settingsBinding(\.launcherLearningEnabled))
                HStack {
                    Text("Items you pick for a search rise to the top next time. Stored only on this Mac.")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Forget learned ranking", role: .destructive) {
                        viewModel.forgetLearnedRanking()
                    }
                }

                HStack {
                    Text("Open Translator")
                    Spacer()
                    ActionHotkeyRecorderView(
                        hotkey: viewModel.settingsBinding(
                            get: { $0.translatorHotkey as ActionHotkey? },
                            set: { settings, value in
                                settings.translatorHotkey = value
                                    ?? ActionHotkey(keyCode: 17, modifiers: 1_048_576 | 131_072)
                            }
                        ),
                        label: "",
                        changeNotification: .translatorSettingsChanged
                    )
                    .frame(width: 220)
                }
                if let error = viewModel.settings.translatorHotkeyConflict() ?? viewModel.translatorHotkeyRegistrationError {
                    Text(error).font(AQDesign.TypeToken.caption).foregroundStyle(AQDesign.ColorToken.danger)
                }

                HStack {
                    Text("Type to Click")
                    Spacer()
                    ActionHotkeyRecorderView(
                        hotkey: viewModel.settingsBinding(
                            get: { $0.typeToClickHotkeyEnabled ? $0.typeToClickHotkey : nil },
                            set: { settings, value in
                                if let value {
                                    settings.typeToClickHotkey = value
                                    settings.typeToClickHotkeyEnabled = true
                                } else {
                                    settings.typeToClickHotkeyEnabled = false
                                }
                            }
                        ),
                        label: "",
                        changeNotification: .typeToClickSettingsChanged
                    )
                    .frame(width: 220)
                }
                HStack {
                    Text("After Return")
                    Spacer()
                    Picker("", selection: viewModel.settingsBinding(\.typeToClickContinuation) { _ in
                        NotificationCenter.default.post(name: .typeToClickSettingsChanged, object: nil)
                    }) {
                        ForEach(TypeToClickContinuation.allCases, id: \.self) { continuation in
                            Text(continuation.displayName).tag(continuation)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                if let error = viewModel.settings.typeToClickHotkeyConflict() ?? viewModel.typeToClickHotkeyRegistrationError {
                    Text(error).font(AQDesign.TypeToken.caption).foregroundStyle(AQDesign.ColorToken.danger)
                } else if viewModel.settings.typeToClickHotkeyEnabled {
                    Text(viewModel.settings.typeToClickContinuation == .continuous
                        ? "Press \(viewModel.settings.typeToClickHotkey.displayName) to label clickable targets by name. Type to narrow them, then press Return. It pulses the choice, prioritizes an opened menu, and stays open for the next step; Esc or the shortcut closes it."
                        : "Press \(viewModel.settings.typeToClickHotkey.displayName) to label clickable targets by name. Type to narrow them, then press Return. It acts once and closes; invoke Type to Click again for another action."
                    )
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No direct hotkey. Type to Click remains available from Quick Launch.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Double-tap right ⌘ sends the focused window to AI",
                    isOn: viewModel.settingsBinding(\.screenAwarenessDoubleTap) { _ in
                        NotificationCenter.default.post(name: .screenAwarenessSettingsChanged, object: nil)
                    }
                )
                Toggle("Search text inside screenshots (on-device OCR)", isOn: viewModel.settingsBinding(\.screenshotTextSearch))

                Toggle(
                    "Keep quick-action history",
                    isOn: viewModel.settingsBinding(\.historyEnabled) { enabled in
                        if enabled {
                            viewModel.loadHistory()
                        } else {
                            viewModel.history = []
                        }
                    }
                )

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
                    Picker("", selection: viewModel.settingsBinding(\.newConversationAfterMinutes)) {
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                HStack {
                    Text("Keep my place after closing")
                    Spacer()
                    Picker("", selection: viewModel.settingsBinding(\.reopenRetentionSeconds)) {
                        Text("Do not keep").tag(0)
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                Toggle(
                    "Show welcome screen on next launch",
                    isOn: viewModel.settingsBinding(
                        get: { !$0.hasSeenWelcome },
                        set: { settings, show in settings.hasSeenWelcome = !show }
                    )
                )

                Divider()

                HStack {
                    Text("Appearance")
                    Spacer()
                    Picker("", selection: viewModel.settingsBinding(\.appearance)) {
                        ForEach(AppearancePreference.allCases, id: \.self) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
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
                Text("About").font(AQDesign.TypeToken.heading)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick Launch")
                        .font(AQDesign.TypeToken.title)
                    Text("Version \(viewModel.currentVersion)")
                        .font(AQDesign.TypeToken.detail)
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
                .font(AQDesign.TypeToken.detail)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch viewModel.updateState {
        case .checking:
            Text("Checking…").font(AQDesign.TypeToken.detail).foregroundStyle(.secondary)
        case .upToDate:
            Text("Up to date").font(AQDesign.TypeToken.detail).foregroundStyle(AQDesign.ColorToken.success)
        case .updateAvailable(let v):
            Button("Update to \(v)") { [weak viewModel] in viewModel?.installUpdate() }
                .font(AQDesign.TypeToken.detail)
                .foregroundStyle(AQDesign.ColorToken.emphasis)
                .buttonStyle(.plain)
        case .installing(let v):
            Text("Installing \(v)…").font(AQDesign.TypeToken.detail).foregroundStyle(.secondary)
        case .installed(let v):
            Text("Installed \(v)").font(AQDesign.TypeToken.detail).foregroundStyle(AQDesign.ColorToken.success)
        case .error(let msg):
            Text(msg).font(AQDesign.TypeToken.detail).foregroundStyle(AQDesign.ColorToken.danger)
        case .idle:
            EmptyView()
        }
    }
}
