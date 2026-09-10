import SwiftUI

/// The inline multiple-choice question the model asked mid-answer.
///
/// Raycast renders it in the conversation: the question, then a short list of
/// options, one of them selected. The user moves with ↑/↓ and picks with
/// Return; the pick folds back into the thread and the answer continues.
///
/// The same view serves both roles. A live card is the one in the answer
/// area while the model waits (`isInteractive`). A record card is the one
/// left in the transcript after the pick; it shows the same options with the
/// picked one marked and takes no input.
struct AskUserQuestionCard: View {
    let question: AskUserQuestion
    /// The option the keys are on while the card is live. Ignored once the
    /// card has been answered, where `question.selectedIndex` rules.
    var selectedIndex: Int = 0
    var isInteractive: Bool = false
    /// ↑/↓ walk the options; the delta goes to the view model so the panel
    /// and the card can never disagree about which option is selected.
    var onMove: ((Int) -> Void)?
    var onPick: ((Int) -> Void)?

    @FocusState private var isFocused: Bool

    /// A live card takes the keys itself. The composer stays enabled as a
    /// fallback, so either first responder answers the question.
    private var isFocusable: Bool { isInteractive && !question.isAnswered }

    var body: some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
            HStack(alignment: .firstTextBaseline, spacing: AQDesign.Space.standard) {
                Image(systemName: "questionmark.bubble")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                Text(question.question)
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            VStack(spacing: 2) {
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    row(option, index: index)
                }
            }
            if isInteractive, !question.isAnswered {
                Text(AskUserQuestionAccessibility.cardHint)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
            }
        }
        .padding(AQDesign.Space.row)
        .frame(maxWidth: House.Layout.answerMaxWidth, alignment: .leading)
        .raisedCard()
        .focusable(isFocusable)
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = isFocusable }
        .onChange(of: question.isAnswered) { _, answered in
            isFocused = isInteractive && !answered
        }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.return) { pick() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AskUserQuestionAccessibility.cardLabel(
            question: question.question,
            optionCount: question.options.count
        ))
    }

    /// ↑/↓ move the selection and stay handled, so the key never falls
    /// through to the launcher or the composer while a question is open.
    private func move(_ delta: Int) -> KeyPress.Result {
        guard isFocusable else { return .ignored }
        onMove?(delta)
        return .handled
    }

    private func pick() -> KeyPress.Result {
        guard isFocusable else { return .ignored }
        onPick?(selectedIndex)
        return .handled
    }

    private func row(_ option: AskUserQuestionOption, index: Int) -> some View {
        let isPicked = question.selectedIndex == index
        let isSelected = isPicked || (!question.isAnswered && index == selectedIndex)
        return Button {
            onPick?(index)
        } label: {
            HStack(spacing: AQDesign.Space.row) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = option.detail {
                        Text(detail)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if isPicked {
                    Image(systemName: "checkmark")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                }
            }
            .padding(.horizontal, AQDesign.Space.row)
            .padding(.vertical, AQDesign.Space.compact)
            .frame(minHeight: House.Control.row, alignment: .leading)
            .background { RowHighlight(isSelected: isSelected) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isInteractive || question.isAnswered)
        .accessibilityLabel(AskUserQuestionAccessibility.optionLabel(
            option,
            index: index,
            count: question.options.count,
            isSelected: isSelected,
            isPicked: isPicked
        ))
        .accessibilityAddTraits(isPicked ? [.isSelected] : [])
    }

    /// The room the live card takes in the answer block, so the panel grows
    /// to fit it instead of clipping the last option. Every option is counted
    /// at the full row height even when it has no detail line.
    static func blockHeight(optionCount: Int, isInteractive: Bool = true) -> CGFloat {
        let rows = CGFloat(max(optionCount, 1)) * House.Control.row
            + CGFloat(max(optionCount - 1, 0)) * 2
        let questionRow = House.Control.chip
        let hint = isInteractive ? House.Control.chip - House.Spacing.xs : 0
        return AQDesign.Space.row * 2
            + questionRow
            + rows
            + hint
            + AQDesign.Space.standard * 2
    }
}
