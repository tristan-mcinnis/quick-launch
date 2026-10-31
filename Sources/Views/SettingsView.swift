import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HouseDesign

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
            VStack(spacing: SettingsMetrics.headerGap) {
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
            }
            paneFooter
        }
    }

    private var paneHeader: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            Text(tab.title)
                .font(AQDesign.TypeToken.title)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
            Text(tab.subtitle)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsMetrics.paneInset)
        .padding(.top, SettingsMetrics.paneTop)
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

// MARK: - Prompts

private struct SavedPromptsTab: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        SavedPromptsEditor(viewModel: viewModel)
    }
}
