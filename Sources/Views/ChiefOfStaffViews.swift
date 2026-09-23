import SwiftUI

/// The WAITING section of the pinned Chief of Staff conversation, pinned
/// above the thread: every waiting card, newest first, in its own scroll
/// capped at `maxHeight`. The section takes the keyboard when a card is
/// focused (↑↓ from the composer), so typed keys never reach the draft.
struct ChiefOfStaffWaitingSection: View {
    @Bindable var model: ChiefOfStaffModel
    /// The most the section may take before it scrolls.
    let maxHeight: CGFloat
    /// The keyboard is on the cards (the window's `Focus.cards`).
    let hasKeyboard: Bool
    /// Where the keyboard is, for the window's key routing.
    var onFocus: (_ cards: Bool, _ editing: Bool) -> Void = { _, _ in }

    @State private var contentHeight: CGFloat = 0
    @FocusState private var sectionFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            header
            if !model.waiting.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: House.Spacing.sm) {
                            ForEach(model.waiting) { proposal in
                                card(proposal).id(proposal.id)
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
                        withAnimation(.easeOut(duration: House.Motion.select)) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
            }
        }
        .frame(maxWidth: QuickAIView.threadColumnWidth, alignment: .leading)
        .padding(.horizontal, House.Spacing.lg)
        .padding(.top, House.Spacing.sm)
        .padding(.bottom, House.Spacing.xs)
        .frame(maxWidth: .infinity)
        .focusable(hasKeyboard && !model.isEditingFocusedCard)
        .focusEffectDisabled()
        .focused($sectionFocused)
        .onChange(of: hasKeyboard) { _, has in
            if has, !model.isEditingFocusedCard { FocusRequest.apply($sectionFocused) }
        }
        .onAppear {
            if hasKeyboard, !model.isEditingFocusedCard { FocusRequest.apply($sectionFocused) }
        }
        .onChange(of: sectionFocused) { _, focused in
            if focused { onFocus(true, false) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting cards")
    }

    private var header: some View {
        HStack(spacing: House.Spacing.xs) {
            SectionLabel(text: "Waiting")
            Text(model.waiting.isEmpty ? "None" : "\(model.waiting.count)")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
                .monospacedDigit()
            if model.isPaused {
                StatusDot(color: House.ColorToken.danger)
                Text("Paused")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
            }
            Spacer(minLength: House.Spacing.xs)
            if !model.waiting.isEmpty {
                KeyHint(label: hasKeyboard ? "Back" : "Cards", keys: hasKeyboard ? ["esc"] : ["⌥", "↑"])
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func card(_ proposal: Proposal) -> some View {
        let state = model.cards[proposal.id] ?? ProposalCardState()
        let isFocused = hasKeyboard && model.focusedCardID == proposal.id
        return ProposalCard(
            proposal: proposal,
            state: state,
            isFocused: isFocused || (state.isEditing && model.focusedCardID == proposal.id),
            editFocusRequest: model.focusedCardID == proposal.id ? model.editFocusRequest : 0,
            onDo: { model.send(.doIt(id: proposal.id)) },
            onEdit: { model.beginEdit(proposal) },
            onSkip: { model.send(.skip(id: proposal.id)) },
            onRun: { model.send(.runEdit(id: proposal.id)) },
            onCancel: {
                model.cancelEdit(proposal.id)
                onFocus(true, false)
            },
            onEditFocus: { editing in
                if editing {
                    model.focusedCardID = proposal.id
                    onFocus(true, true)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { model.focusCard(proposal.id) }
    }
}

/// The history above the chat, inside the thread's scroll: decided cards
/// collapsed to one line each (a click opens one), and chat turns another
/// surface recorded (`cos ask`) as normal chat. The turns this app asked
/// follow as the chat's own thread.
struct ChiefOfStaffHistory: View {
    let items: [ChiefOfStaffThreadItem]
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
            if !items.isEmpty {
                SectionLabel(text: "Earlier")
            }
            ForEach(items) { item in
                row(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// "2 OK, 1 FAIL", or nil when nothing ran.
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
