import SwiftUI
import HouseDesign

/// A copied colour drawn as itself, in place of the row's glyph.
struct ClipboardColorSwatch: View {
    let color: ClipboardColor

    var body: some View {
        RoundedRectangle(cornerRadius: House.Radius.xs, style: .continuous)
            .fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha))
            .overlay(
                RoundedRectangle(cornerRadius: House.Radius.xs, style: .continuous)
                    .strokeBorder(AQDesign.ColorToken.divider, lineWidth: AQDesign.hairline)
            )
            .padding(House.Spacing.xxs)
            .accessibilityHidden(true)
    }

    /// The colour a clipboard row's text is, or nil.
    static func color(for item: LauncherCatalogItem) -> ClipboardColor? {
        guard item.kind == .clipboard, let payload = item.clipboardPayload,
              payload.kind == .text || payload.kind == .richText else { return nil }
        return ClipboardColor(payload.text)
    }
}
