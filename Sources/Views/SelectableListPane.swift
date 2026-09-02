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
    /// Accessibility value for the row at `index`, given whether it is selected.
    var accessibilityValue: ((Int, Bool) -> String)? = nil
    let onActivate: (Item) -> Void
    /// Row content for `(index, item, isSelected)`.
    @ViewBuilder let row: (Int, Item, Bool) -> Row

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: rowSpacing) {
                    if items.isEmpty, let emptyText {
                        Text(emptyText)
                            .font(AQDesign.TypeToken.body)
                            .foregroundStyle(.secondary)
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
                                .background(
                                    RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
                                        .fill(isSelected ? AQDesign.ColorToken.selectionFill : .clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .modifier(OptionalAccessibilityValue(
                            value: accessibilityValue?(index, isSelected)
                        ))
                        .id(item.id)
                    }
                }
                .padding(listInsets)
            }
            .scrollIndicators(.never)
            .onChange(of: selectedIndex) { _, index in
                guard scrollsToSelection, items.indices.contains(index) else { return }
                proxy.scrollTo(items[index].id, anchor: .center)
            }
        }
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
