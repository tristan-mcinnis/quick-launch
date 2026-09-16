import SwiftUI
import AppKit

/// The Screen History settings tab: sources, Coast import, capture, and
/// retention, one card per group. Every action goes through
/// `viewModel.screenHistory`.
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
        SettingsPaneScroller(pane: .screenHistory) {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                introCard
                sourcesCard.settingsAnchor("screenHistory.sources")
                communicationCard
                coastCard
                captureCard.settingsAnchor("screenHistory.capture")
                retentionCard.settingsAnchor("screenHistory.retention")
                excludedApplicationsCard.settingsAnchor("screenHistory.excludedApplications")
                excludedWebsitesCard.settingsAnchor("screenHistory.excludedWebsites")
                captureControlCard
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, House.Spacing.md)
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

    private var introCard: some View {
        SettingsCard {
            CardNote(isFirst: true) {
                Text("Screen History stays on this Mac. Only moments you save to Vault are copied out.")
                    .font(AQDesign.TypeToken.body)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            CardNote {
                CardText("Capture is locked until the privacy review and seven-day test pass.")
            }
        }
    }

    private var sourcesCard: some View {
        SettingsCard("Sources") {
            SettingsRow(title: "Search existing Coast history", isFirst: true) {
                Toggle(
                    "Search existing Coast history",
                    isOn: viewModel.settingsBinding(\.searchLegacyCoastHistory)
                )
                .toggleStyle(InkToggleStyle())
            }
        }
    }

    private var communicationCard: some View {
        SettingsCard("Communication history") {
            CardNote(isFirst: true) {
                CardText("Choose which sources can appear in Screen History search and Coast import.")
            }
            ForEach(Self.communicationSources) { source in
                VStack(spacing: 0) {
                    HouseDivider()
                    HStack(spacing: House.Spacing.sm) {
                        IconTile {
                            Image(systemName: source.systemImage)
                                .font(AQDesign.TypeToken.caption)
                                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                                .font(AQDesign.TypeToken.label)
                                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                            Text(source.detail)
                                .font(AQDesign.TypeToken.caption)
                                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        }
                        Spacer(minLength: House.Spacing.sm)
                        Toggle(
                            "Include \(source.title)",
                            isOn: communicationBinding(source)
                        )
                        .toggleStyle(InkToggleStyle())
                    }
                    .frame(minHeight: AQDesign.rowHeight)
                }
            }
        }
    }

    private var coastCard: some View {
        SettingsCard("Import from Coast") {
            CardNote(isFirst: true) {
                CardText("Review the counts before importing. Quick Launch copies only allowed text and verified media. Coast stays unchanged.")
            }

            CardNote {
                HStack(spacing: AQDesign.Space.standard) {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let message = viewModel.screenHistory.coastFreezeMessage {
                CardNote {
                    CardText(message).accessibilityLabel("Coast freeze status")
                }
            }
            if let message = viewModel.screenHistory.coastImportMessage {
                CardNote {
                    CardText(message).accessibilityLabel("Coast import status")
                }
            }

            CardNote {
                Button("Review imported moments") {
                    Task { await viewModel.screenHistory.openRetirementReview() }
                }
                .disabled(
                    viewModel.screenHistory.retirementReviewSnapshot?.moments.isEmpty != false
                )
            }
            if let message = viewModel.screenHistory.retirementReviewMessage {
                CardNote {
                    CardText(message).accessibilityLabel("Coast review status")
                }
            }
        }
    }

    private var captureCard: some View {
        SettingsCard("Capture") {
            SettingsRow(title: "Enable owned screen capture", isFirst: true) {
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
                .toggleStyle(InkToggleStyle())
                .disabled(!ScreenHistoryReleasePolicy.allowsOwnedCapture)
            }

            CardNote { CardText("Browser capture remains blocked.") }

            SettingsRow(title: "Status") {
                statusLine(captureStatus, dot: captureStatusTone)
            }

            SettingsRow(title: "FileVault") {
                statusLine(fileVaultStatus, dot: fileVaultStatusTone)
            }

            if let blocker = viewModel.screenHistory.captureStartBlocker {
                CardNote { CardText(blocker) }
            }

            if viewModel.screenHistory.captureStatus?.lastSkipReason == .screenRecordingNotAuthorized {
                CardNote {
                    Button("Allow Screen Recording") {
                        Task { await viewModel.screenHistory.requestScreenRecordingAuthorization() }
                    }
                }
            }

            SettingsRow(
                title: "I accept that other software running as my Mac user could read stored OCR"
            ) {
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
                .toggleStyle(InkToggleStyle())
            }

            CardNote {
                CardText("Screen History files are private to your macOS account, but they are not app-encrypted.")
            }

            if let message = viewModel.screenHistory.soakMessage {
                CardNote {
                    CardText(message)
                        .accessibilityLabel("Screen History soak status. \(message)")
                }
            }
        }
    }

    private var retentionCard: some View {
        SettingsCard("Retention") {
            SettingsRow(title: "Keep history for", isFirst: true) {
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

            SettingsRow(title: "Storage limit") {
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
                CardNote { CardText(message) }
            }

            CardNote {
                Button("Apply reviewed retention limits") {
                    Task { await viewModel.screenHistory.applyReviewedRetention() }
                }
                .disabled(viewModel.screenHistory.pendingRetentionPolicy == nil)
            }
        }
    }

    private var excludedApplicationsCard: some View {
        SettingsCard("Excluded applications") {
            CardNote(isFirst: true) {
                VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
                    CardText("Add one app bundle ID per line, such as com.apple.Safari. Protected apps stay excluded.")
                    TextEditor(text: exclusionBinding)
                        .font(AQDesign.TypeToken.code)
                        .scrollContentBackground(.hidden)
                        .padding(AQDesign.Space.standard)
                        .frame(minHeight: exclusionEditorMinHeight)
                        .background(fieldBackground)
                        .accessibilityLabel("Excluded application bundle identifiers")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var excludedWebsitesCard: some View {
        SettingsCard("Excluded websites") {
            CardNote(isFirst: true) {
                VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
                    CardText("Enter one domain per line. These rules filter existing history and legacy migration. Browser capture remains unavailable.")
                    TextEditor(text: domainExclusionBinding)
                        .font(AQDesign.TypeToken.code)
                        .scrollContentBackground(.hidden)
                        .padding(AQDesign.Space.standard)
                        .frame(minHeight: exclusionEditorMinHeight)
                        .background(fieldBackground)
                        .accessibilityLabel("Excluded website domains")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var captureControlCard: some View {
        SettingsCard {
            if ScreenHistoryReleasePolicy.allowsOwnedCapture {
                CardNote(isFirst: true) {
                    CardText("Start only after you review the retention and exclusion rules above. Quick Launch asks again after every launch.")
                }
                CardNote {
                    HStack(spacing: AQDesign.Space.standard) {
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                CardNote(isFirst: true) {
                    CardText("Start and Stop controls will appear only after the live privacy and soak gates pass in a later release.")
                }
            }
        }
    }

    /// A status word with its dot. Never colour alone: the word carries it.
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

    /// The house field ground: quiet fill plus a hairline, at `Radius.sm`.
    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: AQDesign.fieldCornerRadius, style: .continuous)
            .fill(AQDesign.ColorToken.surfaceFill)
            .overlay(
                RoundedRectangle(cornerRadius: AQDesign.fieldCornerRadius, style: .continuous)
                    .strokeBorder(AQDesign.ColorToken.tileStroke, lineWidth: AQDesign.hairline)
            )
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

    private var fileVaultStatusTone: Color {
        switch viewModel.screenHistory.captureStatus?.fileVaultStatus {
        case .on: return AQDesign.ColorToken.success
        case .off: return AQDesign.ColorToken.danger
        case .unknown, nil: return AQDesign.ColorToken.warning
        }
    }

    private var captureStatusTone: Color {
        switch viewModel.screenHistory.captureStatus?.state {
        case .running: AQDesign.ColorToken.success
        case .pausedForInactivity: AQDesign.ColorToken.warning
        case .stopped, .disabled, nil: AQDesign.ColorToken.danger
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
