import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HouseDesign

// MARK: - About

struct AboutTab: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        SettingsPaneScroller(pane: .about) {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                SettingsCard("Version") {
                    SettingsRow(title: "Quick Launch", isFirst: true) {
                        Text("Version \(viewModel.currentVersion)")
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    }

                    SettingsRow(title: "Updates") {
                        HStack(spacing: House.Spacing.sm) {
                            updateStatusView
                            Button("Check for update") {
                                Task { await viewModel.checkForUpdateManual() }
                            }
                            .disabled(viewModel.updateState == .checking)
                        }
                    }
                    .settingsAnchor("about.updates", radius: AQDesign.fieldCornerRadius)

                    SettingsRow(
                        title: "Check for updates on launch",
                        detail: "Asks GitHub once at launch for the newest release tag. Never installs on its own."
                    ) {
                        Toggle(
                            "Check for updates on launch",
                            isOn: viewModel.settingsBinding(\.checkForUpdatesOnLaunch)
                        )
                        .toggleStyle(InkToggleStyle())
                    }
                }
                .settingsAnchor("about.version")

                SettingsCard("Source") {
                    SettingsRow(title: "Repository", isFirst: true) {
                        Link(
                            "Source on GitHub",
                            destination: URL(string: "https://github.com/tristan-mcinnis/quick-launch")!
                        )
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.accent)
                    }
                }
                .settingsAnchor("about.source")
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, SettingsMetrics.paneBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch viewModel.updateState {
        case .checking:
            statusLine("Checking…", dot: AQDesign.ColorToken.warning)
        case .upToDate:
            statusLine("Up to date", dot: AQDesign.ColorToken.success)
        case .updateAvailable(let v):
            Button("Update to \(v)") { [weak viewModel] in viewModel?.installUpdate() }
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .buttonStyle(.plain)
        case .installing(let v):
            statusLine("Installing \(v)…", dot: AQDesign.ColorToken.warning)
        case .installed(let v):
            statusLine("Installed \(v)", dot: AQDesign.ColorToken.success)
        case .error(let msg):
            statusLine(msg, dot: AQDesign.ColorToken.danger)
        case .idle:
            EmptyView()
        }
    }

    private func statusLine(_ text: String, dot: Color) -> some View {
        HStack(spacing: AQDesign.Space.standard) {
            StatusDot(color: dot)
            Text(text)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
