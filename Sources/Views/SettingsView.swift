import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
            case .general: "Hotkeys, launcher behaviour, chats, and learning."
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
                // High in the pane: these are behaviour settings, and the
                // cards under them (Learning & Review especially) are long.
                QuickAISettingsView(viewModel: viewModel)
                ChatSettingsView(viewModel: viewModel)
                FallbackCommandsView(viewModel: viewModel)
                learningAndReviewCard
                HistorySettingsView(viewModel: viewModel)
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

    /// Ranking learning and the interaction journal sit together: they are the
    /// two halves of "how does Quick Launch learn from me, and what can I see
    /// and undo".
    private var learningAndReviewCard: some View {
        SettingsCard("Learning & Review") {
            SettingsRow(
                title: "Learn from my choices",
                detail: "Items you pick for a search rise to the top next time. Stored only on this Mac.",
                isFirst: true
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

            SettingsRow(
                title: "Keep a local interaction journal",
                detail: "Records outcomes only — choices, abandoned searches, retries, and failures. No text, no content, no network. Turning it off stops new recording; events already kept stay on this Mac and keep ageing out until you clear them."
            ) {
                Toggle(
                    "Keep a local interaction journal",
                    isOn: viewModel.settingsBinding(\.interactionJournalEnabled) { _ in
                        viewModel.applyInteractionJournalSettings()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }
            if !viewModel.settings.interactionJournalEnabled {
                CardNote {
                    CardText(
                        viewModel.interactionJournalEvents.isEmpty
                            ? "Recording is off. Nothing new is written."
                            : "Recording is off. The "
                                + "\(viewModel.interactionJournalEvents.count) saved event"
                                + "\(viewModel.interactionJournalEvents.count == 1 ? "" : "s") "
                                + "stay on this Mac and remain exportable and clearable, and "
                                + "still age out on the retention below."
                    )
                }
            }

            SettingsRow(title: "Keep journal events for") {
                Picker(
                    "Keep journal events for",
                    selection: viewModel.settingsBinding(\.interactionJournalRetentionDays) { _ in
                        viewModel.applyInteractionJournalSettings()
                    }
                ) {
                    ForEach(retentionChoices, id: \.self) { days in
                        Text(Self.retentionTitle(days)).tag(days)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            SettingsRow(title: "Maximum journal events") {
                Picker(
                    "Maximum journal events",
                    selection: viewModel.settingsBinding(\.interactionJournalEventCap) { _ in
                        viewModel.applyInteractionJournalSettings()
                    }
                ) {
                    ForEach(eventCapChoices, id: \.self) { cap in
                        Text(cap.formatted()).tag(cap)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            CardNote { CardText(journalStatusText) }

            journalReview

            CardNote {
                HStack(spacing: House.Spacing.sm) {
                    Menu("Export…") {
                        ForEach(InteractionJournalExportFormat.allCases) { format in
                            Button(format.title) { exportJournal(as: format) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(viewModel.interactionJournalEvents.isEmpty)
                    Button("Reveal in Finder") { viewModel.revealInteractionJournal() }
                    Button("Clear journal", role: .destructive) {
                        viewModel.clearInteractionJournal()
                    }
                    .disabled(viewModel.interactionJournalEvents.isEmpty)
                }
            }

            CardNote {
                CardText(
                    "Local only: the journal lives at "
                        + "~/Library/Application Support/Quick Launch/interaction-journal.json "
                        + "with owner-only permissions, and nothing is ever sent anywhere. "
                        + "Its query digest is keyed with a random key this Mac generated "
                        + "(interaction-journal-key, also owner-only and re-checked on "
                        + "every launch), so repeats correlate here and the digest cannot "
                        + "be recomputed without that file. "
                        + "It never stores clipboard, snippet, chat, selection, file, query, "
                        + "or AI answer text. Typed text is written only as that keyed "
                        + "digest plus a coarse size band — including a question you "
                        + "submit through the Ask AI row. That digest is one-way, not a "
                        + "secret store: a short query is still guessable by brute force "
                        + "if someone has the key file, so avoid typing secrets here. "
                        + "An identifier that could carry content, such as a typed web "
                        + "address or a window title, is replaced by a keyed digest too; "
                        + "for a typed web address the launcher's own row identity is a "
                        + "keyless content hash, which is stable but not cryptographic, "
                        + "so this journal re-keys it. "
                        + "Marked rows are review notes and never change ranking."
                )
            }
        }
    }

    /// Every clamped setting value must render and select. The documented range
    /// is far wider than the presets, so the current value is added when it is
    /// not already offered.
    private var retentionChoices: [Int] {
        InteractionJournalStore.retentionChoices(
            including: viewModel.settings.interactionJournalRetentionDays
        )
    }

    private var eventCapChoices: [Int] {
        InteractionJournalStore.eventCapChoices(
            including: viewModel.settings.interactionJournalEventCap
        )
    }

    private static func retentionTitle(_ days: Int) -> String {
        switch days {
        case 7, 30, 90: "\(days) days"
        case 365: "1 year"
        case 1: "1 day"
        default: "\(days) days"
        }
    }

    private var journalStatusText: String {
        let events = viewModel.interactionJournalEvents
        guard let first = events.first else { return "No events recorded yet." }
        var text = "\(events.count) event\(events.count == 1 ? "" : "s") · "
        text += ByteCountFormatter.string(
            fromByteCount: Int64(viewModel.interactionJournalByteSize),
            countStyle: .file
        )
        text += " · last \(first.date.formatted(date: .abbreviated, time: .shortened))"
        let accidents = events.count { $0.markedAccidental }
        if accidents > 0 { text += " · \(accidents) marked accidental" }
        return text
    }

    /// The last few outcomes, each with the explicit, reversible "wrong choice"
    /// marker. Nothing here is inferred and nothing feeds ranking.
    private var journalReview: some View {
        let events = Array(viewModel.interactionJournalEvents.prefix(6))
        let revision = viewModel.interactionJournalRevision
        return Group {
            if !events.isEmpty {
                VStack(spacing: 0) {
                    HouseDivider()
                    ForEach(events) { event in
                        journalRow(event)
                    }
                }
                .id(revision)
            }
        }
    }

    private func journalRow(_ event: InteractionJournalEvent) -> some View {
        HStack(spacing: House.Spacing.sm) {
            Text(event.date.formatted(date: .omitted, time: .shortened))
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .frame(width: 58, alignment: .leading)
            Text(event.kind.shortTitle)
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .frame(width: 84, alignment: .leading)
            Text(journalDetail(event))
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: House.Spacing.sm)
            Button(event.markedAccidental ? "Unmark" : "Mark wrong") {
                viewModel.setInteractionMarkedAccidental(
                    id: event.id,
                    accidental: !event.markedAccidental
                )
            }
            .font(AQDesign.TypeToken.caption)
        }
        .frame(minHeight: 26)
    }

    private func journalDetail(_ event: InteractionJournalEvent) -> String {
        var parts: [String] = []
        if let itemID = event.itemID { parts.append(itemID) }
        if event.scope != LauncherUsageStore.rootScope { parts.append(event.scope) }
        if let detail = event.detail { parts.append(detail) }
        if let bucket = event.queryLengthBucket { parts.append("\(bucket) chars") }
        if event.markedAccidental { parts.append("marked accidental") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func exportJournal(as format: InteractionJournalExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Interaction Journal"
        panel.nameFieldStringValue = InteractionJournalExporter.suggestedFileName(for: format)
        switch format {
        case .markdown:
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        case .jsonLines:
            panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        }
        panel.canCreateDirectories = true
        let viewModel = viewModel
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            viewModel.writeInteractionJournal(as: format, to: url)
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
