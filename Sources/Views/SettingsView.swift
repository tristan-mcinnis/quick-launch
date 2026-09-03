import SwiftUI
import AppKit

/// Measures the Settings shell and its panes share.
///
/// Every value here is a house token except `paneInset`: the mockup's 22 pt
/// pane gutter is the one Settings measure that is not on the spacing scale.
enum SettingsMetrics {
    /// Horizontal gutter of the pane header, the cards, and the notes.
    static let paneInset: CGFloat = 22
    /// Gap between the cards stacked down a pane.
    static let cardGap = House.Spacing.sm
    /// Gap between two rail rows.
    static let railGap: CGFloat = 3
}

/// A full-width strip inside a `SettingsCard` that is not a titled row:
/// helper text, an error line, or a lone button. Draws the same divider
/// above itself that `SettingsRow` does.
struct CardNote<Content: View>: View {
    var isFirst = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { HouseDivider() }
            HStack(spacing: House.Spacing.sm) {
                content
                Spacer(minLength: 0)
            }
            .padding(.vertical, AQDesign.Space.standard)
        }
    }
}

/// The text of a `CardNote`: caption ink, wrapping, never truncated.
struct CardText: View {
    let text: String
    var tone: Color = AQDesign.ColorToken.textSecondary

    init(_ text: String, tone: Color = AQDesign.ColorToken.textSecondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(AQDesign.TypeToken.caption)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One option of an `InkSegmentedControl`.
struct InkSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// A segmented control in ink. The selected segment is the house selection
/// tile (fill, inset ring, 1 pt drop); hover is half the fill. Never an
/// accent tint, which is what `.pickerStyle(.segmented)` would paint.
struct InkSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [InkSegment<Value>]
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(
                            isSelected
                                ? AQDesign.ColorToken.textPrimary
                                : AQDesign.ColorToken.textSecondary
                        )
                        .lineLimit(1)
                        .padding(.horizontal, AQDesign.Space.row)
                        .frame(maxWidth: .infinity, minHeight: AQDesign.tileSize)
                        .background(
                            RowHighlight(
                                isSelected: isSelected,
                                isHovering: hovered == option.value,
                                radius: AQDesign.fieldCornerRadius
                            )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = option.value
                    } else if hovered == option.value {
                        hovered = nil
                    }
                }
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(AQDesign.Space.compact)
        .background(
            RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                .fill(AQDesign.ColorToken.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                .strokeBorder(AQDesign.ColorToken.tileStroke, lineWidth: AQDesign.hairline)
        )
    }
}

/// Settings window: a 220 pt rail on `surfaceSunken` beside one pane per
/// tab. Each pane is a title, a subtitle, a stack of cards, and a footer
/// well. No system tab view: it overflows into a "»" menu on narrow windows.
struct SettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var tab: SettingsTab
    @State private var settingsQuery = ""
    @State private var hoveredTab: SettingsTab?

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
        /// One plain line under the pane title.
        var subtitle: String {
            switch self {
            case .general: "Hotkeys, launcher behaviour, and learning."
            case .items: "Aliases and hotkeys for apps, folders, and commands."
            case .models: "Providers, models, and the quick-action instruction."
            case .clipboard: "Clipboard history, colors, emoji, and Quicklinks."
            case .screenHistory: "Sources, capture, retention, and exclusions."
            case .prompts: "Saved AI commands, their aliases, and hotkeys."
            case .about: "Version, updates, and source."
            }
        }
        /// The quiet hint on the left of the footer well. Keep it true.
        var footerHint: String {
            switch self {
            case .general, .items, .clipboard, .prompts: "Applies immediately"
            case .models: "Model changes apply immediately"
            case .screenHistory: "Capture stays locked in this build"
            case .about: "Version and updates"
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
            Rectangle()
                .fill(AQDesign.ColorToken.divider)
                .frame(width: AQDesign.hairline)
            pane
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

    // MARK: - Pane

    private var pane: some View {
        VStack(spacing: 0) {
            paneHeader
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
            paneFooter
        }
    }

    private var paneHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tab.title)
                .font(AQDesign.TypeToken.title)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
            Text(tab.subtitle)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsMetrics.paneInset)
        .padding(.vertical, House.Spacing.md)
    }

    private var paneFooter: some View {
        FooterWell {
            HStack(spacing: House.Spacing.sm) {
                Text(tab.footerHint)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: House.Spacing.sm)
                KeyHint(label: "Next", keys: ["\u{2318}", nextTabNumber])
            }
        }
    }

    /// The ⌘-number of the tab after this one; the last tab wraps to 1.
    private var nextTabNumber: String {
        let all = SettingsTab.allCases
        guard let index = all.firstIndex(of: tab) else { return "1" }
        return String((index + 1) % all.count + 1)
    }

    // MARK: - Rail

    private var filteredTabs: [SettingsTab] {
        let query = settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsTab.allCases }
        return SettingsTab.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            searchField

            ScrollView {
                LazyVStack(spacing: SettingsMetrics.railGap) {
                    ForEach(filteredTabs) { item in
                        railRow(item)
                    }
                }
            }

            Spacer(minLength: 0)
            Text("Quick Launch")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
        }
        .padding(House.Spacing.sm)
        .frame(width: House.Layout.settingsRail)
        .background(AQDesign.ColorToken.sidebarSurface)
    }

    private var searchField: some View {
        HStack(spacing: AQDesign.Space.standard) {
            Image(systemName: "magnifyingglass")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
            ZStack(alignment: .leading) {
                if settingsQuery.isEmpty {
                    Text("Search settings…")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $settingsQuery)
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .accessibilityLabel("Search settings…")
            }
        }
        .padding(.horizontal, AQDesign.Space.standard)
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

    private func railRow(_ item: SettingsTab) -> some View {
        let isSelected = tab == item
        return Button {
            tab = item
        } label: {
            HStack(spacing: AQDesign.Space.standard) {
                IconTile {
                    Image(systemName: item.systemImage)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(
                            isSelected
                                ? AQDesign.ColorToken.textPrimary
                                : AQDesign.ColorToken.textSecondary
                        )
                }
                Text(item.title)
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(
                        isSelected
                            ? AQDesign.ColorToken.textPrimary
                            : AQDesign.ColorToken.textSecondary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: AQDesign.Space.compact)
                if let index = SettingsTab.allCases.firstIndex(of: item) {
                    Text("\u{2318}\(index + 1)")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                }
            }
            .padding(.horizontal, AQDesign.Space.standard)
            .frame(maxWidth: .infinity, minHeight: House.Control.railRow, alignment: .leading)
            .background(
                RowHighlight(
                    isSelected: isSelected,
                    isHovering: hoveredTab == item,
                    radius: AQDesign.menuCornerRadius
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredTab = item
            } else if hoveredTab == item {
                hoveredTab = nil
            }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                hotkeysCard
                behaviourCard
                historyCard
                appearanceCard
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, House.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hotkeysCard: some View {
        SettingsCard("Hotkeys") {
            SettingsRow(title: "Open Quick Launch", isFirst: true) {
                HotkeyRecorderView(
                    keyCode: viewModel.settingsBinding(\.hotkeyKeyCode),
                    modifiers: viewModel.settingsBinding(\.hotkeyModifiers),
                    label: "Open Quick Launch",
                    showsLabel: false
                )
            }
            if let error = viewModel.hotkeyRegistrationError {
                CardNote { CardText(error, tone: AQDesign.ColorToken.danger) }
            }

            SettingsRow(title: "Open Translator") {
                ActionHotkeyRecorderView(
                    hotkey: viewModel.settingsBinding(
                        get: { $0.translatorHotkey as ActionHotkey? },
                        set: { settings, value in
                            settings.translatorHotkey = value
                                ?? ActionHotkey(keyCode: 17, modifiers: 1_048_576 | 131_072)
                        }
                    ),
                    label: "Open Translator",
                    showsLabel: false,
                    changeNotification: .translatorSettingsChanged
                )
            }
            if let error = viewModel.settings.translatorHotkeyConflict()
                ?? viewModel.translatorHotkeyRegistrationError {
                CardNote { CardText(error, tone: AQDesign.ColorToken.danger) }
            }

            SettingsRow(title: "Type to Click") {
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
                    label: "Type to Click",
                    showsLabel: false,
                    changeNotification: .typeToClickSettingsChanged
                )
            }

            SettingsRow(title: "After Return") {
                Picker("After Return", selection: viewModel.settingsBinding(\.typeToClickContinuation) { _ in
                    NotificationCenter.default.post(name: .typeToClickSettingsChanged, object: nil)
                }) {
                    ForEach(TypeToClickContinuation.allCases, id: \.self) { continuation in
                        Text(continuation.displayName).tag(continuation)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            CardNote { CardText(typeToClickNote, tone: typeToClickNoteTone) }
        }
    }

    private var typeToClickNote: String {
        if let error = viewModel.settings.typeToClickHotkeyConflict()
            ?? viewModel.typeToClickHotkeyRegistrationError {
            return error
        }
        guard viewModel.settings.typeToClickHotkeyEnabled else {
            return "No direct hotkey. Type to Click remains available from Quick Launch."
        }
        return viewModel.settings.typeToClickContinuation == .continuous
            ? "Press \(viewModel.settings.typeToClickHotkey.displayName) to label clickable targets by name. Type to narrow them, then press Return. It pulses the choice, prioritizes an opened menu, and stays open for the next step; Esc or the shortcut closes it."
            : "Press \(viewModel.settings.typeToClickHotkey.displayName) to label clickable targets by name. Type to narrow them, then press Return. It acts once and closes; invoke Type to Click again for another action."
    }

    private var typeToClickNoteTone: Color {
        let conflict = viewModel.settings.typeToClickHotkeyConflict()
            ?? viewModel.typeToClickHotkeyRegistrationError
        return conflict == nil
            ? AQDesign.ColorToken.textSecondary
            : AQDesign.ColorToken.danger
    }

    private var behaviourCard: some View {
        SettingsCard("Behaviour") {
            SettingsRow(title: "Copy result to clipboard automatically", isFirst: true) {
                Toggle(
                    "Copy result to clipboard automatically",
                    isOn: viewModel.settingsBinding(\.autoCopy)
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Launch at login") {
                Toggle(
                    "Launch at login",
                    isOn: viewModel.settingsBinding(\.launchAtLogin) { _ in viewModel.applyLaunchAtLogin() }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Show menu bar icon") {
                Toggle("Show menu bar icon", isOn: viewModel.settingsBinding(\.showMenuBar))
                    .toggleStyle(InkToggleStyle())
                    .disabled(!viewModel.screenHistory.menuBarCanBeHidden)
            }
            if !viewModel.screenHistory.menuBarCanBeHidden {
                CardNote {
                    CardText("The menu bar status stays visible while Screen History capture is on.")
                }
            }

            SettingsRow(
                title: "Learn from my choices",
                detail: "Items you pick for a search rise to the top next time. Stored only on this Mac."
            ) {
                Toggle(
                    "Learn from my choices",
                    isOn: viewModel.settingsBinding(\.launcherLearningEnabled)
                )
                .toggleStyle(InkToggleStyle())
            }
            CardNote {
                Button("Forget learned ranking", role: .destructive) {
                    viewModel.forgetLearnedRanking()
                }
            }

            SettingsRow(title: "Double-tap right \u{2318} sends the focused window to AI") {
                Toggle(
                    "Double-tap right \u{2318} sends the focused window to AI",
                    isOn: viewModel.settingsBinding(\.screenAwarenessDoubleTap) { _ in
                        NotificationCenter.default.post(name: .screenAwarenessSettingsChanged, object: nil)
                    }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Search text inside screenshots (on-device OCR)") {
                Toggle(
                    "Search text inside screenshots (on-device OCR)",
                    isOn: viewModel.settingsBinding(\.screenshotTextSearch)
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Show welcome screen on next launch") {
                Toggle(
                    "Show welcome screen on next launch",
                    isOn: viewModel.settingsBinding(
                        get: { !$0.hasSeenWelcome },
                        set: { settings, show in settings.hasSeenWelcome = !show }
                    )
                )
                .toggleStyle(InkToggleStyle())
            }
        }
    }

    private var historyCard: some View {
        SettingsCard("History") {
            SettingsRow(title: "Keep quick-action history", isFirst: true) {
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
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Saved history") {
                Button("Clear history", role: .destructive) {
                    viewModel.clearHistory()
                }
            }

            SettingsRow(title: "Start a new thread after") {
                Picker("Start a new thread after", selection: viewModel.settingsBinding(\.newConversationAfterMinutes)) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
                .labelsHidden()
                .frame(width: 140)
            }

            SettingsRow(title: "Keep my place after closing") {
                Picker("Keep my place after closing", selection: viewModel.settingsBinding(\.reopenRetentionSeconds)) {
                    Text("Do not keep").tag(0)
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
    }

    private var appearanceCard: some View {
        SettingsCard("Appearance") {
            SettingsRow(title: "Appearance", isFirst: true) {
                InkSegmentedControl(
                    selection: viewModel.settingsBinding(\.appearance),
                    options: AppearancePreference.allCases.map {
                        InkSegment(value: $0, title: $0.displayName)
                    }
                )
                .frame(maxWidth: 300)
            }
        }
    }
}

// MARK: - Prompts

private struct SavedPromptsTab: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        SavedPromptsEditor(viewModel: viewModel)
    }
}

// MARK: - About

private struct AboutTab: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                SettingsCard("Version") {
                    SettingsRow(title: "Quick Launch", isFirst: true) {
                        Text("Version \(viewModel.currentVersion)")
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    }

                    SettingsRow(title: "Updates") {
                        HStack(spacing: House.Spacing.sm) {
                            updateStatusView
                            Button("Check for update") {
                                Task { await viewModel.checkForUpdateManual() }
                            }
                            .disabled(viewModel.updateState == .checking)
                        }
                    }
                }

                SettingsCard("Source") {
                    SettingsRow(title: "Repository", isFirst: true) {
                        Link(
                            "Source on GitHub",
                            destination: URL(string: "https://github.com/tristan-mcinnis/quick-launch")!
                        )
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.accent)
                    }
                }
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, House.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch viewModel.updateState {
        case .checking:
            statusLine("Checking…", dot: AQDesign.ColorToken.warning)
        case .upToDate:
            statusLine("Up to date", dot: AQDesign.ColorToken.success)
        case .updateAvailable(let v):
            Button("Update to \(v)") { [weak viewModel] in viewModel?.installUpdate() }
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .buttonStyle(.plain)
        case .installing(let v):
            statusLine("Installing \(v)…", dot: AQDesign.ColorToken.warning)
        case .installed(let v):
            statusLine("Installed \(v)", dot: AQDesign.ColorToken.success)
        case .error(let msg):
            statusLine(msg, dot: AQDesign.ColorToken.danger)
        case .idle:
            EmptyView()
        }
    }

    private func statusLine(_ text: String, dot: Color) -> some View {
        HStack(spacing: AQDesign.Space.standard) {
            StatusDot(color: dot)
            Text(text)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
