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
            // Only here: today's model calls against their caps.
            if let calls = model.status?.modelCalls {
                HStack(spacing: House.Spacing.xs) {
                    StatusDot(color: calls.pausedUntil == nil ? House.ColorToken.success : House.ColorToken.danger)
                    Text(calls.line)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
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
            if event.didNotFinish { StatusDot(color: House.ColorToken.warning) }
            Text(event.clock)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .monospacedDigit()
                .frame(minWidth: House.Spacing.xxxl, alignment: .leading)
            Text(event.didNotFinish ? "\(event.text) (did not finish)" : event.text)
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

/// ⌥⌘5 Charter: Tristan's policy (watch, people, ignore, style, quiet),
/// read only; the learnings as rows with Forget; the Always do rungs with
/// Remove (⌘⌫ on a focused row). ⌘N adds a learning with its scope; Edit
/// opens the file in the default editor (⌘O), only when asked.
struct ChiefOfStaffCharterPage: View {
    @Bindable var model: ChiefOfStaffModel
    let hasKeyboard: Bool
    var onFocus: (ChiefOfStaffFocus) -> Void = { _ in }

    /// Learnings and rungs are rows of their own below the policy.
    static let hiddenSections: Set<String> = ["learned", "autonomy"]

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
            policy
            learnings
            rungs
        }
    }

    @ViewBuilder
    private var policy: some View {
        if let charter = model.charter {
            ForEach(charter.sections.filter { !Self.hiddenSections.contains($0.key) }) { section in
                CharterSectionView(section: section)
            }
        } else if model.viewProblem == nil {
            PageNote(text: "Reading…")
        }
    }

    private var learnings: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SectionHeader(title: "Learnings", count: model.learnings.count) { EmptyView() }
            if model.learnings.isEmpty {
                PageNote(text: "None yet. More, Less and Add rule each teach one.")
            }
            ForEach(model.learnings) { learning in
                LearningRow(
                    learning: learning,
                    scope: learning.scopeLabel { slug in model.projects.first { $0.slug == slug }?.shortName },
                    isFocused: hasKeyboard && model.focusedCardID == "learning:\(learning.key)",
                    now: model.now
                ) { model.send(.forget(key: learning.key)) }
                .onTapGesture { model.focusCard("learning:\(learning.key)") }
            }
        }
    }

    private var rungs: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            SectionHeader(title: "Always do", count: model.rungs.count) { EmptyView() }
            if model.rungs.isEmpty {
                PageNote(text: "Nothing runs without a tap. After a Do it, ⌘Y on the offer adds one here.")
            }
            ForEach(model.rungs) { rung in
                RungRow(
                    rung: rung,
                    projectName: rung.project == "*" ? "every project" : projectName(rung.project),
                    isFocused: hasKeyboard && model.focusedCardID == rung.id
                ) { model.send(.never(rung: rung.rung)) }
                .onTapGesture { model.focusCard(rung.id) }
            }
        }
    }

    private func projectName(_ slug: String) -> String {
        model.projects.first { $0.slug == slug }?.shortName ?? slug
    }
}

/// One charter section: its label and count, then its lines.
struct CharterSectionView: View {
    let section: CosCharter.Section

    var body: some View {
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
}

/// One learning: its text, then its scope, who taught it and when, and
/// Forget.
struct LearningRow: View {
    let learning: CosLearning
    let scope: String
    let isFocused: Bool
    var now: Date = .now
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            VStack(alignment: .leading, spacing: House.Spacing.xxs / 2) {
                Text(learning.text)
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(detail)
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: House.Spacing.xs)
            CardButton(title: "Forget", keys: ["⌘", "⌫"], showsKeys: isFocused, action: onForget)
        }
        .padding(.horizontal, House.Spacing.xs)
        .padding(.vertical, House.Spacing.xxs)
        .frame(minHeight: House.Control.row)
        .background { RowHighlight(isSelected: isFocused, radius: House.Radius.row) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(learning.text), \(detail)")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    /// "Project: Acme Amplify · you · 3 days ago" or "… · inferred · …".
    private var detail: String {
        var parts = [scope, learning.source == "user" ? "you" : "inferred"]
        if let created = learning.created { parts.append(created.formatted(.relative(presentation: .named, unitsStyle: .wide))) }
        return parts.joined(separator: " · ")
    }
}

/// One consent rung and its Remove.
struct RungRow: View {
    let rung: CosRung
    let projectName: String
    let isFocused: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: House.Spacing.xs) {
            Text(ProposalAction(type: rung.type).typeLabel)
                .font(House.TypeToken.label)
                .foregroundStyle(House.ColorToken.textPrimary)
            Text(projectName)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .lineLimit(1)
            Spacer(minLength: House.Spacing.xs)
            CardButton(title: "Remove", keys: ["⌘", "⌫"], showsKeys: isFocused, action: onRemove)
        }
        .padding(.horizontal, House.Spacing.xs)
        .frame(minHeight: House.Control.railRow)
        .background { RowHighlight(isSelected: isFocused, radius: House.Radius.row) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }
}

/// ⌘N in the Charter: pick where the rule applies (Everywhere, This
/// project, This sender), type one line, Return adds it.
struct AddRuleSheet: View {
    @Bindable var model: ChiefOfStaffModel
    var onFocus: (ChiefOfStaffFocus) -> Void = { _ in }
    @FocusState private var focused: Bool

    var body: some View {
        if let draft = model.addRule {
            VStack(alignment: .leading, spacing: House.Spacing.xs) {
                SectionLabel(text: "Add rule")
                HStack(spacing: House.Spacing.xxs) {
                    ForEach(ChiefOfStaffModel.AddRule.Scope.allCases, id: \.self) { scope in
                        ScopeChip(
                            title: title(scope, draft: draft),
                            isSelected: draft.scope == scope,
                            isAvailable: draft.isAvailable(scope)
                        ) { model.setAddRuleScope(scope) }
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

    /// "This project (Acme Amplify)", "This sender (Charlie)".
    private func title(_ scope: ChiefOfStaffModel.AddRule.Scope, draft: ChiefOfStaffModel.AddRule) -> String {
        switch scope {
        case .everywhere: return scope.title
        case .project:
            let name = draft.project.map { slug in model.projects.first { $0.slug == slug }?.shortName ?? slug }
            return name.map { "\(scope.title) (\($0))" } ?? scope.title
        case .sender:
            return draft.sender.map { "\(scope.title) (\($0))" } ?? scope.title
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { model.addRule?.text ?? "" }, set: { model.addRule?.text = $0 })
    }
}

/// One choice of a small picker: selected in ink, unavailable greyed.
struct ScopeChip: View {
    let title: String
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(House.TypeToken.meta)
                .foregroundStyle(isSelected ? House.ColorToken.textPrimary : House.ColorToken.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, House.Spacing.xs)
                .frame(height: House.Control.chip)
                .background { RowHighlight(isSelected: isSelected, radius: House.Radius.sm) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .help(isAvailable ? title : "Open Add rule from a card, or filter a project, to use this")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
