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
    /// The group a search result asked to reveal. Cleared on any manual tab
    /// change so the highlight does not linger after the user moves on.
    @State private var focus: SettingsFocus?
    @State private var focusToken = 0
    @State private var searchSelection = 0
    @State private var clearFocusTask: Task<Void, Never>?
    @FocusState private var searchFieldFocused: Bool

    init(
        viewModel: QuickViewModel,
        initialTab: SettingsTab = .general,
        initialDestination: SettingsDestination? = nil
    ) {
        self.viewModel = viewModel
        _tab = State(initialValue: initialDestination?.pane ?? initialTab)
        let token = 1
        _focusToken = State(initialValue: token)
        _focus = State(initialValue: initialDestination.map {
            SettingsFocus(pane: $0.pane, anchor: $0.anchor, token: token)
        })
    }

    /// The Settings tabs. The enum now lives in the model layer
    /// (`SettingsPane`) so the launcher's search index can name a pane without
    /// importing this view; the old nested name stays as an alias for every
    /// existing caller and test.
    typealias SettingsTab = SettingsPane

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
        .onReceive(
            NotificationCenter.default.publisher(for: .revealSettingsDestination)
        ) { note in
            guard let destination = note.object as? SettingsDestination else { return }
            reveal(destination)
        }
        .onAppear { scheduleFocusFade() }
        .onChange(of: tab) { _, newTab in
            // ⌘1…⌘7 and rail clicks move panes without clearing a reveal, so
            // clear it here: the highlight belongs to the pane that was asked
            // for, not to whatever pane the user moved to next.
            if let current = focus, current.pane != newTab { focus = nil }
        }
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

    /// The pane and anchor this view was asked to open on. Internal so a test
    /// can assert the destination landed, not just that the frame has a size.
    var revealedDestinationForTesting: (pane: SettingsPane, anchor: String)? {
        guard let focus else { return nil }
        return (focus.pane, focus.anchor)
    }

    private var pane: some View {
        VStack(spacing: 0) {
            paneHeader
            Group {
                switch tab {
                case .general: GeneralTab(viewModel: viewModel)
                case .keyboard: KeyboardShortcutsSettingsView(viewModel: viewModel)
                case .items: ItemsSettingsView(viewModel: viewModel)
                case .models: ProviderSettingsView(viewModel: viewModel)
                case .clipboard: ClipboardLinksSettingsView(viewModel: viewModel)
                case .prompts: SavedPromptsTab(viewModel: viewModel)
                case .about: AboutTab(viewModel: viewModel)
                }
            }
            .environment(\.settingsFocus, focus)
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

    /// The destinations the typed query matches, or nothing when the field is
    /// empty. The sidebar and the launcher share this one index.
    private var searchHits: [SettingsDestination] {
        SettingsDestinationIndex.matching(settingsQuery)
    }

    private var isSearching: Bool {
        !settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Switches to a destination's pane, scrolls its group into view, and
    /// lights it. The token makes a repeated request for the same group
    /// scroll again instead of reading as no change.
    private func reveal(_ destination: SettingsDestination) {
        tab = destination.pane
        focusToken += 1
        focus = SettingsFocus(pane: destination.pane, anchor: destination.anchor, token: focusToken)
        scheduleFocusFade()
    }

    /// Fades a reveal highlight after the user has had time to see where it
    /// landed. Also called on appear, so a destination an `initialDestination`
    /// set before the window existed fades too (there is no `reveal` then).
    private func scheduleFocusFade() {
        guard let current = focus else { return }
        let token = current.token
        clearFocusTask?.cancel()
        clearFocusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, focus?.token == token else { return }
            focus = nil
        }
    }

    /// Moves the search highlight. Arrow keys in the search field route here
    /// before the field editor sees them.
    private func moveSearchSelection(_ delta: Int) {
        let count = searchHits.count
        guard count > 0 else { return }
        searchSelection = min(max(searchSelection + delta, 0), count - 1)
    }

    /// Return in the search field: go to the highlighted hit, or the first one
    /// when the highlight was never moved.
    private func activateSearchSelection() {
        let hits = searchHits
        let destination = hits.indices.contains(searchSelection) ? hits[searchSelection] : hits.first
        guard let destination else { return }
        reveal(destination)
        searchFieldFocused = false
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            searchField

            ScrollView {
                LazyVStack(spacing: SettingsMetrics.railGap) {
                    if isSearching {
                        if searchHits.isEmpty {
                            noResults
                        } else {
                            ForEach(Array(searchHits.enumerated()), id: \.element.id) { index, hit in
                                searchResultRow(hit, isSelected: index == searchSelection)
                            }
                        }
                    } else {
                        ForEach(SettingsTab.allCases) { item in
                            railRow(item)
                        }
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
        .onChange(of: settingsQuery) { _, _ in searchSelection = 0 }
    }

    /// A usable empty state: it names the query and offers words that work.
    private var noResults: some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
            Text("No settings found")
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
            Text("Nothing matches \u{201C}\(settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}. Try caffeinate, updates, or clipboard.")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AQDesign.Space.standard)
        .padding(.vertical, AQDesign.Space.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One search hit: the setting's own name above the pane it lives in, so
    /// a glance says both what and where before Return goes there.
    private func searchResultRow(_ destination: SettingsDestination, isSelected: Bool) -> some View {
        Button {
            reveal(destination)
            searchFieldFocused = false
        } label: {
            HStack(spacing: AQDesign.Space.standard) {
                IconTile {
                    Image(systemName: destination.pane.systemImage)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(
                            isSelected
                                ? AQDesign.ColorToken.textPrimary
                                : AQDesign.ColorToken.textSecondary
                        )
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(destination.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(
                            isSelected
                                ? AQDesign.ColorToken.textPrimary
                                : AQDesign.ColorToken.textSecondary
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(destination.pane.title)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: AQDesign.Space.compact)
                if isSelected {
                    Image(systemName: "return")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                }
            }
            .padding(.horizontal, AQDesign.Space.standard)
            .frame(maxWidth: .infinity, minHeight: House.Control.railRow, alignment: .leading)
            .background(
                RowHighlight(
                    isSelected: isSelected,
                    isHovering: false,
                    radius: AQDesign.menuCornerRadius
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel("\(destination.title), \(destination.pane.title)")
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
                    .focused($searchFieldFocused)
                    .accessibilityLabel("Search settings…")
                    .onSubmit { activateSearchSelection() }
                    .onKeyPress(.downArrow) { moveSearchSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSearchSelection(-1); return .handled }
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
            focus = nil
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
    /// A failed Caffeinate assertion is surfaced here, beside the switch that
    /// asked for it, instead of being silently swallowed.
    @State private var caffeinateError: String?

    var body: some View {
        SettingsPaneScroller(pane: .general) {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                hotkeysCard.settingsAnchor("general.hotkeys")
                behaviourCard.settingsAnchor("general.behaviour")
                caffeinateCard.settingsAnchor("general.caffeinate")
                // High in the pane: these are behaviour settings, and the
                // cards under them (Learning & Review especially) are long.
                QuickAISettingsView(viewModel: viewModel).settingsAnchor("general.quickAI")
                ChatSettingsView(viewModel: viewModel).settingsAnchor("general.chat")
                FallbackCommandsView(viewModel: viewModel).settingsAnchor("general.fallback")
                learningAndReviewCard.settingsAnchor("general.learning")
                HistorySettingsView(viewModel: viewModel).settingsAnchor("general.history")
                appearanceCard.settingsAnchor("general.appearance")
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
            SettingsRow(
                title: "Copy the first answer of each chat automatically",
                detail: "Not follow-ups or AI Chat. Clipboard History skips it.",
                isFirst: true
            ) {
                Toggle(
                    "Copy the first answer of each chat automatically",
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

    /// Caffeinate's four preferences. These lived only in the launcher's
    /// Caffeinate catalog; the master switch, Agent Watch, the battery cutoff,
    /// and the display assertion now have a home here too, and every control
    /// writes both the stored setting and the running manager.
    private var caffeinateCard: some View {
        SettingsCard("Caffeinate") {
            SettingsRow(
                title: "Keep this Mac awake",
                detail: "Hold a sleep assertion until you turn it off. A timed session set from the launcher still shows below.",
                isFirst: true
            ) {
                Toggle(
                    "Keep this Mac awake",
                    isOn: Binding(
                        get: { viewModel.settings.caffeinateEnabled },
                        set: { enabled in
                            if viewModel.setCaffeinateEnabled(enabled) {
                                caffeinateError = nil
                            } else {
                                caffeinateError = "Could not turn Caffeinate \(enabled ? "on" : "off")."
                            }
                        }
                    )
                )
                .toggleStyle(InkToggleStyle())
            }
            .settingsAnchor("general.caffeinate.enabled", radius: AQDesign.fieldCornerRadius)

            SettingsRow(
                title: "Agent Watch",
                detail: "Stay awake while Claude Code or Codex is working, then let the Mac sleep again."
            ) {
                Toggle(
                    "Agent Watch",
                    isOn: viewModel.settingsBinding(\.caffeinateAgentWatch) { _ in
                        viewModel.applyCaffeinatePreferences()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }
            .settingsAnchor("general.caffeinate.agentWatch", radius: AQDesign.fieldCornerRadius)

            SettingsRow(
                title: "Pause on battery at",
                detail: "On battery at or below this percent, sleep is allowed again. Off never pauses."
            ) {
                Picker(
                    "Pause on battery at",
                    selection: viewModel.settingsBinding(\.caffeinateBatteryCutoff) { _ in
                        viewModel.applyCaffeinatePreferences()
                    }
                ) {
                    ForEach(batteryCutoffChoices, id: \.self) { percent in
                        Text(percent == 0 ? "Off" : "\(percent)%").tag(percent)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .accessibilityLabel("Pause Caffeinate on battery at")
            }
            .settingsAnchor("general.caffeinate.battery", radius: AQDesign.fieldCornerRadius)

            SettingsRow(
                title: "Keep the display awake",
                detail: "Also prevent the display from idle-sleeping. Off, only the system stays awake."
            ) {
                Toggle(
                    "Keep the display awake",
                    isOn: viewModel.settingsBinding(\.caffeinateKeepDisplayAwake) { _ in
                        viewModel.applyCaffeinatePreferences()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }
            .settingsAnchor("general.caffeinate.display", radius: AQDesign.fieldCornerRadius)

            CardNote { CardText(caffeinateStatusText) }
            // A timed or Agent Watch session leaves the master switch off, so
            // its own cancel control lives here. A paused session is still in
            // force and is exactly the case this is for.
            if viewModel.hasCaffeinateSession, !viewModel.settings.caffeinateEnabled {
                CardNote {
                    Button("Decaffeinate", role: .destructive) {
                        _ = viewModel.setCaffeinateEnabled(false)
                    }
                }
            }
            if let caffeinateError {
                CardNote { CardText(caffeinateError, tone: AQDesign.ColorToken.danger) }
            }
        }
    }

    /// The presets, plus whatever is stored, so a value written by an older
    /// build (or a hand-edited plist) still renders and stays selectable.
    private var batteryCutoffChoices: [Int] {
        var choices = [0, 10, 20, 30, 50]
        let current = viewModel.settings.caffeinateBatteryCutoff
        if !choices.contains(current) {
            choices.append(current)
            choices.sort()
        }
        return choices
    }

    /// The manager's own policy line: it names the reason and reports a
    /// battery pause, which `isCaffeinating` alone cannot (the assertion is
    /// released while paused).
    private var caffeinateStatusText: String {
        viewModel.caffeinateStatusSummary
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
        SettingsPaneScroller(pane: .about) {
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
                    .settingsAnchor("about.updates", radius: AQDesign.fieldCornerRadius)

                    SettingsRow(
                        title: "Check for updates on launch",
                        detail: "Asks GitHub once at launch for the newest release tag. Never installs on its own."
                    ) {
                        Toggle(
                            "Check for updates on launch",
                            isOn: viewModel.settingsBinding(\.checkForUpdatesOnLaunch)
                        )
                        .toggleStyle(InkToggleStyle())
                    }
                }
                .settingsAnchor("about.version")

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
                .settingsAnchor("about.source")
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
