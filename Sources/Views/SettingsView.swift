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
            case .clipboard: "Clipboard & Links"
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
    static let minimumWindowSize = NSSize(width: 900, height: 560)

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
        .background(Color(NSColor.windowBackgroundColor))
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
                                    .font(.system(size: 14, weight: .medium))
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
                }
            }

            Spacer(minLength: 0)
            Text("Quick Launch")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 220)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.55))
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
                    .disabled(!viewModel.screenHistoryMenuBarCanBeHidden)
                if !viewModel.screenHistoryMenuBarCanBeHidden {
                    Text("The menu bar status stays visible while Screen History capture is on.")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(.secondary)
                }

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

                HStack {
                    Text("Open Translator")
                    Spacer()
                    ActionHotkeyRecorderView(
                        hotkey: Binding(
                            get: { viewModel.settings.translatorHotkey },
                            set: { value in
                                viewModel.settings.translatorHotkey = value ?? ActionHotkey(keyCode: 17, modifiers: 1_048_576 | 131_072)
                                viewModel.settings.save()
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

// MARK: - Screen History

private struct ScreenHistorySettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @ScaledMetric(relativeTo: .body) private var exclusionEditorMinHeight: CGFloat = 110

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Screen History").font(.headline)
                Text("Screen History stays on this Mac. Only moments you save to Vault are copied out.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("Capture is locked until the privacy review and seven-day test pass.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Search existing Coast history", isOn: $viewModel.settings.searchLegacyCoastHistory)
                    .onChange(of: viewModel.settings.searchLegacyCoastHistory) { _, _ in
                        viewModel.settings.save()
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Import from Coast")
                        .font(.body.weight(.semibold))
                    Text("Review the counts before importing. Quick Launch copies only allowed text and verified media. Coast stays unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Freeze Coast source") {
                            Task { await viewModel.freezeCoastSourceForImport() }
                        }
                        .disabled(
                            viewModel.screenHistoryCoastFreezeIsRunning
                                || viewModel.screenHistoryCoastImportIsRunning
                        )
                        Button("Preview Coast import") {
                            Task { await viewModel.previewCoastHistoryImport() }
                        }
                        .disabled(
                            viewModel.screenHistoryCoastImportIsRunning
                                || viewModel.screenHistoryCoastImportState == .unavailable
                        )
                        Button("Import reviewed Coast history") {
                            Task { await viewModel.importCoastHistory() }
                        }
                        .disabled(
                            viewModel.screenHistoryCoastImportIsRunning
                                || !viewModel.screenHistoryCoastImportCanImport
                        )
                        if viewModel.screenHistoryCoastImportIsRunning {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Coast preview or import in progress")
                        }
                        Spacer()
                    }
                    if let message = viewModel.screenHistoryCoastFreezeMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Coast freeze status")
                    }
                    if let message = viewModel.screenHistoryCoastImportMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Coast import status")
                    }
                    HStack {
                        Button("Review imported moments") {
                            Task { await viewModel.openScreenHistoryRetirementReview() }
                        }
                        .disabled(
                            viewModel.screenHistoryRetirementReviewSnapshot?.moments.isEmpty != false
                        )
                        Spacer()
                    }
                    if let message = viewModel.screenHistoryRetirementReviewMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Coast review status")
                    }
                }

                Divider()

                Toggle("Enable owned screen capture", isOn: $viewModel.settings.screenHistoryCaptureEnabled)
                    .onChange(of: viewModel.settings.screenHistoryCaptureEnabled) { _, enabled in
                        if !enabled { viewModel.settings.screenHistoryCaptureConfirmed = false }
                        viewModel.settings.save()
                        Task { await viewModel.applyScreenHistoryCaptureSettings() }
                    }
                    .disabled(!ScreenHistoryReleasePolicy.allowsOwnedCapture)

                Text("Browser capture remains blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline) {
                    Text("Status")
                    Spacer()
                    Label(captureStatus, systemImage: captureStatusIcon)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("FileVault")
                    Spacer()
                    Label(fileVaultStatus, systemImage: fileVaultStatusIcon)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if let blocker = viewModel.screenHistoryCaptureStartBlocker {
                    Label(blocker, systemImage: "lock.shield")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.screenHistoryCaptureStatus?.lastSkipReason == .screenRecordingNotAuthorized {
                    Button("Allow Screen Recording") {
                        Task { await viewModel.requestScreenHistoryScreenRecordingAuthorization() }
                    }
                }

                Toggle(
                    "I accept that other software running as my Mac user could read stored OCR",
                    isOn: $viewModel.settings.screenHistorySameUserAccessRiskAccepted
                )
                .onChange(of: viewModel.settings.screenHistorySameUserAccessRiskAccepted) { _, accepted in
                    if !accepted {
                        viewModel.settings.screenHistoryCaptureConfirmed = false
                    }
                    viewModel.settings.save()
                    Task { await viewModel.applyScreenHistoryCaptureSettings() }
                }
                Text("Screen History files are private to your macOS account, but they are not app-encrypted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let message = viewModel.screenHistorySoakMessage {
                    Label(message, systemImage: "calendar.badge.clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Screen History soak status. \(message)")
                }

                Divider()

                HStack {
                    Text("Keep history for")
                    Spacer()
                    Picker("Keep history for", selection: Binding(
                        get: { viewModel.screenHistoryRetentionDaysSelection },
                        set: { viewModel.screenHistoryRetentionDaysSelection = $0 }
                    )) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                HStack {
                    Text("Storage limit")
                    Spacer()
                    Picker("Storage limit", selection: Binding(
                        get: { viewModel.screenHistoryStorageCapGBSelection },
                        set: { viewModel.screenHistoryStorageCapGBSelection = $0 }
                    )) {
                        Text("5 GB").tag(5)
                        Text("10 GB").tag(10)
                        Text("20 GB").tag(20)
                        Text("50 GB").tag(50)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                if let message = viewModel.screenHistoryRetentionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Apply reviewed retention limits") {
                    Task { await viewModel.applyReviewedScreenHistoryRetention() }
                }
                .disabled(viewModel.screenHistoryPendingRetentionPolicy == nil)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Excluded applications")
                        .font(.body.weight(.semibold))
                    Text("Add one app bundle ID per line, such as com.apple.Safari. Protected apps stay excluded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: exclusionBinding)
                        .font(.body.monospaced())
                        .frame(minHeight: exclusionEditorMinHeight)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius).fill(AQDesign.ColorToken.keyCapFill))
                        .accessibilityLabel("Excluded application bundle identifiers")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Excluded websites")
                        .font(.body.weight(.semibold))
                    Text("Enter one domain per line. These rules filter existing history and legacy migration. Browser capture remains unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: domainExclusionBinding)
                        .font(.body.monospaced())
                        .frame(minHeight: exclusionEditorMinHeight)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius).fill(AQDesign.ColorToken.keyCapFill))
                        .accessibilityLabel("Excluded website domains")
                }

                Divider()

                if ScreenHistoryReleasePolicy.allowsOwnedCapture {
                    Text("Start only after you review the retention and exclusion rules above. Quick Launch asks again after every launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Start capture") {
                            Task { await viewModel.confirmAndStartScreenHistoryCapture() }
                        }
                        .disabled(
                            !viewModel.settings.screenHistoryCaptureEnabled
                                || viewModel.screenHistoryCaptureStartBlocker != nil
                        )
                        Button("Stop capture") {
                            Task { await viewModel.stopScreenHistoryCapture() }
                        }
                        .disabled(!viewModel.screenHistoryCaptureIsActive)
                        Spacer()
                    }
                } else {
                    Text("Start and Stop controls will appear only after the live privacy and soak gates pass in a later release.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            viewModel.noteScreenHistorySettingsPresented()
            await viewModel.applyScreenHistoryCaptureSettings()
            await viewModel.refreshScreenHistoryCoastImportAvailability()
            await viewModel.refreshCoastFreezeReceipt()
            await viewModel.refreshScreenHistoryRetirementReview()
        }
    }

    private var captureStatus: String {
        viewModel.screenHistoryCaptureStatusLabel
    }

    private var fileVaultStatus: String {
        switch viewModel.screenHistoryCaptureStatus?.fileVaultStatus {
        case .on: return "On"
        case .off: return "Off"
        case .unknown, nil: return "Not verified"
        }
    }

    private var fileVaultStatusIcon: String {
        switch viewModel.screenHistoryCaptureStatus?.fileVaultStatus {
        case .on: return "checkmark.shield"
        case .off: return "xmark.shield"
        case .unknown, nil: return "questionmark.diamond"
        }
    }

    private var captureStatusIcon: String {
        switch viewModel.screenHistoryCaptureStatus?.state {
        case .running: "record.circle"
        case .pausedForInactivity: "pause.circle"
        case .stopped, .disabled, nil: "stop.circle"
        }
    }

    private var exclusionBinding: Binding<String> {
        Binding(
            get: { viewModel.settings.screenHistoryExcludedBundleIDs.sorted().joined(separator: "\n") },
            set: { value in
                let ids = value.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
                let normalized = Array(Set(ids)).sorted()
                if normalized != viewModel.settings.screenHistoryExcludedBundleIDs {
                    viewModel.invalidateScreenHistoryCoastImportPreview()
                }
                viewModel.settings.screenHistoryExcludedBundleIDs = normalized
                viewModel.settings.save()
                Task { await viewModel.applyScreenHistoryCaptureSettings() }
            }
        )
    }

    private var domainExclusionBinding: Binding<String> {
        Binding(
            get: { viewModel.settings.screenHistoryExcludedDomains.sorted().joined(separator: "\n") },
            set: { value in
                let domains = value
                    .split(whereSeparator: \.isWhitespace)
                    .compactMap { ScreenHistoryCaptureConfiguration.normalizedDomain(String($0)) }
                let normalized = Array(Set(domains)).sorted()
                if normalized != viewModel.settings.screenHistoryExcludedDomains {
                    viewModel.invalidateScreenHistoryCoastImportPreview()
                }
                viewModel.settings.screenHistoryExcludedDomains = normalized
                viewModel.settings.save()
                Task { await viewModel.applyScreenHistoryCaptureSettings() }
            }
        )
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
