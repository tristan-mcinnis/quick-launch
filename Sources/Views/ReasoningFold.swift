import SwiftUI
import HouseDesign

/// A thinking model's reasoning, folded into one quiet line above its
/// answer: "Thinking… 4 s" while it thinks, "Thought for 12 s" once the
/// answer starts. The chevron opens the reasoning itself, in secondary ink,
/// selectable. Collapsed by default, as the tool lines are.
struct ReasoningFold: View {
    let text: String
    /// Seconds it thought, once known.
    let seconds: Double?
    /// When the thinking started, for the live count. Nil on a saved answer.
    var startedAt: Date? = nil

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The line's words. Pure, so the wording is tested.
    nonisolated static func headline(seconds: Double?, startedAt: Date?, now: Date) -> String {
        if let seconds { return "Thought for \(shownSeconds(seconds)) s" }
        if let startedAt {
            let elapsed = now.timeIntervalSince(startedAt)
            return elapsed >= 1 ? "Thinking… \(shownSeconds(elapsed)) s" : "Thinking…"
        }
        return "Reasoning"
    }

    nonisolated static func shownSeconds(_ seconds: Double) -> Int {
        max(1, Int(seconds.rounded()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            Button {
                withAnimation(ToolActivityMotion.expandAnimation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: House.Spacing.xs) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .frame(width: House.Control.keyCap)
                    headlineText
                        .font(AQDesign.TypeToken.body)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                }
                .frame(minHeight: House.Control.keyCap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.headline(seconds: seconds, startedAt: startedAt, now: Date()))
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the reasoning" : "Shows the reasoning")

            if isExpanded {
                Text(text)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, House.Spacing.sm)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(AQDesign.ColorToken.textTertiary.opacity(0.3))
                            .frame(width: 2)
                    }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private var headlineText: some View {
        if seconds == nil, let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.headline(seconds: nil, startedAt: startedAt, now: context.date))
            }
        } else {
            Text(Self.headline(seconds: seconds, startedAt: startedAt, now: Date()))
        }
    }
}
