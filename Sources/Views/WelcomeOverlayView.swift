import SwiftUI

struct WelcomeOverlayView: View {
    @Bindable var viewModel: QuickViewModel
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.38, green: 0.13, blue: 0.66),
                                     Color(red: 0.24, green: 0.07, blue: 0.44)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)

                Text("Welcome to Quick Launch")
                    .font(.system(size: 22, weight: .bold))

                Text("Press Option+Space anywhere, choose a model, and run a quick action. The result streams in and copies to your clipboard automatically.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    featureBullet("arrow.triangle.2.circlepath", "Switch local, API, and CLI models")
                    featureBullet("bolt", "Saved actions and short follow-ups")
                    featureBullet("lock.shield", "API keys stay in macOS Keychain")
                }
                .padding(.top, 4)

            }
            .padding(32)

            Divider()

            Button("Get Started") {
                viewModel.settings.save()
                onContinue()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(20)
        }
        .frame(width: 460)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .preferredColorScheme(.light)
    }

    private func featureBullet(_ systemImage: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AQDesign.ColorToken.accent)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
