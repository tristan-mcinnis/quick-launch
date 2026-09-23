import SwiftUI

/// ⌥⌘3 Activity: what the Chief of Staff did one day, grouped as read,
/// proposed, reviewed, ran, closed on their own, and failed, from
/// `cos activity --json`. ⌥⌘[ and ⌥⌘] move a day.
struct ChiefOfStaffActivityPage: View {
    @Bindable var model: ChiefOfStaffModel

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.sm) {
            HStack(spacing: House.Spacing.xs) {
                dayButton("chevron.left", label: "Previous day", delta: -1)
                Text(dayTitle)
                    .font(House.TypeToken.label)
                    .foregroundStyle(House.ColorToken.textPrimary)
                dayButton("chevron.right", label: "Next day", delta: 1)
                    .disabled(model.activityDay == nil)
                Spacer(minLength: House.Spacing.xs)
                KeyHint(label: "Day", keys: ["⌥", "⌘", "[", "]"])
            }
            if let problem = model.viewProblem {
                PageNote(text: problem)
            } else if let activity = model.activity {
                if activity.events.isEmpty {
                    PageNote(text: activity.runs.map { "\($0) runs, and nothing to show that day." } ?? "Nothing happened that day.")
                } else if let runs = activity.runs {
                    PageNote(text: "\(runs) runs")
                }
                ForEach(CosActivity.groups, id: \.kind) { group in
                    let events = activity.events(group.kind)
                    if !events.isEmpty {
                        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                            SectionHeader(title: group.title, count: events.count) { EmptyView() }
                            ForEach(events) { event in
                                ActivityRow(event: event, isFailure: group.kind == "failed")
                            }
                        }
                    }
                }
            } else {
                PageNote(text: "Reading…")
            }
        }
    }

    private var dayTitle: String {
        guard let day = model.activityDay, let date = ChiefOfStaffDates.day(day) else { return "Today" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func dayButton(_ symbol: String, label: String, delta: Int) -> some View {
        Button {
            model.moveActivityDay(delta)
        } label: {
            Image(systemName: symbol)
                .font(House.TypeToken.caption)
                .foregroundStyle(House.ColorToken.textSecondary)
                .frame(width: House.Control.keyCap, height: House.Control.keyCap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct ActivityRow: View {
    let event: CosActivityEvent
    var isFailure = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            if isFailure { StatusDot(color: House.ColorToken.danger) }
            Text(event.clock)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .monospacedDigit()
                .frame(minWidth: House.Spacing.xxxl, alignment: .leading)
            Text(event.text)
                .font(House.TypeToken.bodySmall)
                .foregroundStyle(House.ColorToken.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: House.Control.chip)
        .accessibilityElement(children: .combine)
    }
}

/// ⌥⌘4 Artifacts: what Prepare made, newest first. Return (or ⌘O) opens
/// the focused file in its default app; ⌘D discusses it. Nothing opens by
/// itself.
struct ChiefOfStaffArtifactsPage: View {
    @Bindable var model: ChiefOfStaffModel
    let hasKeyboard: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SectionHeader(title: "Artifacts", count: model.artifacts.count) { EmptyView() }
            if let problem = model.viewProblem {
                PageNote(text: problem)
            } else if model.artifacts.isEmpty {
                PageNote(text: "Nothing prepared yet. A card's Prepare action puts its drafts here.")
            }
            ForEach(model.artifacts) { artifact in
                let isFocused = hasKeyboard && model.focusedCardID == artifact.id
                HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                    Image(systemName: "doc.text")
                        .font(House.TypeToken.caption)
                        .foregroundStyle(House.ColorToken.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: House.Spacing.xxs / 2) {
                        Text(artifact.name)
                            .font(House.TypeToken.label)
                            .foregroundStyle(House.ColorToken.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(detail(artifact))
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: House.Spacing.xs)
                    CardButton(title: "Open", keys: ["↩"], showsKeys: isFocused) {
                        model.focusCard(artifact.id)
                        model.openFocusedFile()
                    }
                    CardButton(title: "Discuss", keys: ["⌘", "D"], showsKeys: isFocused) {
                        model.onDiscuss?(model.discussion(for: artifact))
                    }
                }
                .padding(.horizontal, House.Spacing.xs)
                .frame(minHeight: House.Control.row)
                .background { RowHighlight(isSelected: isFocused, radius: House.Radius.row) }
                .contentShape(Rectangle())
                .onTapGesture { model.focusCard(artifact.id) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(artifact.name)
                .accessibilityAddTraits(isFocused ? .isSelected : [])
            }
        }
    }

    private func detail(_ artifact: CosArtifact) -> String {
        var parts: [String] = []
        if let card = model.proposal(artifact.card) {
            parts.append(card.headline)
        } else if let headline = artifact.headline {
            parts.append(headline)
        }
        if let created = artifact.created { parts.append(created.formatted(.dateTime.month(.abbreviated).day().hour().minute())) }
        return parts.joined(separator: " · ")
    }
}

/// ⌥⌘5 Charter: what the Chief of Staff watches, who matters, what it
/// ignores, its style and what it learned, read only. ⌘N adds a rule; Edit
/// opens the file in the default editor (⌘O), only when asked. Below, the
/// consent rungs, each with Remove (⌘⌫ when focused).
struct ChiefOfStaffCharterPage: View {
    @Bindable var model: ChiefOfStaffModel
    let hasKeyboard: Bool
    var onFocus: (ChiefOfStaffFocus) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.md) {
            HStack(spacing: House.Spacing.sm) {
                CardButton(title: "Add rule", keys: ["⌘", "N"], showsKeys: true, prominent: true) { model.openAddRule() }
                CardButton(title: "Edit charter", keys: ["⌘", "O"], showsKeys: true) { model.openFocusedFile() }
                    .disabled(model.charter?.path == nil)
                Spacer(minLength: 0)
            }
            if model.addRule != nil {
                AddRuleSheet(model: model, onFocus: onFocus)
            }
            if let problem = model.viewProblem {
                PageNote(text: problem)
            }
            if let charter = model.charter {
                // Autonomy is drawn below as the rungs, each with Remove.
                ForEach(charter.sections.filter { $0.key != "autonomy" }) { section in
                    VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                        SectionHeader(title: section.name, count: section.lines.count) { EmptyView() }
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(House.TypeToken.bodySmall)
                                .foregroundStyle(House.ColorToken.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else if model.viewProblem == nil {
                PageNote(text: "Reading…")
            }
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                SectionHeader(title: "Always do", count: model.rungs.count) { EmptyView() }
                if model.rungs.isEmpty {
                    PageNote(text: "Nothing runs without a tap. After a Do it, ⌘Y on the offer adds one here.")
                }
                ForEach(model.rungs) { rung in
                    let isFocused = hasKeyboard && model.focusedCardID == rung.id
                    HStack(spacing: House.Spacing.xs) {
                        Text(ProposalAction(type: rung.type).typeLabel)
                            .font(House.TypeToken.label)
                            .foregroundStyle(House.ColorToken.textPrimary)
                        Text(rung.project == "*" ? "every project" : projectName(rung.project))
                            .font(House.TypeToken.meta)
                            .foregroundStyle(House.ColorToken.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: House.Spacing.xs)
                        CardButton(title: "Remove", keys: ["⌘", "⌫"], showsKeys: isFocused) {
                            model.send(.never(rung: rung.rung))
                        }
                    }
                    .padding(.horizontal, House.Spacing.xs)
                    .frame(minHeight: House.Control.railRow)
                    .background { RowHighlight(isSelected: isFocused, radius: House.Radius.row) }
                    .contentShape(Rectangle())
                    .onTapGesture { model.focusCard(rung.id) }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(isFocused ? .isSelected : [])
                }
            }
        }
    }

    private func projectName(_ slug: String) -> String {
        model.projects.first { $0.slug == slug }?.shortName ?? slug
    }
}

/// ⌘N in the Charter: pick a section, type one line, Return adds it.
struct AddRuleSheet: View {
    @Bindable var model: ChiefOfStaffModel
    var onFocus: (ChiefOfStaffFocus) -> Void = { _ in }
    @FocusState private var focused: Bool

    var body: some View {
        if let draft = model.addRule {
            VStack(alignment: .leading, spacing: House.Spacing.xs) {
                SectionLabel(text: "Add rule")
                HStack(spacing: House.Spacing.xxs) {
                    ForEach(CosCharter.ruleSections, id: \.self) { section in
                        Button {
                            model.addRule?.section = section
                        } label: {
                            Text(section.capitalized)
                                .font(House.TypeToken.meta)
                                .foregroundStyle(draft.section == section ? House.ColorToken.textPrimary : House.ColorToken.textTertiary)
                                .padding(.horizontal, House.Spacing.xs)
                                .frame(height: House.Control.chip)
                                .background { RowHighlight(isSelected: draft.section == section, radius: House.Radius.sm) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(draft.section == section ? .isSelected : [])
                    }
                }
                CardField(prompt: "The rule, in one line", text: textBinding, lines: 1...3)
                    .focused($focused)
                    .onSubmit { model.submitAddRule() }
                HStack(spacing: House.Spacing.xs) {
                    CardButton(title: "Add", keys: ["↩"], showsKeys: true, prominent: true) { model.submitAddRule() }
                    CardButton(title: "Cancel", keys: ["esc"], showsKeys: true) { model.addRule = nil }
                }
            }
            .padding(House.Spacing.sm)
            .raisedCard(radius: AQDesign.cardCornerRadius, fill: AQDesign.ColorToken.raisedSurface)
            .houseShadow(AQDesign.Shadow.card)
            .onAppear { FocusRequest.apply($focused) }
            .onChange(of: focused) { _, now in if now { onFocus(.form) } }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Add rule")
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { model.addRule?.text ?? "" }, set: { model.addRule?.text = $0 })
    }
}

/// One quiet line on a page: an empty state or why it could not be read.
struct PageNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
