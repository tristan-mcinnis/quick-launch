import SwiftUI

/// One keyboard-driven list shared by the launcher, the ⌘K item pane, the
/// prompt palette, and the translator's target picker.
///
/// The caller owns the items, the selection index, and the row content; this
/// view owns everything the four lists had copied by hand: the scroll view and
/// lazy stack, the plain button per row, the selection fill behind the
/// selected row, the `isSelected` accessibility trait, an optional
/// accessibility value per row, an optional empty-state placeholder row, and
/// scrolling the selected row into view when the index changes.
///
/// Hover is not selection. Hover paints half the selection fill and no ring;
/// selection paints the fill, an inset ring, and a 1 pt drop, and slides
/// between rows over `Motion.select`. Reduce Motion turns the slide into a
/// plain cut with no movement.
struct SelectableListPane<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @Binding var selectedIndex: Int
    /// Spacing between rows in the lazy stack.
    var rowSpacing: CGFloat = 0
    /// Fixed row height; `nil` lets the row builder size itself.
    var rowHeight: CGFloat? = nil
    /// Insets around the whole stack of rows.
    var listInsets: EdgeInsets = EdgeInsets()
    /// Quiet single row shown when `items` is empty.
    var emptyText: String? = nil
    /// Keeps the selected row visible while it moves under the keys.
    var scrollsToSelection = false
    /// Corner radius of the selection and hover fills.
    var rowCornerRadius: CGFloat = AQDesign.itemCornerRadius
    /// Accessibility value for the row at `index`, given whether it is selected.
    var accessibilityValue: ((Int, Bool) -> String)? = nil
    let onActivate: (Item) -> Void
    /// Row content for `(index, item, isSelected)`.
    @ViewBuilder let row: (Int, Item, Bool) -> Row

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    @State private var hoveredID: Item.ID?
    @State private var pacer = SelectionPacer()
    @State private var keyboardDriven = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: rowSpacing) {
                    if items.isEmpty, let emptyText {
                        Text(emptyText)
                            .font(AQDesign.TypeToken.body)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .frame(maxWidth: .infinity)
                            .frame(height: PanelSizing.actionRowHeight)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let isSelected = index == selectedIndex
                        Button {
                            onActivate(item)
                        } label: {
                            row(index, item, isSelected)
                                .frame(height: rowHeight)
                                .background { background(for: item, isSelected: isSelected) }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                guard !keyboardDriven else { return }
                                hoveredID = item.id
                            } else if hoveredID == item.id {
                                hoveredID = nil
                            }
                        }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .modifier(OptionalAccessibilityValue(
                            value: accessibilityValue?(index, isSelected)
                        ))
                        .id(item.id)
                    }
                }
                .padding(listInsets)
                .animation(selectionAnimation(for: selectedIndex), value: selectedIndex)
                .animation(hoverAnimation, value: hoveredID)
            }
            .scrollIndicators(.never)
            .onContinuousHover { phase in
                if case .active = phase, keyboardDriven { keyboardDriven = false }
            }
            .onChange(of: selectedIndex) { _, index in
                keyboardDriven = true
                hoveredID = nil
                guard scrollsToSelection, items.indices.contains(index) else { return }
                proxy.scrollTo(items[index].id)
            }
        }
    }

    /// The selected row's fill is one view that slides between rows; hover
    /// paints its own quieter fill wherever the pointer is.
    @ViewBuilder
    private func background(for item: Item, isSelected: Bool) -> some View {
        ZStack {
            if isSelected {
                RowHighlight(isSelected: true, radius: rowCornerRadius)
                    .matchedGeometryEffect(id: "slate.selection", in: selection)
            } else if hoveredID == item.id {
                RowHighlight(isSelected: false, isHovering: true, radius: rowCornerRadius)
            }
        }
    }

    private func selectionAnimation(for index: Int) -> Animation? {
        let animate = pacer.animates(for: index, now: Date())
        return reduceMotion || !animate ? nil : .easeOut(duration: AQDesign.Motion.select)
    }

    private var hoverAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: AQDesign.Motion.hover)
    }
}

/// Keyboard stepping shared by every `SelectableListPane` owner.
enum ListSelection {
    /// The index `delta` steps away from `index`, wrapping around `count`.
    /// Returns `index` unchanged for an empty list.
    static func wrappedIndex(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return index }
        return (index + delta + count) % count
    }

    /// Key repeat arrives faster than this; a deliberate press does not.
    static let repeatThreshold: TimeInterval = 0.08

    /// Whether a selection change slides (`true`) or cuts. A change that
    /// follows the previous one within `repeatThreshold` is a held key.
    static func shouldAnimateSelection(
        previous: Date?, now: Date, threshold: TimeInterval = repeatThreshold
    ) -> Bool {
        guard let previous else { return true }
        return now.timeIntervalSince(previous) >= threshold
    }
}

/// Remembers when the selection last moved so the slide can be judged at
/// render time, before the animation for that change is chosen. Not observed:
/// it only feeds `ListSelection.shouldAnimateSelection`.
@MainActor
final class SelectionPacer {
    private var index: Int?
    private var changedAt: Date?
    private var animate = true

    func animates(for newIndex: Int, now: Date) -> Bool {
        guard newIndex != index else { return animate }
        animate = ListSelection.shouldAnimateSelection(previous: changedAt, now: now)
        if index != nil { changedAt = now }
        index = newIndex
        return animate
    }
}

private struct OptionalAccessibilityValue: ViewModifier {
    let value: String?

    func body(content: Content) -> some View {
        if let value {
            content.accessibilityValue(value)
        } else {
            content
        }
    }
}
