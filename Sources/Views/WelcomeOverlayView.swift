import SwiftUI

/// The first-run card: the app mark, one paragraph, three bullets, and the
/// key that starts the launcher. Monochrome glass, exactly like the launcher.
struct WelcomeOverlayView: View {
    @Bindable var viewModel: QuickViewModel
    var onContinue: () -> Void

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

                Text("Press Option+Space anywhere, choose a model, and run a quick action. The result streams in and copies to your clipboard automatically.")
                    .font(AQDesign.TypeToken.prose)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
                    featureBullet("arrow.triangle.2.circlepath", "Switch local, API, and CLI models")
                    featureBullet("bolt", "Saved actions and short follow-ups")
                    featureBullet("lock.shield", "API keys stay in macOS Keychain")
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
