import SwiftUI

/// Manage Models: every model the configured providers report, in one
/// searchable list, with the switch that hides a model from every picker and
/// the reasoning-effort choice for the models that take one.
///
/// It is a screen rather than a card. `ProviderSettingsView` swaps the whole
/// Models pane for it and `onClose` swaps back, so the screen owns the full
/// pane height and the list never has to scroll inside a card.
///
/// Everything on it is a standard focusable control (a button, a toggle, a
/// picker, a text field), so the screen is operable from the keyboard with no
/// mouse and every control carries its own accessibility label.
struct ManageModelsView: View {
    let viewModel: QuickViewModel
    var preferences: ModelPreferenceStore = .shared
    let onClose: () -> Void

    @State private var query = ""
    @State private var sort: ModelSortOrder = .brand
    @State private var groupByProvider = true
    @State private var collapsedProviders: Set<UUID> = []
    @State private var hoveredRow: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            columnHeader
            HouseDivider()
            list
        }
        .onAppear { FocusRequest.apply($searchFocused) }
        .background(AQDesign.ColorToken.windowSurface)
    }

    // MARK: - The list itself

    private var entries: [ModelListEntry] {
        preferences.entries(for: viewModel.settings.providers)
    }

    private var listing: (flat: [ModelListEntry], groups: [ModelGroup]) {
        ModelList.build(entries, query: query, order: sort, groupsByProvider: groupByProvider)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
            Button(action: onClose) {
                HStack(spacing: AQDesign.Space.compact) {
                    Image(systemName: "chevron.left")
                        .font(AQDesign.TypeToken.caption)
                    Text("Models and providers")
                        .font(AQDesign.TypeToken.metadata)
                }
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to models and providers")

            VStack(alignment: .leading, spacing: 2) {
                Text("Manage models")
                    .font(AQDesign.TypeToken.heading)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                Text(summary)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, SettingsMetrics.paneInset)
        .padding(.top, House.Spacing.md)
        .padding(.bottom, AQDesign.Space.standard)
    }

    private var summary: String {
        let all = entries
        let enabled = all.filter(\.profile.enabled).count
        return "\(enabled) of \(all.count) models on. Turned-off models are hidden from every model picker."
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
            HStack(spacing: House.Spacing.sm) {
                searchField
                Spacer(minLength: House.Spacing.sm)
                Text("Group by Provider")
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                Toggle("Group by Provider", isOn: $groupByProvider)
                    .toggleStyle(InkToggleStyle())
            }
            VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
                SectionLabel(text: "Sort")
                InkSegmentedControl(
                    selection: $sort,
                    options: ModelSortOrder.allCases.map { InkSegment(value: $0, title: $0.title) }
                )
                .accessibilityLabel("Sort models")
            }
        }
        .padding(.horizontal, SettingsMetrics.paneInset)
        .padding(.bottom, AQDesign.Space.standard)
    }

    private var searchField: some View {
        HStack(spacing: AQDesign.Space.standard) {
            Image(systemName: "magnifyingglass")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search models")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .focused($searchFocused)
                    .accessibilityLabel("Search models")
            }
        }
        .padding(.horizontal, AQDesign.Space.standard)
        .frame(minWidth: 140, idealWidth: 240, maxWidth: 240)
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

    /// One row of column labels, so "Unknown" in a cell has a name above it.
    private var columnHeader: some View {
        HStack(spacing: House.Spacing.sm) {
            SectionLabel(text: "On")
                .frame(width: 30, alignment: .leading)
            SectionLabel(text: "Model")
                .frame(maxWidth: .infinity, alignment: .leading)
            SectionLabel(text: "Speed")
                .frame(width: Metrics.speed, alignment: .leading)
            SectionLabel(text: "Intelligence")
                .frame(width: Metrics.intelligence, alignment: .leading)
            SectionLabel(text: "Context")
                .frame(width: Metrics.context, alignment: .leading)
            SectionLabel(text: "Reasoning")
                .frame(width: Metrics.effort, alignment: .leading)
        }
        .padding(.horizontal, SettingsMetrics.paneInset)
        .frame(minHeight: House.Control.chip)
    }

    // MARK: - Rows

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if listing.flat.isEmpty {
                    Text(emptyMessage)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, House.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if groupByProvider {
                    ForEach(listing.groups) { group in
                        providerHeader(group)
                        if !collapsedProviders.contains(group.providerID) {
                            ForEach(group.entries) { row($0) }
                        }
                    }
                } else {
                    ForEach(listing.flat) { row($0) }
                }
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, House.Spacing.md)
        }
    }

    private var emptyMessage: String {
        entries.isEmpty
            ? "No models yet. Pick a provider on the Models pane and refresh its models."
            : "No models match \"\(query)\"."
    }

    private func providerHeader(_ group: ModelGroup) -> some View {
        let isCollapsed = collapsedProviders.contains(group.providerID)
        let enabled = group.entries.filter(\.profile.enabled).count
        return Button {
            if isCollapsed {
                collapsedProviders.remove(group.providerID)
            } else {
                collapsedProviders.insert(group.providerID)
            }
        } label: {
            HStack(spacing: AQDesign.Space.standard) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                SectionLabel(text: group.providerName)
                Spacer(minLength: House.Spacing.sm)
                Text("\(enabled) of \(group.entries.count) on")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
            }
            .padding(.vertical, AQDesign.Space.standard)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.providerName), \(group.entries.count) models")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .help(isCollapsed
            ? "Show the \(group.providerName) models"
            : "Hide the \(group.providerName) models")
    }

    private func row(_ entry: ModelListEntry) -> some View {
        let profile = entry.profile
        return VStack(spacing: 0) {
            HouseDivider()
            HStack(spacing: House.Spacing.sm) {
                Toggle(isOn: enabledBinding(entry)) {
                    Text("Enable \(entry.model)")
                }
                .toggleStyle(InkToggleStyle())
                .accessibilityLabel("Enable \(entry.model)")
                .frame(width: 30, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.model)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(
                            profile.enabled
                                ? AQDesign.ColorToken.textPrimary
                                : AQDesign.ColorToken.textTertiary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !groupByProvider {
                        Text(entry.providerName)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RatingDots(rating: profile.speed, label: "Speed for \(entry.model)")
                    .frame(width: Metrics.speed, alignment: .leading)
                RatingDots(rating: profile.intelligence, label: "Intelligence for \(entry.model)")
                    .frame(width: Metrics.intelligence, alignment: .leading)
                Text(profile.contextWindowLabel)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .lineLimit(1)
                    .frame(width: Metrics.context, alignment: .leading)
                    .accessibilityLabel("Context window for \(entry.model)")
                    .accessibilityValue(profile.contextWindowLabel)
                effortControl(entry)
                    .frame(width: Metrics.effort, alignment: .leading)
            }
            .padding(.vertical, AQDesign.Space.compact)
            .frame(minHeight: AQDesign.rowHeight)
            .background(
                RowHighlight(isSelected: false, isHovering: hoveredRow == entry.id)
            )
            .onHover { hovering in
                if hovering {
                    hoveredRow = entry.id
                } else if hoveredRow == entry.id {
                    hoveredRow = nil
                }
            }
        }
    }

    /// The effort menu, on the models that take one. A model the catalogue
    /// says takes none says so; a model the catalogue does not know at all
    /// reads "Unknown" rather than being told it has no such setting.
    @ViewBuilder
    private func effortControl(_ entry: ModelListEntry) -> some View {
        if entry.profile.supportsReasoningEffort {
            Picker("Reasoning effort for \(entry.model)", selection: effortBinding(entry)) {
                ForEach(ReasoningEffort.allCases) { effort in
                    Text(effort.title).tag(effort)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Reasoning effort for \(entry.model)")
        } else {
            Text(isCurated(entry.model) ? "Not supported" : "Unknown")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .lineLimit(1)
                .accessibilityLabel("Reasoning effort for \(entry.model)")
                .accessibilityValue(isCurated(entry.model) ? "Not supported" : "Unknown")
        }
    }

    /// Whether the app ships any curated data for this model id.
    private func isCurated(_ model: String) -> Bool {
        ModelProfile.curatedTable[model.lowercased()] != nil
    }

    // MARK: - Bindings

    private func enabledBinding(_ entry: ModelListEntry) -> Binding<Bool> {
        Binding(
            get: { preferences.isEnabled(providerID: entry.providerID, model: entry.model) },
            set: { preferences.setEnabled($0, providerID: entry.providerID, model: entry.model) }
        )
    }

    private func effortBinding(_ entry: ModelListEntry) -> Binding<ReasoningEffort> {
        Binding(
            get: {
                preferences.profile(providerID: entry.providerID, model: entry.model)
                    .reasoningEffort
            },
            set: {
                preferences.setReasoningEffort(
                    $0,
                    providerID: entry.providerID,
                    model: entry.model
                )
            }
        )
    }

    /// Column widths, so the labels and the cells line up.
    private enum Metrics {
        static let speed: CGFloat = 78
        static let intelligence: CGFloat = 92
        static let context: CGFloat = 76
        static let effort: CGFloat = 140
    }
}

/// The five-dot rating for one axis. An unrated model reads "Unknown" rather
/// than five empty dots, so it cannot be mistaken for a rated zero.
private struct RatingDots: View {
    let rating: ModelRating?
    let label: String

    var body: some View {
        if let rating {
            HStack(spacing: AQDesign.Space.compact) {
                ForEach(1...ModelRating.scale, id: \.self) { index in
                    Circle()
                        .fill(
                            index <= rating.rawValue
                                ? AQDesign.ColorToken.textSecondary
                                : AQDesign.ColorToken.tileStroke
                        )
                        .frame(width: 5, height: 5)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(rating.title)
        } else {
            Text("Unknown")
                .font(AQDesign.TypeToken.caption)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .accessibilityLabel(label)
                .accessibilityValue("Unknown")
        }
    }
}
