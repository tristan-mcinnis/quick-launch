import SwiftUI

/// The first-run card: the app mark, one line, the five keys and tools that
/// make up today's app, and the key that starts the launcher. Monochrome
/// glass, exactly like the launcher.
struct WelcomeOverlayView: View {
    @Bindable var viewModel: QuickViewModel
    var onContinue: () -> Void

    /// One line of the card: a glyph in a tile and a short sentence.
    struct Line: Identifiable, Equatable {
        let systemImage: String
        let text: String
        var id: String { text }
    }

    static let summary = "Search, ask, and chat without leaving the keyboard."

    /// `hotkey` is the launcher key as Settings shows it (\u{2325}Space by
    /// default), so the card names the key this Mac really uses.
    static func lines(hotkey: String) -> [Line] {
        [
            Line(systemImage: "magnifyingglass", text: "\(hotkey) opens search"),
            Line(systemImage: "sparkles", text: "Tab asks Quick AI"),
            Line(systemImage: "bubble.left.and.bubble.right", text: "\u{2318}J opens AI Chat"),
            Line(systemImage: "at", text: "@ adds context"),
            Line(systemImage: "brain.head.profile", text: "Tools can read your memory and the vault"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: House.Spacing.md) {
                // The app icon's own shape: one flat ink tile, one glyph.
                // No gradient, no shadow.
                RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius, style: .continuous)
                    .fill(AQDesign.ColorToken.textPrimary)
                    .frame(width: House.Spacing.xxxxl, height: House.Spacing.xxxxl)
                    .overlay {
                        Image(systemName: "bolt.fill")
                            .font(House.TypeToken.display)
                            .foregroundStyle(AQDesign.ColorToken.textInverse)
                    }
                    .accessibilityHidden(true)

                Text("Welcome to Quick Launch")
                    .font(AQDesign.TypeToken.title)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)

                Text(Self.summary)
                    .font(AQDesign.TypeToken.prose)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
                    ForEach(Self.lines(hotkey: viewModel.settings.hotkeyDisplayName)) { line in
                        featureBullet(line.systemImage, line.text)
                    }
                }
                .padding(.top, AQDesign.Space.compact)

            }
            .padding(House.Spacing.xxl)

            HouseDivider()

            Button {
                viewModel.settings.save()
                onContinue()
            } label: {
                Text("Get Started")
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textInverse)
                    .frame(maxWidth: .infinity)
                    .frame(height: AQDesign.controlHeight)
                    .background(
                        RoundedRectangle(
                            cornerRadius: AQDesign.menuCornerRadius,
                            style: .continuous
                        )
                        .fill(AQDesign.ColorToken.textPrimary)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(AQDesign.Space.panel)
        }
        .frame(width: 460)
        .panelGlass()
        .preferredColorScheme(viewModel.settings.appearance.swiftUIColorScheme)
    }

    private func featureBullet(_ systemImage: String, _ text: String) -> some View {
        HStack(spacing: AQDesign.Space.row) {
            IconTile {
                Image(systemName: systemImage)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
            }
            Text(text)
                .font(AQDesign.TypeToken.body)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
        }
    }
}
