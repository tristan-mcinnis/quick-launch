import SwiftUI
import AppKit

/// The Screen History settings tab: sources, Coast import, capture, and
/// retention. Every action goes through `viewModel.screenHistory`.
struct ScreenHistorySettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @ScaledMetric(relativeTo: .body) private var exclusionEditorMinHeight: CGFloat = 110

    private struct CommunicationSource: Identifiable {
        let id: String
        let title: String
        let detail: String
        let systemImage: String
        var bundleIdentifiers: [String] = []
        var domains: [String] = []
    }

    private static let communicationSources = [
        CommunicationSource(id: "wechat", title: "WeChat", detail: "App activity", systemImage: "message.fill", bundleIdentifiers: ["com.tencent.xinwechat"]),
        CommunicationSource(id: "messages", title: "Messages", detail: "App activity", systemImage: "message", bundleIdentifiers: ["com.apple.mobilesms"]),
        CommunicationSource(id: "telegram", title: "Telegram", detail: "App activity", systemImage: "paperplane", bundleIdentifiers: ["ru.keepcoder.telegram"]),
        CommunicationSource(id: "whatsapp", title: "WhatsApp", detail: "App and web activity", systemImage: "phone.bubble", bundleIdentifiers: ["net.whatsapp.whatsapp"], domains: ["web.whatsapp.com"]),
        CommunicationSource(id: "slack", title: "Slack", detail: "Work messages", systemImage: "number", bundleIdentifiers: ["com.tinyspeck.slackmacgap"]),
        CommunicationSource(id: "outlook", title: "Outlook", detail: "Work email", systemImage: "envelope", bundleIdentifiers: ["com.microsoft.outlook"]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Screen History").font(AQDesign.TypeToken.heading)
                Text("Screen History stays on this Mac. Only moments you save to Vault are copied out.")
                    .font(AQDesign.TypeToken.body)
                    .foregroundStyle(.secondary)
                Text("Capture is locked until the privacy review and seven-day test pass.")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(.secondary)

                Toggle("Search existing Coast history", isOn: viewModel.settingsBinding(\.searchLegacyCoastHistory))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Communication history")
                        .font(AQDesign.TypeToken.subheading)
                    Text("Choose which sources can appear in Screen History search and Coast import.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Self.communicationSources) { source in
                            HStack(spacing: 10) {
                                Image(systemName: source.systemImage)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.title)
                                        .font(AQDesign.TypeToken.body.weight(.medium))
                                    Text(source.detail)
                                        .font(AQDesign.TypeToken.metadata)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle(
                                    "Include \(source.title)",
                                    isOn: communicationBinding(source)
                                )
                                .labelsHidden()
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            if source.id != Self.communicationSources.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: AQDesign.cardCornerRadius)
                            .fill(AQDesign.ColorToken.surfaceFill)
                    )
                }


                VStack(alignment: .leading, spacing: 8) {
                    Text("Import from Coast")
                        .font(AQDesign.TypeToken.subheading)
                    Text("Review the counts before importing. Quick Launch copies only allowed text and verified media. Coast stays unchanged.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Freeze Coast source") {
                            Task { await viewModel.screenHistory.freezeCoastSourceForImport() }
                        }
                        .disabled(
                            viewModel.screenHistory.coastFreezeIsRunning
                                || viewModel.screenHistory.coastImportIsRunning
                        )
                        Button("Preview Coast import") {
                            Task { await viewModel.screenHistory.previewCoastImport() }
                        }
                        .disabled(
                            viewModel.screenHistory.coastImportIsRunning
                                || viewModel.screenHistory.coastImportState == .unavailable
                        )
                        Button("Import reviewed Coast history") {
                            Task { await viewModel.screenHistory.importCoastHistory() }
                        }
                        .disabled(
                            viewModel.screenHistory.coastImportIsRunning
                                || !viewModel.screenHistory.coastImportCanImport
                        )
                        if viewModel.screenHistory.coastImportIsRunning {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Coast preview or import in progress")
                        }
                        Spacer()
                    }
                    if let message = viewModel.screenHistory.coastFreezeMessage {
                        Text(message)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Coast freeze status")
                    }
                    if let message = viewModel.screenHistory.coastImportMessage {
                        Text(message)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Coast import status")
                    }
                    HStack {
                        Button("Review imported moments") {
                            Task { await viewModel.screenHistory.openRetirementReview() }
                        }
                        .disabled(
                            viewModel.screenHistory.retirementReviewSnapshot?.moments.isEmpty != false
                        )
                        Spacer()
                    }
                    if let message = viewModel.screenHistory.retirementReviewMessage {
                        Text(message)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Coast review status")
                    }
                }

                Divider()

                Toggle(
                    "Enable owned screen capture",
                    isOn: viewModel.settingsBinding(
                        get: { $0.screenHistoryCaptureEnabled },
                        set: { settings, enabled in
                            settings.screenHistoryCaptureEnabled = enabled
                            if !enabled { settings.screenHistoryCaptureConfirmed = false }
                        },
                        onSet: { Task { await viewModel.screenHistory.applyCaptureSettings() } }
                    )
                )
                .disabled(!ScreenHistoryReleasePolicy.allowsOwnedCapture)

                Text("Browser capture remains blocked.")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline) {
                    Text("Status")
                    Spacer()
                    Label(captureStatus, systemImage: captureStatusIcon)
                        .font(AQDesign.TypeToken.body)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("FileVault")
                    Spacer()
                    Label(fileVaultStatus, systemImage: fileVaultStatusIcon)
                        .font(AQDesign.TypeToken.body)
                        .foregroundStyle(.secondary)
                }

                if let blocker = viewModel.screenHistory.captureStartBlocker {
                    Label(blocker, systemImage: "lock.shield")
                        .font(AQDesign.TypeToken.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if viewModel.screenHistory.captureStatus?.lastSkipReason == .screenRecordingNotAuthorized {
                    Button("Allow Screen Recording") {
                        Task { await viewModel.screenHistory.requestScreenRecordingAuthorization() }
                    }
                }

                Toggle(
                    "I accept that other software running as my Mac user could read stored OCR",
                    isOn: viewModel.settingsBinding(
                        get: { $0.screenHistorySameUserAccessRiskAccepted },
                        set: { settings, accepted in
                            settings.screenHistorySameUserAccessRiskAccepted = accepted
                            if !accepted { settings.screenHistoryCaptureConfirmed = false }
                        },
                        onSet: { Task { await viewModel.screenHistory.applyCaptureSettings() } }
                    )
                )
                Text("Screen History files are private to your macOS account, but they are not app-encrypted.")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let message = viewModel.screenHistory.soakMessage {
                    Label(message, systemImage: "calendar.badge.clock")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Screen History soak status. \(message)")
                }

                Divider()

                HStack {
                    Text("Keep history for")
                    Spacer()
                    Picker("Keep history for", selection: Binding(
                        get: { viewModel.screenHistory.retentionDaysSelection },
                        set: { viewModel.screenHistory.retentionDaysSelection = $0 }
                    )) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                HStack {
                    Text("Storage limit")
                    Spacer()
                    Picker("Storage limit", selection: Binding(
                        get: { viewModel.screenHistory.storageCapGBSelection },
                        set: { viewModel.screenHistory.storageCapGBSelection = $0 }
                    )) {
                        Text("5 GB").tag(5)
                        Text("10 GB").tag(10)
                        Text("20 GB").tag(20)
                        Text("50 GB").tag(50)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                if let message = viewModel.screenHistory.retentionMessage {
                    Text(message)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Apply reviewed retention limits") {
                    Task { await viewModel.screenHistory.applyReviewedRetention() }
                }
                .disabled(viewModel.screenHistory.pendingRetentionPolicy == nil)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Excluded applications")
                        .font(AQDesign.TypeToken.subheading)
                    Text("Add one app bundle ID per line, such as com.apple.Safari. Protected apps stay excluded.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: exclusionBinding)
                        .font(AQDesign.TypeToken.code)
                        .frame(minHeight: exclusionEditorMinHeight)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius).fill(AQDesign.ColorToken.keyCapFill))
                        .accessibilityLabel("Excluded application bundle identifiers")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Excluded websites")
                        .font(AQDesign.TypeToken.subheading)
                    Text("Enter one domain per line. These rules filter existing history and legacy migration. Browser capture remains unavailable.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: domainExclusionBinding)
                        .font(AQDesign.TypeToken.code)
                        .frame(minHeight: exclusionEditorMinHeight)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius).fill(AQDesign.ColorToken.keyCapFill))
                        .accessibilityLabel("Excluded website domains")
                }

                Divider()

                if ScreenHistoryReleasePolicy.allowsOwnedCapture {
                    Text("Start only after you review the retention and exclusion rules above. Quick Launch asks again after every launch.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Start capture") {
                            Task { await viewModel.screenHistory.confirmAndStartCapture() }
                        }
                        .disabled(
                            !viewModel.settings.screenHistoryCaptureEnabled
                                || viewModel.screenHistory.captureStartBlocker != nil
                        )
                        Button("Stop capture") {
                            Task { await viewModel.screenHistory.stopCapture() }
                        }
                        .disabled(!viewModel.screenHistory.captureIsActive)
                        Spacer()
                    }
                } else {
                    Text("Start and Stop controls will appear only after the live privacy and soak gates pass in a later release.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            viewModel.screenHistory.noteSettingsPresented()
            await viewModel.screenHistory.applyCaptureSettings()
            await viewModel.screenHistory.refreshCoastImportAvailability()
            await viewModel.screenHistory.refreshCoastFreezeReceipt()
            await viewModel.screenHistory.refreshRetirementReview()
        }
    }

    private var captureStatus: String {
        viewModel.screenHistory.captureStatusLabel
    }

    private func communicationBinding(_ source: CommunicationSource) -> Binding<Bool> {
        viewModel.settingsBinding(
            get: {
                $0.screenHistoryIncludes(
                    bundleIdentifiers: source.bundleIdentifiers,
                    domains: source.domains
                )
            },
            set: { settings, included in
                viewModel.screenHistory.invalidateCoastImportPreview()
                settings.setScreenHistoryIncluded(
                    included,
                    bundleIdentifiers: source.bundleIdentifiers,
                    domains: source.domains
                )
            },
            onSet: { Task { await viewModel.screenHistory.applyCaptureSettings() } }
        )
    }

    private var fileVaultStatus: String {
        switch viewModel.screenHistory.captureStatus?.fileVaultStatus {
        case .on: return "On"
        case .off: return "Off"
        case .unknown, nil: return "Not verified"
        }
    }

    private var fileVaultStatusIcon: String {
        switch viewModel.screenHistory.captureStatus?.fileVaultStatus {
        case .on: return "checkmark.shield"
        case .off: return "xmark.shield"
        case .unknown, nil: return "questionmark.diamond"
        }
    }

    private var captureStatusIcon: String {
        switch viewModel.screenHistory.captureStatus?.state {
        case .running: "record.circle"
        case .pausedForInactivity: "pause.circle"
        case .stopped, .disabled, nil: "stop.circle"
        }
    }

    private var exclusionBinding: Binding<String> {
        viewModel.settingsBinding(
            get: { $0.screenHistoryExcludedBundleIDs.sorted().joined(separator: "\n") },
            set: { settings, value in
                let ids = value.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
                let normalized = Array(Set(ids)).sorted()
                if normalized != settings.screenHistoryExcludedBundleIDs {
                    viewModel.screenHistory.invalidateCoastImportPreview()
                }
                settings.screenHistoryExcludedBundleIDs = normalized
            },
            onSet: { Task { await viewModel.screenHistory.applyCaptureSettings() } }
        )
    }

    private var domainExclusionBinding: Binding<String> {
        viewModel.settingsBinding(
            get: { $0.screenHistoryExcludedDomains.sorted().joined(separator: "\n") },
            set: { settings, value in
                let domains = value
                    .split(whereSeparator: \.isWhitespace)
                    .compactMap { ScreenHistoryCaptureConfiguration.normalizedDomain(String($0)) }
                let normalized = Array(Set(domains)).sorted()
                if normalized != settings.screenHistoryExcludedDomains {
                    viewModel.screenHistory.invalidateCoastImportPreview()
                }
                settings.screenHistoryExcludedDomains = normalized
            },
            onSet: { Task { await viewModel.screenHistory.applyCaptureSettings() } }
        )
    }
}
