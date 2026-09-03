import AppKit
import SwiftUI

// Shared Slate chrome: the pieces every surface in the app is built from.
// Nothing here invents a value; every number is a token from `AQDesign`
// (and so from the design system's `tokens.json`).

// MARK: - Glass

/// The blur behind a floating panel. `panelTint` is painted over it.
struct HouseVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.state = .active
    }
}

/// Panel glass: blur material, `panelTint`, hairline `stroke`, and a 1 px
/// `highlightTop` along the top edge. The only way a floating surface in
/// this app gets a background.
struct PanelGlass: ViewModifier {
    var radius: CGFloat = AQDesign.cornerRadius
    var material: NSVisualEffectView.Material = .popover

    func body(content: Content) -> some View {
        content
            .background {
                ZStack(alignment: .top) {
                    HouseVisualEffect(material: material)
                    AQDesign.ColorToken.panelTint
                    Rectangle()
                        .fill(AQDesign.ColorToken.highlightTop)
                        .frame(height: AQDesign.hairline)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: AQDesign.hairline)
            }
    }
}

/// An opaque raised card: `surfaceRaised`, hairline, top highlight.
struct RaisedCard: ViewModifier {
    var radius: CGFloat = AQDesign.cardCornerRadius
    var fill: Color = AQDesign.ColorToken.surfaceFill

    func body(content: Content) -> some View {
        content
            .background {
                ZStack(alignment: .top) {
                    fill
                    Rectangle()
                        .fill(AQDesign.ColorToken.highlightTop)
                        .frame(height: AQDesign.hairline)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: AQDesign.hairline)
            }
    }
}

/// One house shadow. Opacity follows the appearance, so this reads the
/// colour scheme rather than hard-coding one of the two values.
private struct HouseShadow: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let spec: House.ShadowSpec

    func body(content: Content) -> some View {
        content.shadow(
            color: .black.opacity(spec.opacity(dark: colorScheme == .dark)),
            radius: spec.blur / 2,
            y: spec.y
        )
    }
}

extension View {
    func panelGlass(
        radius: CGFloat = AQDesign.cornerRadius,
        material: NSVisualEffectView.Material = .popover
    ) -> some View {
        modifier(PanelGlass(radius: radius, material: material))
    }

    func raisedCard(
        radius: CGFloat = AQDesign.cardCornerRadius,
        fill: Color = AQDesign.ColorToken.surfaceFill
    ) -> some View {
        modifier(RaisedCard(radius: radius, fill: fill))
    }

    func houseShadow(_ spec: House.ShadowSpec) -> some View {
        modifier(HouseShadow(spec: spec))
    }

    /// The two shadows under every floating panel.
    func panelShadows() -> some View {
        houseShadow(AQDesign.Shadow.panelNear).houseShadow(AQDesign.Shadow.panelFar)
    }
}

// MARK: - Divider

/// The line between the input row, the list, and the footer. Quieter than
/// the panel stroke and never drawn with it.
struct HouseDivider: View {
    var body: some View {
        Rectangle()
            .fill(AQDesign.ColorToken.divider)
            .frame(height: AQDesign.hairline)
    }
}

// MARK: - Row furniture

/// The 26 pt tile a row glyph sits in, so rows align whatever the symbol
/// width. Pass an app icon, an SF Symbol, or an emoji.
struct IconTile<Content: View>: View {
    var size: CGFloat = AQDesign.tileSize
    /// An app icon fills the tile edge to edge; a glyph sits inside it.
    var fillsTile = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: fillsTile ? size : size - 10, height: fillsTile ? size : size - 10)
            .frame(width: size, height: size)
            .background {
                if !fillsTile {
                    RoundedRectangle(cornerRadius: AQDesign.tileCornerRadius, style: .continuous)
                        .fill(AQDesign.ColorToken.tileFill)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: AQDesign.tileCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AQDesign.tileCornerRadius, style: .continuous)
                    .strokeBorder(AQDesign.ColorToken.tileStroke, lineWidth: AQDesign.hairline)
            }
    }
}

/// An uppercase section label: "SUGGESTIONS", "HOTKEYS", "TODAY".
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(AQDesign.TypeToken.section)
            .tracking(AQDesign.TypeToken.sectionTracking)
            .foregroundStyle(AQDesign.ColorToken.textTertiary)
            .accessibilityLabel(text)
    }
}

/// A run of key caps such as ⌥ ⌘ ←.
struct KeyCapGroup: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: AQDesign.Space.compact) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCap(text: key)
            }
        }
    }
}

/// One outlined key cap: 20 pt tall, `keyCapStroke` hairline, no fill.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AQDesign.TypeToken.keyCap)
            .foregroundStyle(AQDesign.ColorToken.textSecondary)
            .padding(.horizontal, text.count > 1 ? 6 : 0)
            .frame(minWidth: AQDesign.keyCapHeight, minHeight: AQDesign.keyCapHeight)
            .background(
                RoundedRectangle(cornerRadius: AQDesign.keyCapCornerRadius, style: .continuous)
                    .fill(AQDesign.ColorToken.keyCapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AQDesign.keyCapCornerRadius, style: .continuous)
                    .strokeBorder(AQDesign.ColorToken.keyCapStroke, lineWidth: AQDesign.hairline)
            )
    }
}

/// A hint and its keys, as they read in a footer: "Open ↩".
struct KeyHint: View {
    let label: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textPrimary.opacity(0.8))
                .lineLimit(1)
            KeyCapGroup(keys: keys)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(keys.joined(separator: " "))")
    }
}

/// A 6 pt status dot. Never the only signal: it always sits beside a word.
struct StatusDot: View {
    var color: Color = AQDesign.ColorToken.success
    var diameter: CGFloat = 6

    var body: some View {
        Circle().fill(color).frame(width: diameter, height: diameter)
    }
}

/// The sunken strip at the foot of a panel or window.
struct FooterWell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HouseDivider()
            content
                .padding(.leading, House.Spacing.md)
                .padding(.trailing, House.Spacing.sm)
                .frame(minHeight: AQDesign.footerHeight)
                .frame(maxWidth: .infinity)
                .background(AQDesign.ColorToken.well)
        }
    }
}

/// The background behind one list row: selection (fill, inset ring, 1 pt
/// drop) or hover (half the fill, no ring). Hover is not selection.
struct RowHighlight: View {
    var isSelected: Bool
    var isHovering: Bool = false
    var radius: CGFloat = AQDesign.itemCornerRadius

    var body: some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(AQDesign.ColorToken.selectionFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(
                                AQDesign.ColorToken.selectionRing,
                                lineWidth: AQDesign.hairline
                            )
                    )
                    .houseShadow(AQDesign.Shadow.selection)
            } else if isHovering {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(AQDesign.ColorToken.hoverFill)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A chip: 28 tall at `Radius.sm` on `chipFill`, `meta` text.
struct HouseChip: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(AQDesign.TypeToken.caption)
            }
            Text(text)
                .font(AQDesign.TypeToken.metadata)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(AQDesign.ColorToken.textSecondary)
        .padding(.horizontal, AQDesign.Space.standard)
        .frame(minHeight: House.Control.chip - 6)
        .background(
            RoundedRectangle(cornerRadius: AQDesign.fieldCornerRadius, style: .continuous)
                .fill(AQDesign.ColorToken.chipFill)
        )
    }
}

// MARK: - Controls

/// An ink toggle. On is a solid ink track with a knob in the ground colour;
/// off is an outline. Never blue, never an accent.
struct InkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? AQDesign.ColorToken.textPrimary : Color.clear)
                    .overlay(
                        Capsule().strokeBorder(
                            configuration.isOn ? Color.clear : AQDesign.ColorToken.keyCapStroke,
                            lineWidth: AQDesign.hairline
                        )
                    )
                    .frame(width: 30, height: 18)
                Circle()
                    .fill(
                        configuration.isOn
                            ? AQDesign.ColorToken.textInverse
                            : AQDesign.ColorToken.textTertiary
                    )
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, 2)
            }
            .frame(width: 30, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A settings group drawn as a card: an uppercase section label above rows
/// separated by dividers.
struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                SectionLabel(text: title)
                    .padding(.top, House.Spacing.sm)
                    .padding(.bottom, AQDesign.Space.compact)
            }
            content
        }
        .padding(.horizontal, House.Spacing.md)
        .padding(.bottom, AQDesign.Space.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard()
    }
}

/// One row inside a `SettingsCard`: a label on the left, a control on the
/// right, a divider above every row but the first.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var isFirst: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if !isFirst { HouseDivider() }
            HStack(spacing: House.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: House.Spacing.sm)
                trailing
            }
            .frame(minHeight: AQDesign.rowHeight)
        }
    }
}

/// The one primary action on a form: an ink fill with inverse text. There is
/// no accent button in this app.
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AQDesign.TypeToken.label)
            .foregroundStyle(AQDesign.ColorToken.textInverse)
            .padding(.horizontal, House.Spacing.sm)
            .frame(minHeight: House.Control.compact)
            .background(
                RoundedRectangle(cornerRadius: AQDesign.menuCornerRadius, style: .continuous)
                    .fill(AQDesign.ColorToken.textPrimary)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
