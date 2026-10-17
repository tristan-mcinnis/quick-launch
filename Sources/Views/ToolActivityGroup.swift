import SwiftUI
import HouseDesign

/// The activity line's timing: 0.175 s to open, rows fading in over 0.3 s
/// 50 ms apart. Reduce Motion: no animation at all (DESIGN.md).
enum ToolActivityMotion {
    /// The open and close curve, and each row's fade.
    static let expandDuration: Double = ChatMotion.disclosure
    static let rowFadeDuration: Double = ChatMotion.appear
    static let rowStagger: Double = ChatMotion.appearStagger

    /// Reduce Motion: no movement and no stagger, rows just appear.
    static func expandAnimation(reduceMotion: Bool) -> Animation? {
        ChatMotion.disclosureAnimation(reduceMotion: reduceMotion)
    }

    static func rowAnimation(index: Int, reduceMotion: Bool) -> Animation? {
        ChatMotion.appearAnimation(index: index, reduceMotion: reduceMotion)
    }
}

/// The thread's one activity line for a run of tool calls: collapsed by
/// default, a chevron to open the lines it holds. Failures and pending
/// approvals are not inside it; the caller draws them beside it.
struct ToolActivityGroup<Row: View>: View {
    let headline: String
    let lines: [ToolActivitySummary.Line]
    @ViewBuilder let row: (ToolActivitySummary.Line) -> Row

    init(
        headline: String,
        lines: [ToolActivitySummary.Line],
        startsExpanded: Bool = false,
        @ViewBuilder row: @escaping (ToolActivitySummary.Line) -> Row
    ) {
        self.headline = headline
        self.lines = lines
        self.row = row
        _isExpanded = State(initialValue: startsExpanded)
    }

    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    Text(headline)
                        .font(AQDesign.TypeToken.body)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(lines.count)")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                }
                .frame(minHeight: House.Control.keyCap)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(headline), \(lines.count) steps")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the steps" : "Shows the steps")

            if isExpanded {
                VStack(alignment: .leading, spacing: House.Spacing.xs) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        row(line)
                            .transition(.opacity.animation(ToolActivityMotion.rowAnimation(index: index, reduceMotion: reduceMotion)))
                    }
                }
                .padding(.leading, House.Spacing.sm)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(AQDesign.ColorToken.textTertiary.opacity(0.3))
                        .frame(width: 2)
                }
            }
        }
    }
}
