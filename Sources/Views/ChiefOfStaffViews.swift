import SwiftUI

/// Where the keyboard is inside the Chief of Staff panel, for the window's
/// key routing.
enum ChiefOfStaffFocus: Sendable, Equatable {
    /// On a card or row (arrows, ⌘↩, ⌘E, ⌘L, ⌘⌫, ⌘R).
    case cards
    /// In a card's Edit fields.
    case editing
    /// In the New task sheet or the project picker: typing is the field's.
    case form
}

/// The pinned Chief of Staff conversation above its thread: the status line
/// (health, filter, view), then the List (DECIDE, TODAY, WAITING ON OTHERS,
/// PROJECTS, LATER, FYI) or the Board. The List scrolls within `maxHeight`;
/// the Board takes the space it is given. The panel takes the keyboard when
/// a card is focused, so typed keys never reach the draft.
struct ChiefOfStaffPanel: View {
    @Bindable var model: ChiefOfStaffModel
    /// The most the List may take before it scrolls.
    let maxHeight: CGFloat
    /// The keyboard is on the cards (the window's `Focus.cards`).
    let hasKeyboard: Bool
    var onFocus: (ChiefOfStaffFocus) -> Void = { _ in }

    @State private var contentHeight: CGFloat = 0
    @FocusState private var panelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            ChiefOfStaffStatusBar(model: model)
            switch model.viewMode {
            case .list:
                listView
            case .board:
                sheets
                ChiefOfStaffBoard(model: model, hasKeyboard: hasKeyboard, onFocus: onFocus)
            }
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.top, House.Spacing.xs)
        .padding(.bottom, House.Spacing.xs)
        .frame(maxWidth: model.viewMode == .list ? QuickAIView.threadColumnWidth + House.Spacing.lg * 2 : .infinity)
        .frame(maxWidth: .infinity)
        .focusable(hasKeyboard && !model.isEditingFocusedCard && !(model.laterMenu?.isPicking ?? false))
        .focusEffectDisabled()
        .focused($panelFocused)
        .onChange(of: hasKeyboard) { _, has in
            if has, !model.isEditingFocusedCard { FocusRequest.apply($panelFocused) }
        }
        .onAppear {
            if hasKeyboard, !model.isEditingFocusedCard { FocusRequest.apply($panelFocused) }
        }
        .onChange(of: panelFocused) { _, focused in
            if focused { onFocus(.cards) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chief of Staff")
    }

    /// Health detail, the project picker, New task, and the last notice.
    /// In the List they scroll with the sections, so the panel never grows
    /// past its share of the window.
    @ViewBuilder
    private var sheets: some View {
        if model.isHealthDetailShown, let health = model.health {
            HealthDetail(proposal: health)
        }
        if model.projectPicker != nil {
            ProjectPickerView(model: model, onFocus: onFocus)
        }
        if model.newTask != nil {
            NewTaskSheet(model: model, onFocus: onFocus)
        }
        if let notice = model.notice {
            Text(notice)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(2)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    // MARK: List

    private var listView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: House.Spacing.md) {
                    sheets
                    decideSection
                    todaySection
                    CollapsedSection(
                        title: "Waiting on others",
                        count: model.waitingOnOthers.count,
                        isExpanded: model.expanded.contains(.waiting)
                    ) { model.toggleSection(.waiting) } rows: {
                        ForEach(model.waitingOnOthers) { proposal in
                            OneLineRow(proposal: proposal, detail: waitingDetail(proposal), isFocused: isFocused(proposal))
                                .id(proposal.id)
                                .onTapGesture { model.focusCard(proposal.id) }
                        }
                    }
                    ProjectsStrip(model: model)
                    CollapsedSection(
                        title: "Later",
                        count: model.later.count,
                        isExpanded: model.expanded.contains(.later)
                    ) { model.toggleSection(.later) } rows: {
                        ForEach(model.later) { proposal in
                            OneLineRow(
                                proposal: proposal,
                                detail: proposal.snoozedUntil.map { ChiefOfStaffDates.returnPhrase($0, now: model.now) } ?? "",
                                isFocused: isFocused(proposal),
                                action: ("Bring back", ["⌘", "R"], { model.send(.reopen(id: proposal.id)) })
                            )
                            .id(proposal.id)
                            .onTapGesture { model.focusCard(proposal.id) }
                        }
                    }
                    CollapsedSection(
                        title: "FYI",
                        count: model.fyi.count,
                        isExpanded: model.expanded.contains(.fyi)
                    ) { model.toggleSection(.fyi) } rows: {
                        ForEach(model.fyi) { proposal in
                            OneLineRow(
                                proposal: proposal,
                                detail: proposal.source,
                                isFocused: isFocused(proposal),
                                action: ("Got it", ["⌘", "↩"], { model.send(.doIt(id: proposal.id)) })
                            )
                            .id(proposal.id)
                            .onTapGesture { model.focusCard(proposal.id) }
                        }
                    }
                }
                // Room for the card shadow and the focus stroke.
                .padding(.vertical, House.Spacing.xxs)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maxHeight))
            .onChange(of: model.focusedCardID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: House.Motion.select)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var decideSection: some View {
        if !model.decide.isEmpty {
            VStack(alignment: .leading, spacing: House.Spacing.sm) {
                SectionHeader(title: "Decide", count: model.decide.count) {
                    if model.decide.count > ChiefOfStaffModel.decideVisibleLimit {
                        Button(model.expanded.contains(.decide) ? "Show fewer" : "Show all \(model.decide.count)") {
                            model.toggleSection(.decide)
                        }
                        .buttonStyle(.plain)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                    }
                }
                ForEach(model.visibleDecide) { proposal in
                    card(proposal).id(proposal.id)
                }
            }
        }
    }

    @ViewBuilder
    private var todaySection: some View {
        if !model.today.isEmpty {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                SectionHeader(title: "Today", count: model.today.count) {
                    if let armed = model.bulkArmed {
                        Text("Press ⇧⌘↩ again to run \(armed.count)")
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textPrimary)
                    } else {
                        KeyHint(label: "Do all", keys: ["⇧", "⌘", "↩"])
                    }
                }
                ForEach(model.today) { proposal in
                    Group {
                        if model.cards[proposal.id]?.isEditing == true {
                            card(proposal)
                        } else {
                            TodayRow(
                                proposal: proposal,
                                state: model.cards[proposal.id] ?? ProposalCardState(),
                                isFocused: isFocused(proposal),
                                isArmed: model.bulkArmed?.contains(proposal.id) == true,
                                laterMenu: model.laterMenu,
                                onDo: { model.send(.doIt(id: proposal.id)) },
                                onLaterChoice: { model.chooseLater($0) },
                                onLaterPickText: model.setLaterPickText
                            )
                            .onTapGesture { model.focusCard(proposal.id) }
                        }
                    }
                    .id(proposal.id)
                }
            }
        }
    }

    private func isFocused(_ proposal: Proposal) -> Bool {
        hasKeyboard && model.focusedCardID == proposal.id
    }

    private func waitingDetail(_ proposal: Proposal) -> String {
        let who = proposal.sender.isEmpty ? proposal.source : proposal.sender
        guard let created = proposal.created else { return who }
        return "\(who) · since \(created.formatted(.relative(presentation: .named)))"
    }

    private func card(_ proposal: Proposal) -> some View {
        let state = model.cards[proposal.id] ?? ProposalCardState()
        return ProposalCard(
            proposal: proposal,
            state: state,
            isFocused: isFocused(proposal) || (state.isEditing && model.focusedCardID == proposal.id),
            editFocusRequest: model.focusedCardID == proposal.id ? model.editFocusRequest : 0,
            laterMenu: model.laterMenu,
            now: model.now,
            onDo: { model.send(.doIt(id: proposal.id)) },
            onEdit: { model.beginEdit(proposal) },
            onLater: {
                model.focusCard(proposal.id)
                model.openLaterMenu()
            },
            onNo: { model.send(.no(id: proposal.id)) },
            onLaterChoice: { model.chooseLater($0) },
            onLaterPickText: model.setLaterPickText,
            onRun: { model.send(.runEdit(id: proposal.id)) },
            onCancel: {
                model.cancelEdit(proposal.id)
                onFocus(.cards)
            },
            onEditFocus: { editing in
                if editing {
                    model.focusedCardID = proposal.id
                    onFocus(.editing)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { model.focusCard(proposal.id) }
    }
}

// MARK: - Status bar

/// The line under the window header: health as a status dot and a word
/// (⌘I opens the detail), the project filter chip, and the view (⌥⌘1 List,
/// ⌥⌘2 Board). The conversation's other keys are in its footer.
struct ChiefOfStaffStatusBar: View {
    @Bindable var model: ChiefOfStaffModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: House.Spacing.sm) { health; Spacer(minLength: House.Spacing.xs); controls }
            VStack(alignment: .leading, spacing: House.Spacing.xs) { health; HStack(spacing: House.Spacing.sm) { controls } }
        }
    }

    private var health: some View {
        Button {
            model.isHealthDetailShown.toggle()
        } label: {
            HStack(spacing: House.Spacing.xs) {
                StatusDot(color: model.health == nil ? House.ColorToken.success : House.ColorToken.danger)
                Text(model.isPaused ? "Paused · \(model.healthLine)" : model.healthLine)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.health == nil)
        .help(model.health == nil ? "Every background job is running" : "Show the failing jobs (⌘I)")
        .accessibilityLabel(model.health == nil ? "Jobs running" : "Jobs failing: \(model.healthLine)")
    }

    @ViewBuilder
    private var controls: some View {
        if let project = model.filteredProject {
            Button {
                model.setProjectFilter(nil)
            } label: {
                HouseChip(text: project.shortName, icon: "xmark")
            }
            .buttonStyle(.plain)
            .help("Show every project (⇧⌘P)")
            .accessibilityLabel("Filter: \(project.shortName). Clear")
        }
        // Never truncated: the health line gives way first, then the row wraps.
        ViewSwitch(mode: model.viewMode) { model.viewMode = $0 }
            .fixedSize()
    }
}

/// List ⌥⌘1 and Board ⌥⌘2, the current one in ink.
struct ViewSwitch: View {
    let mode: ChiefOfStaffModel.ViewMode
    let onChange: (ChiefOfStaffModel.ViewMode) -> Void

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            item("List", "1", .list)
            item("Board", "2", .board)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }

    private func item(_ title: String, _ key: String, _ value: ChiefOfStaffModel.ViewMode) -> some View {
        Button {
            onChange(value)
        } label: {
            HStack(spacing: House.Spacing.xxs) {
                Text(title)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(mode == value ? House.ColorToken.textPrimary : House.ColorToken.textTertiary)
                KeyCapGroup(keys: ["⌥", "⌘", key])
            }
            .padding(.horizontal, House.Spacing.xs)
            .frame(height: House.Control.chip)
            .background { RowHighlight(isSelected: mode == value, radius: House.Radius.sm) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
    }
}

/// ⌘I: which jobs are failing, as the health card says.
struct HealthDetail: View {
    let proposal: Proposal

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            Text(proposal.message)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !proposal.red.isEmpty {
                Text(proposal.red.joined(separator: "\n"))
                    .font(House.TypeToken.code)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous).fill(House.ColorToken.surfaceTint))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sections and rows

/// A section label, its count, and anything on its right.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            SectionLabel(text: title)
            Text("\(count)")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .monospacedDigit()
            Spacer(minLength: House.Spacing.xs)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

/// A collapsed section: its label and count, a click (or focusing a card in
/// it) opens it. Hidden when empty.
struct CollapsedSection<Rows: View>: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder var rows: Rows

    var body: some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                Button(action: onToggle) {
                    HStack(spacing: House.Spacing.xs) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(House.TypeToken.caption)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .frame(width: House.Spacing.sm)
                            .accessibilityHidden(true)
                        SectionLabel(text: title)
                        Text("\(count)")
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(count)")
                .accessibilityValue(isExpanded ? "Open" : "Closed")
                if isExpanded { rows }
            }
        }
    }
}

/// A TODAY row: source, headline, the actions as chips, and Do it; the
/// focused row shows its keys. `Control.row` high at least.
struct TodayRow: View {
    let proposal: Proposal
    @Bindable var state: ProposalCardState
    let isFocused: Bool
    var isArmed = false
    var laterMenu: ChiefOfStaffModel.LaterMenu?
    let onDo: () -> Void
    var onLaterChoice: (LaterChoice) -> Void = { _ in }
    var onLaterPickText: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                VStack(alignment: .leading, spacing: House.Spacing.xxs / 2) {
                    Text(proposal.headline)
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: House.Spacing.xs)
                if state.isRunning {
                    Text("Running…")
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                } else {
                    CardButton(
                        title: proposal.isNotice ? "Got it" : "Do it",
                        keys: ["⌘", "↩"],
                        showsKeys: isFocused,
                        prominent: isFocused,
                        action: onDo
                    )
                }
            }
            if isFocused {
                HStack(spacing: House.Spacing.sm) {
                    if !proposal.isNotice { KeyHint(label: "Edit", keys: ["⌘", "E"]) }
                    KeyHint(label: "Later", keys: ["⌘", "L"])
                    KeyHint(label: "No", keys: ["⌘", "⌫"])
                }
            }
            if let outcome = state.outcome, !outcome.isEmpty, !state.isRunning {
                OutcomeLines(lines: outcome)
            }
            if let laterMenu, laterMenu.proposalID == proposal.id {
                LaterMenuView(menu: laterMenu, onChoice: onLaterChoice, onPickText: onLaterPickText)
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .padding(.vertical, House.Spacing.xs)
        .frame(minHeight: House.Control.row)
        .background { RowHighlight(isSelected: isFocused || isArmed, radius: House.Radius.row) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(proposal.source): \(proposal.headline)")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    /// The source, the first action ("Finalise the photos, +2 more"), and
    /// the due phrase.
    private var detail: String {
        var parts = [proposal.source].filter { !$0.isEmpty }
        // Not when it only repeats the headline.
        if let actions = proposal.actionSummary, !actions.hasPrefix(proposal.headline) { parts.append(actions) }
        if let due = proposal.due, let phrase = ChiefOfStaffDates.relativeDue(due) { parts.append(phrase) }
        return parts.joined(separator: " · ")
    }
}

/// One line for a card in a collapsed section: headline, detail, and one
/// action (Bring back, Got it) with its keys while focused.
struct OneLineRow: View {
    let proposal: Proposal
    let detail: String
    let isFocused: Bool
    var action: (title: String, keys: [String], run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            Text(proposal.headline)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: House.Spacing.xs)
            Text(detail)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let action {
                CardButton(title: action.title, keys: action.keys, showsKeys: isFocused, action: action.run)
            }
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(minHeight: House.Control.railRow)
        .background { RowHighlight(isSelected: isFocused, radius: House.Radius.row) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }
}

/// PROJECTS: one row per active project, not cards. A risk dot and word,
/// the name and phase, the next date, open tasks and waiting cards. A click
/// filters the conversation to that project; again clears it.
struct ProjectsStrip: View {
    @Bindable var model: ChiefOfStaffModel

    var body: some View {
        if !model.projects.isEmpty {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                SectionHeader(title: "Projects", count: model.projects.count) {
                    KeyHint(label: "Filter", keys: ["⇧", "⌘", "P"])
                }
                ForEach(model.projects) { project in
                    ProjectRow(project: project, isSelected: model.projectFilter == project.slug, now: model.now) {
                        model.setProjectFilter(model.projectFilter == project.slug ? nil : project.slug)
                    }
                }
            }
        }
    }
}

struct ProjectRow: View {
    let project: CosProject
    let isSelected: Bool
    var now: Date = .now
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                StatusDot(color: riskColor)
                Text(project.shortName)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: House.Spacing.xs)
                Text(detail)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, House.Spacing.xs)
            .frame(minHeight: House.Control.railRow)
            .background { RowHighlight(isSelected: isSelected, radius: House.Radius.row) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Show every project" : project.name)
        .accessibilityLabel("\(project.shortName), \(riskWord), \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The dot is never alone: the word is in the detail and the label.
    private var riskColor: Color {
        switch project.risk {
        case "red": House.ColorToken.danger
        case "amber": House.ColorToken.warning
        default: House.ColorToken.success
        }
    }

    private var riskWord: String {
        switch project.risk {
        case "red": "at risk"
        case "amber": "watch"
        default: "on track"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let phase = project.phase, !phase.isEmpty { parts.append(phase) }
        if project.overdue > 0 {
            parts.append("\(project.overdue) late")
        } else if let next = project.nextDue, let phrase = ChiefOfStaffDates.relativeDue(next, now: now) {
            parts.append("next \(phrase.replacingOccurrences(of: "by ", with: ""))")
        }
        parts.append("\(project.openTasks) open")
        if project.waitingCards > 0 { parts.append("\(project.waitingCards) waiting") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Board

/// ⌘2: Decide, Today, Waiting, Later, Done this week, as columns of compact
/// tiles. ←→ between columns, ↑↓ within one; ⌘↩, ⌘L, ⌘⌫ act on the
/// focused tile. With a project filtered, ⇧⌘T adds its task lanes.
struct ChiefOfStaffBoard: View {
    @Bindable var model: ChiefOfStaffModel
    let hasKeyboard: Bool
    var onFocus: (ChiefOfStaffFocus) -> Void = { _ in }

    /// A column is never narrower than this; a narrow window scrolls the
    /// board sideways instead of squeezing the tiles.
    static let columnWidth = House.Layout.chatRail

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: House.Spacing.sm) {
                        ForEach(ChiefOfStaffModel.Column.allCases) { column in
                            columnView(column)
                        }
                    }
                    .padding(.vertical, House.Spacing.xxs)
                }
                .onChange(of: model.focusedCardID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: House.Motion.select)) { proxy.scrollTo(id) }
                }
            }
            if model.showsTasks {
                BoardTasks(model: model)
            }
        }
    }

    private func columnView(_ column: ChiefOfStaffModel.Column) -> some View {
        let cards = model.column(column)
        return VStack(alignment: .leading, spacing: House.Spacing.xs) {
            SectionHeader(title: column.title, count: cards.count) { EmptyView() }
            ForEach(cards) { proposal in
                BoardTile(
                    proposal: proposal,
                    state: model.cards[proposal.id] ?? ProposalCardState(),
                    isFocused: hasKeyboard && model.focusedCardID == proposal.id,
                    now: model.now
                )
                .id(proposal.id)
                .onTapGesture { model.focusCard(proposal.id) }
                if let menu = model.laterMenu, menu.proposalID == proposal.id {
                    LaterMenuView(menu: menu, onChoice: { model.chooseLater($0) }, onPickText: model.setLaterPickText)
                }
            }
        }
        .frame(width: Self.columnWidth, alignment: .topLeading)
    }
}

/// One card on the board: source and due, headline, and its status or keys.
struct BoardTile: View {
    let proposal: Proposal
    @Bindable var state: ProposalCardState
    let isFocused: Bool
    var now: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            HStack(spacing: House.Spacing.xxs) {
                Text(proposal.source)
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let when = when {
                    Text(when)
                        .font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .lineLimit(1)
                }
            }
            Text(proposal.headline)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if state.isRunning {
                Text("Running…")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
            } else if isFocused {
                keys
            }
        }
        .padding(House.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.row, style: .continuous)
                .fill(House.ColorToken.surfaceRaised)
                .houseShadow(AQDesign.Shadow.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.row, style: .continuous)
                .strokeBorder(isFocused ? House.ColorToken.strokeStrong : House.ColorToken.stroke, lineWidth: House.hairline)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(proposal.statusWord): \(proposal.source), \(proposal.headline)")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private var when: String? {
        if proposal.status == .later, let back = proposal.snoozedUntil {
            return ChiefOfStaffDates.returnPhrase(back, now: now).replacingOccurrences(of: "back ", with: "")
        }
        return proposal.due.flatMap { ChiefOfStaffDates.relativeDue($0, now: now) }
    }

    @ViewBuilder
    private var keys: some View {
        if proposal.isWaiting {
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                KeyHint(label: proposal.isNotice ? "Got it" : "Do it", keys: ["⌘", "↩"])
                KeyHint(label: "Later", keys: ["⌘", "L"])
                KeyHint(label: "No", keys: ["⌘", "⌫"])
            }
        } else if proposal.canBringBack {
            KeyHint(label: "Bring back", keys: ["⌘", "R"])
        }
    }
}

/// ⇧⌘T on the board: the filtered project's canonical task lanes, read only.
struct BoardTasks: View {
    @Bindable var model: ChiefOfStaffModel

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SectionHeader(title: "Tasks", count: model.tasks.count) {
                KeyHint(label: "Hide", keys: ["⇧", "⌘", "T"])
            }
            if model.projectFilter == nil {
                Text("Pick a project (⇧⌘P) to see its tasks.")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
            } else if let problem = model.tasksProblem {
                Text(problem)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
            }
            ForEach(lanes, id: \.lane) { lane in
                Text(lane.lane.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .padding(.top, House.Spacing.xxs)
                ForEach(lane.tasks) { task in
                    HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                        Text(task.title)
                            .font(House.TypeToken.bodySmall)
                            .foregroundStyle(House.ColorToken.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: House.Spacing.xs)
                        if let due = task.due, let phrase = ChiefOfStaffDates.relativeDue(due, now: model.now) {
                            Text(phrase)
                                .font(House.TypeToken.meta)
                                .foregroundStyle(House.ColorToken.textTertiary)
                        }
                    }
                    .frame(minHeight: House.Control.chip)
                }
            }
        }
    }

    private var lanes: [(lane: String, tasks: [CosTask])] {
        var order: [String] = []
        var grouped: [String: [CosTask]] = [:]
        for task in model.tasks {
            if grouped[task.lane] == nil { order.append(task.lane) }
            grouped[task.lane, default: []].append(task)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}

// MARK: - New task and project picker

/// ⌘N: a task title, a project (fuzzy), and an optional due day. Return
/// moves on, ⌘↩ adds, esc cancels. `cos add` writes the canonical tree.
struct NewTaskSheet: View {
    @Bindable var model: ChiefOfStaffModel
    var onFocus: (ChiefOfStaffFocus) -> Void = { _ in }

    enum Field: Hashable {
        case title
        case project
        case due
    }

    @FocusState private var field: Field?

    var body: some View {
        if let draft = model.newTask {
            VStack(alignment: .leading, spacing: House.Spacing.xs) {
                SectionLabel(text: "New task")
                CardField(prompt: "Task", text: binding(\.title), lines: 1...3)
                    .focused($field, equals: .title)
                    .onSubmit { field = .project }
                CardField(prompt: "Project", text: projectBinding, lines: 1...1)
                    .focused($field, equals: .project)
                    .onSubmit { pickProject(); field = .due }
                    .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                        moveProject(press.key == .upArrow ? -1 : 1)
                        return .handled
                    }
                if field == .project, draft.projectSlug == nil, !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestions.prefix(Self.suggestionCount).enumerated()), id: \.element.id) { index, project in
                            Button {
                                model.newTask?.projectIndex = index
                                pickProject()
                                field = .due
                            } label: {
                                Text(project.shortName)
                                    .font(House.TypeToken.bodySmall)
                                    .foregroundStyle(House.ColorToken.textPrimary)
                                    .lineLimit(1)
                                    .padding(.horizontal, House.Spacing.xs)
                                    .frame(maxWidth: .infinity, minHeight: House.Control.chip, alignment: .leading)
                                    .background { RowHighlight(isSelected: index == draft.projectIndex, radius: House.Radius.sm) }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                CardField(prompt: "Due (optional): tomorrow, fri, 2026-10-02", text: binding(\.due), lines: 1...1)
                    .focused($field, equals: .due)
                    .onSubmit { model.submitNewTask() }
                if let problem = draft.problem {
                    Text(problem)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textPrimary)
                }
                HStack(spacing: House.Spacing.xs) {
                    CardButton(title: "Add", keys: ["⌘", "↩"], showsKeys: true, prominent: true) { model.submitNewTask() }
                    CardButton(title: "Cancel", keys: ["esc"], showsKeys: true) { model.newTask = nil }
                }
            }
            .padding(House.Spacing.sm)
            .raisedCard(radius: AQDesign.cardCornerRadius, fill: AQDesign.ColorToken.raisedSurface)
            .houseShadow(AQDesign.Shadow.card)
            .onAppear { field = .title }
            .onChange(of: field) { _, now in if now != nil { onFocus(.form) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("New task")
        }
    }

    static let suggestionCount = 5

    private var suggestions: [CosProject] { model.matchingProjects(model.newTask?.projectQuery ?? "") }

    private func binding(_ path: WritableKeyPath<ChiefOfStaffModel.NewTask, String>) -> Binding<String> {
        Binding(
            get: { model.newTask?[keyPath: path] ?? "" },
            set: { model.newTask?[keyPath: path] = $0 }
        )
    }

    /// Typing a project clears the one picked, so the list comes back.
    private var projectBinding: Binding<String> {
        Binding(
            get: { model.newTask?.projectQuery ?? "" },
            set: {
                model.newTask?.projectQuery = $0
                model.newTask?.projectSlug = nil
                model.newTask?.projectIndex = 0
            }
        )
    }

    private func moveProject(_ delta: Int) {
        let count = min(suggestions.count, Self.suggestionCount)
        guard count > 0, let index = model.newTask?.projectIndex else { return }
        model.newTask?.projectIndex = ListSelection.wrappedIndex(index, by: delta, count: count)
    }

    private func pickProject() {
        guard let draft = model.newTask, draft.projectSlug == nil else { return }
        let list = Array(suggestions.prefix(Self.suggestionCount))
        guard list.indices.contains(draft.projectIndex) else { return }
        model.newTask?.projectSlug = list[draft.projectIndex].slug
        model.newTask?.projectQuery = list[draft.projectIndex].shortName
    }
}

/// ⇧⌘P: filter the conversation to one project. Type to narrow, ↑↓, Return.
struct ProjectPickerView: View {
    @Bindable var model: ChiefOfStaffModel
    var onFocus: (ChiefOfStaffFocus) -> Void = { _ in }
    @FocusState private var focused: Bool

    var body: some View {
        if let picker = model.projectPicker {
            let rows = rows(picker.query)
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                CardField(prompt: "Filter by project", text: queryBinding, lines: 1...1)
                    .focused($focused)
                    .onSubmit { pick(rows, at: picker.index) }
                    .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                        guard !rows.isEmpty else { return .handled }
                        model.projectPicker?.index = ListSelection.wrappedIndex(
                            picker.index, by: press.key == .upArrow ? -1 : 1, count: rows.count
                        )
                        return .handled
                    }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, project in
                    Button {
                        pick(rows, at: index)
                    } label: {
                        Text(project?.shortName ?? "All projects")
                            .font(House.TypeToken.label)
                            .foregroundStyle(House.ColorToken.textPrimary)
                            .lineLimit(1)
                            .padding(.horizontal, House.Spacing.xs)
                            .frame(maxWidth: .infinity, minHeight: House.Control.railRow, alignment: .leading)
                            .background { RowHighlight(isSelected: index == picker.index) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(index == picker.index ? .isSelected : [])
                }
            }
            .padding(House.Spacing.xs)
            .raisedCard(radius: AQDesign.cardCornerRadius, fill: AQDesign.ColorToken.raisedSurface)
            .houseShadow(AQDesign.Shadow.card)
            .onAppear { FocusRequest.apply($focused) }
            .onChange(of: focused) { _, now in if now { onFocus(.form) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filter by project")
        }
    }

    /// "All projects" first while nothing is typed, then the matches.
    private func rows(_ query: String) -> [CosProject?] {
        let matches = Array(model.matchingProjects(query).prefix(8)).map(Optional.some)
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? [nil] + matches : matches
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { model.projectPicker?.query ?? "" },
            set: {
                model.projectPicker?.query = $0
                model.projectPicker?.index = 0
            }
        )
    }

    private func pick(_ rows: [CosProject?], at index: Int) {
        guard rows.indices.contains(index) else { return }
        model.setProjectFilter(rows[index]?.slug)
    }
}

// MARK: - History

/// The history above the chat, inside the thread's scroll: decided cards
/// collapsed to one line each (a click opens one), and chat turns another
/// surface recorded (`cos ask`) as normal chat. The turns this app asked
/// follow as the chat's own thread.
struct ChiefOfStaffHistory: View {
    let entries: [ChiefOfStaffThread.EarlierEntry]
    var problem: String?
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            if let problem {
                HStack(spacing: House.Spacing.xs) {
                    StatusDot(color: House.ColorToken.danger)
                    Text(problem)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if !entries.isEmpty {
                SectionLabel(text: "Earlier")
            }
            ForEach(entries) { entry in
                switch entry {
                case .item(let item):
                    row(item)
                case .closedOnTheirOwn(let proposals):
                    closedLine(proposals)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "7 closed on their own": one quiet line; a click lists them.
    @ViewBuilder
    private func closedLine(_ proposals: [Proposal]) -> some View {
        let key = "closed-on-their-own"
        Button {
            if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        } label: {
            HStack(spacing: House.Spacing.xs) {
                StatusDot(color: House.ColorToken.textTertiary)
                Text("\(proposals.count) closed on their own")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                Image(systemName: expanded.contains(key) ? "chevron.down" : "chevron.right")
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded.contains(key) ? "Open" : "Closed")
        if expanded.contains(key) {
            ForEach(proposals) { proposal in
                DecidedProposalLine(proposal: proposal) {}
                    .padding(.leading, House.Spacing.sm)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ChiefOfStaffThreadItem) -> some View {
        switch item {
        case .proposal(_, let proposal):
            if expanded.contains(proposal.id) {
                DecidedProposalDetail(proposal: proposal) { expanded.remove(proposal.id) }
            } else {
                DecidedProposalLine(proposal: proposal) { expanded.insert(proposal.id) }
            }
        case .chat(_, let fromUser, let text, _, _):
            if fromUser {
                Text(text)
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, House.Spacing.sm)
                    .padding(.vertical, House.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: House.Radius.pill, style: .continuous)
                            .fill(House.ColorToken.chipFill)
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("You: \(text)")
            } else {
                MarkdownTextView(markdown: text, isStreaming: false, scrolls: false, instanceID: "cos-\(item.id)")
                    .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .leading)
            }
        case .verdict:
            EmptyView()
        }
    }
}

/// A decided card in one line: its status dot and word, the source, the
/// headline, what its actions did, and the time.
struct DecidedProposalLine: View {
    let proposal: Proposal
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                StatusDot(color: DecidedProposalLine.tint(proposal))
                Text(proposal.statusWord)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Text(proposal.source.isEmpty ? proposal.headline : "\(proposal.source) · \(proposal.headline)")
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: House.Spacing.xs)
                if let results = DecidedProposalLine.resultSummary(proposal) {
                    Text(results)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                if let created = proposal.created {
                    Text(created, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(proposal.headline)
        .accessibilityLabel("\(proposal.statusWord): \(proposal.source), \(proposal.headline)")
        .accessibilityHint("Shows the whole card")
    }

    /// Done with every action OK is the one success; a failure is danger;
    /// everything else is quiet ink. The word always says it too.
    static func tint(_ proposal: Proposal) -> Color {
        if proposal.results.contains(where: { !$0.ok }) { return House.ColorToken.danger }
        return proposal.status == .done ? House.ColorToken.success : House.ColorToken.textTertiary
    }

    /// "2 OK", "1 OK, 1 FAIL", or nil when nothing ran.
    static func resultSummary(_ proposal: Proposal) -> String? {
        guard !proposal.results.isEmpty else { return nil }
        let ok = proposal.results.filter(\.ok).count
        let failed = proposal.results.count - ok
        return failed == 0 ? "\(ok) OK" : "\(ok) OK, \(failed) FAIL"
    }
}

/// A decided card opened from its line: the message, the actions and what
/// each did, read only. A click folds it again.
struct DecidedProposalDetail: View {
    let proposal: Proposal
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            DecidedProposalLine(proposal: proposal, onOpen: onClose)
            Text(proposal.message)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            ForEach(Array(proposal.actions.enumerated()), id: \.offset) { index, action in
                ActionLine(number: index + 1, action: action)
            }
            if !proposal.results.isEmpty {
                OutcomeLines(lines: proposal.results.map { OutcomeLine(ok: $0.ok, text: "\($0.type): \($0.detail)") })
            }
        }
        .padding(House.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .fill(House.ColorToken.surfaceTint)
        )
    }
}

/// The pinned conversation's own keys, as caps along its foot, over the
/// composer: they act only here, so they are shown only here.
struct ChiefOfStaffKeyStrip: View {
    let model: ChiefOfStaffModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: House.Spacing.md) { hints(all: true) }
            HStack(spacing: House.Spacing.md) { hints(all: false) }
        }
        .padding(.horizontal, House.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: House.Control.chip, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chief of Staff keys")
    }

    @ViewBuilder
    private func hints(all: Bool) -> some View {
        KeyHint(label: "Cards", keys: ["⌥", "↑"])
        KeyHint(label: "New task", keys: ["⌘", "N"])
        KeyHint(label: "Project", keys: ["⇧", "⌘", "P"])
        if all {
            KeyHint(label: "Do all Today", keys: ["⇧", "⌘", "↩"])
            if model.health != nil { KeyHint(label: "Health", keys: ["⌘", "I"]) }
            if model.viewMode == .board { KeyHint(label: "Tasks", keys: ["⇧", "⌘", "T"]) }
        }
    }
}
