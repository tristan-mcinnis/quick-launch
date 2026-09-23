import SwiftUI

/// The Proposal card component (design-system registry `proposal-card`),
/// ported from the retired ChiefOfStaff.app: one waiting proposal on a
/// raised card at `Radius.lg`. Source and time in `meta`, the message in
/// `body`, the numbered actions, then Do it / Edit / Skip. Edit turns each
/// action into its own field with Run and Cancel. The focused card wears the
/// selection ring and shows its keys: ⌘↩ Do it, ⌘E Edit, ⌘⌫ Skip.
struct ProposalCard: View {
    let proposal: Proposal
    @Bindable var state: ProposalCardState
    var isFocused = false
    /// Bumped by the model to put the keyboard in the first Edit field.
    var editFocusRequest = 0
    var onDo: () -> Void = {}
    var onEdit: () -> Void = {}
    var onSkip: () -> Void = {}
    var onRun: () -> Void = {}
    var onCancel: () -> Void = {}
    /// The keyboard moved into or out of the Edit fields.
    var onEditFocus: (Bool) -> Void = { _ in }

    @FocusState private var focusedField: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            header
            Text(proposal.message)
                .font(House.TypeToken.body)
                .foregroundStyle(House.ColorToken.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !proposal.actions.isEmpty {
                actions
            }
            outcome
            controls
        }
        .padding(House.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .fill(House.ColorToken.surfaceRaised)
                .houseShadow(AQDesign.Shadow.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.lg, style: .continuous)
                .strokeBorder(
                    isFocused ? House.ColorToken.strokeStrong : House.ColorToken.stroke,
                    lineWidth: House.hairline
                )
        )
        .overlay(alignment: .top) {
            House.ColorToken.highlightTop
                .frame(height: House.hairline)
                .padding(.horizontal, House.Radius.lg / 2)
        }
        .onChange(of: editFocusRequest) { _, _ in
            if state.isEditing { focusedField = 0 }
        }
        .onChange(of: focusedField) { _, field in onEditFocus(field != nil) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposal: \(proposal.headline)")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            Text(proposal.source)
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let due = proposal.due {
                Text("Due \(due)")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: House.Spacing.xs)
            if let created = proposal.created {
                Text(created, format: .dateTime.hour().minute())
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textTertiary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            if state.isEditing {
                ForEach($state.drafts) { $draft in
                    ActionEditor(number: draft.id + 1, draft: $draft, focus: $focusedField)
                }
            } else {
                ForEach(Array(proposal.actions.enumerated()), id: \.offset) { index, action in
                    ActionLine(number: index + 1, action: action)
                }
            }
        }
    }

    // MARK: Outcome

    @ViewBuilder
    private var outcome: some View {
        if state.isRunning {
            Text(state.isEditing ? "Running your edit…" : "Running…")
                .font(House.TypeToken.meta)
                .foregroundStyle(House.ColorToken.textTertiary)
        } else if let lines = state.outcome {
            OutcomeLines(lines: lines)
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if proposal.isWaiting && !state.isRunning {
            // The buttons wrap under each other when the card is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: House.Spacing.xs) { buttons }
                VStack(alignment: .leading, spacing: House.Spacing.xs) { buttons }
            }
            .padding(.top, House.Spacing.xxs)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if state.isEditing {
            CardButton(title: "Run", keys: ["⌘", "↩"], showsKeys: isFocused, prominent: true, action: onRun)
                .help("Run the edited actions (⌘↩)")
            CardButton(title: "Cancel", keys: ["esc"], showsKeys: isFocused, action: onCancel)
        } else if proposal.isNotice {
            // A health card has nothing to run: one acknowledgement.
            CardButton(title: "Got it", keys: ["⌘", "↩"], showsKeys: isFocused, prominent: true, action: onDo)
                .help("Mark as seen. Nothing runs (⌘↩)")
        } else {
            CardButton(title: "Do it", keys: ["⌘", "↩"], showsKeys: isFocused, prominent: true, action: onDo)
                .help("Run these actions now (⌘↩)")
            CardButton(title: "Edit", keys: ["⌘", "E"], showsKeys: isFocused, action: onEdit)
                .help("Change the actions, then run them (⌘E)")
            CardButton(title: "Skip", keys: ["⌘", "⌫"], showsKeys: isFocused, action: onSkip)
                .help("Record a no. Nothing runs (⌘⌫)")
        }
    }
}

// MARK: - Parts

/// One card button, `Control.chip` high at `Radius.tile`, with its key caps
/// beside it while the card has the keyboard.
struct CardButton: View {
    let title: String
    let keys: [String]
    var showsKeys = false
    var prominent = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: House.Spacing.xxs) {
            Button(title, action: action)
                .buttonStyle(CardButtonStyle(prominent: prominent))
            if showsKeys {
                KeyCapGroup(keys: keys)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
    }
}

/// One numbered action: the number, the type label (and due date) in
/// `caption`, the action's text in `bodySmall`.
struct ActionLine: View {
    let number: Int
    let action: ProposalAction

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            ActionNumber(number: number)
            VStack(alignment: .leading, spacing: House.Spacing.xxs / 2) {
                Text(label)
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                Text(action.text)
                    .font(House.TypeToken.bodySmall)
                    .foregroundStyle(House.ColorToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        guard let due = action.due else { return action.typeLabel }
        return "\(action.typeLabel) · Due \(due)"
    }
}

/// The action's number, in a column so the texts line up.
struct ActionNumber: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(House.TypeToken.meta)
            .foregroundStyle(House.ColorToken.textTertiary)
            .monospacedDigit()
            .frame(width: House.Spacing.sm, alignment: .leading)
    }
}

/// The Edit fields for one action: a note, a task title and due date, a
/// reply body, or what closing a task delivered.
struct ActionEditor: View {
    let number: Int
    @Binding var draft: ActionDraft
    var focus: FocusState<Int?>.Binding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
            ActionNumber(number: number)
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                Text(draft.original.typeLabel)
                    .font(House.TypeToken.caption)
                    .foregroundStyle(House.ColorToken.textTertiary)
                switch draft.kind {
                case .taskAdd:
                    CardField(prompt: "Task", text: $draft.text, lines: 1...3)
                        .focused(focus, equals: draft.id)
                    CardField(prompt: "Due, as 2026-09-30 (optional)", text: $draft.due, lines: 1...1)
                case .draftReply:
                    CardField(prompt: "Reply", text: $draft.text, lines: 3...8)
                        .focused(focus, equals: draft.id)
                case .taskClose:
                    CardField(prompt: "What was delivered", text: $draft.text, lines: 1...3)
                        .focused(focus, equals: draft.id)
                case .statusNote, .other:
                    CardField(prompt: "Note", text: $draft.text, lines: 2...6)
                        .focused(focus, equals: draft.id)
                }
            }
        }
    }
}

/// A text field on a card: `bodySmall` in a `well` at `Radius.sm` with a
/// strong hairline, growing within its line range.
struct CardField: View {
    let prompt: String
    @Binding var text: String
    let lines: ClosedRange<Int>

    var body: some View {
        // The prompt in tertiary ink, so an empty field never reads as filled.
        TextField(
            text: $text,
            prompt: Text(prompt).foregroundStyle(House.ColorToken.textTertiary),
            axis: .vertical
        ) { Text(prompt) }
            .textFieldStyle(.plain)
            .font(House.TypeToken.bodySmall)
            .foregroundStyle(House.ColorToken.textPrimary)
            .lineLimit(lines)
            .padding(.horizontal, House.Spacing.xs)
            .padding(.vertical, House.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .fill(House.ColorToken.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: House.Radius.sm, style: .continuous)
                    .strokeBorder(House.ColorToken.strokeStrong, lineWidth: House.hairline)
            )
            .accessibilityLabel(prompt)
    }
}

/// OK / FAIL lines: a status dot and the word, never colour alone.
struct OutcomeLines: View {
    let lines: [OutcomeLine]

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: House.Spacing.xs) {
                    StatusDot(color: line.ok ? House.ColorToken.success : House.ColorToken.danger)
                    Text(line.ok ? "OK" : "FAIL")
                        .font(House.TypeToken.label)
                        .foregroundStyle(House.ColorToken.textPrimary)
                    Text(line.text)
                        .font(House.TypeToken.meta)
                        .foregroundStyle(House.ColorToken.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The card's buttons: `Control.chip` high at `Radius.tile`. The prominent
/// one is an ink fill with inverse ink, never accent; the others are
/// outlined like key caps.
struct CardButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: House.Radius.tile, style: .continuous)
        configuration.label
            .font(House.TypeToken.label)
            .foregroundStyle(prominent ? House.ColorToken.textInverse : House.ColorToken.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, House.Spacing.sm)
            .frame(height: House.Control.chip)
            .background {
                if prominent {
                    shape.fill(House.ColorToken.textPrimary)
                } else {
                    shape.fill(configuration.isPressed ? House.ColorToken.selectionFill : House.ColorToken.keyCapFill)
                    shape.strokeBorder(House.ColorToken.keyCapStroke, lineWidth: House.hairline)
                }
            }
            .opacity(configuration.isPressed && prominent ? 0.8 : (isEnabled ? 1 : 0.45))
            .contentShape(shape)
    }
}
