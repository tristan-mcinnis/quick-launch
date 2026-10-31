import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HouseDesign

/// Measures the Settings shell and its panes share.
///
/// Every value here is a house token except `railGap`. The pane measures
/// follow the house form spacing rule (design-system/docs/form-spacing.md).
enum SettingsMetrics {
    /// Horizontal gutter of the pane header, the cards, and the notes.
    static let paneInset = House.Spacing.xxl
    /// Gap between the cards stacked down a pane.
    static let cardGap = House.Spacing.xl
    /// Space above the pane title.
    static let paneTop = House.Spacing.xxxl
    /// Gap from the pane header to the first group.
    static let headerGap = House.Spacing.xl
    /// Space below the last group of a pane.
    static let paneBottom = House.Spacing.xxxl
    /// Gap between two rail rows.
    static let railGap: CGFloat = 3
}

/// A full-width strip inside a `SettingsCard` that is not a titled row:
/// helper text, an error line, or a lone button. Draws the same divider
/// above itself that `SettingsRow` does.
struct CardNote<Content: View>: View {
    var isFirst = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { HouseDivider() }
            HStack(spacing: House.Spacing.sm) {
                content
                Spacer(minLength: 0)
            }
            .padding(.vertical, AQDesign.Space.standard)
        }
    }
}

/// The text of a `CardNote`: caption ink, wrapping, never truncated.
struct CardText: View {
    let text: String
    var tone: Color = AQDesign.ColorToken.textSecondary

    init(_ text: String, tone: Color = AQDesign.ColorToken.textSecondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(AQDesign.TypeToken.caption)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One option of an `InkSegmentedControl`.
struct InkSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }
}

/// A segmented control in ink. The selected segment is the house selection
/// tile (fill, inset ring, 1 pt drop); hover is half the fill. Never an
/// accent tint, which is what `.pickerStyle(.segmented)` would paint.
struct InkSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [InkSegment<Value>]
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(
                            isSelected
                                ? AQDesign.ColorToken.textPrimary
                                : AQDesign.ColorToken.textSecondary
                        )
                        .lineLimit(1)
                        .padding(.horizontal, AQDesign.Space.row)
                        .frame(maxWidth: .infinity, minHeight: AQDesign.tileSize)
                        .background(
                            RowHighlight(
                                isSelected: isSelected,
                                isHovering: hovered == option.value,
                                radius: AQDesign.fieldCornerRadius
                            )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = option.value
                    } else if hovered == option.value {
                        hovered = nil
                    }
                }
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(AQDesign.Space.compact)
        .background(
            RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                .fill(AQDesign.ColorToken.surfaceFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                .strokeBorder(AQDesign.ColorToken.tileStroke, lineWidth: AQDesign.hairline)
        )
    }
}
