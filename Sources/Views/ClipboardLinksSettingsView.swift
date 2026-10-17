import AppKit
import SwiftUI
import HouseDesign

/// Clipboard History retention and hotkey, plus where Quick Links open.
/// One card per group, 40 pt rows, ink toggles.
struct ClipboardLinksSettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var browsers: [LaunchableApplication] = []
    @State private var newDisabledSource = ""
    @State private var newScreenshotFolder = ""
    @State private var confirmsClipboardClear = false

    var body: some View {
        SettingsPaneScroller(pane: .clipboard) {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                clipboardCard.settingsAnchor("clipboard.history")
                screenshotsCard.settingsAnchor("clipboard.screenshots")
                screenTextCard.settingsAnchor("clipboard.screenText")
                quicklinksCard.settingsAnchor("clipboard.quicklinks")
                catalogCard.settingsAnchor("clipboard.catalog")
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, House.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { browsers = QuickViewModel.installedBrowsers }
        .alert("Clear Clipboard History?", isPresented: $confirmsClipboardClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Everything", role: .destructive) {
                viewModel.clearClipboardHistory()
            }
        } message: {
            Text("This deletes every saved clipboard entry, including pinned ones. It cannot be undone here.")
        }
    }

    private var clipboardCard: some View {
        SettingsCard("Clipboard History") {
            SettingsRow(title: "Keep text clipboard history", isFirst: true) {
                Toggle(
                    "Keep text clipboard history",
                    isOn: viewModel.settingsBinding(\.clipboardHistoryEnabled) { _ in
                        notifyClipboardSettingsChanged()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(
                title: "Keep \(viewModel.settings.clipboardHistoryLimit) items (pinned items never expire)"
            ) {
                Stepper(
                    "Keep \(viewModel.settings.clipboardHistoryLimit) items (pinned items never expire)",
                    value: viewModel.settingsBinding(\.clipboardHistoryLimit) { _ in
                        notifyClipboardSettingsChanged()
                    },
                    in: 10...200,
                    step: 10
                )
                .labelsHidden()
            }

            SettingsRow(title: "Open Clipboard History") {
                HotkeyRecorderView(
                    keyCode: viewModel.settingsBinding(\.clipboardHistoryHotkey.keyCode),
                    modifiers: viewModel.settingsBinding(\.clipboardHistoryHotkey.modifiers),
                    label: "Open Clipboard History",
                    showsLabel: false,
                    changeNotification: .clipboardHistorySettingsChanged
                )
            }
            if let conflict = viewModel.settings.clipboardHistoryHotkeyConflict()
                ?? viewModel.clipboardHistoryHotkeyRegistrationError {
                CardNote { CardText(conflict, tone: AQDesign.ColorToken.danger) }
            }

            SettingsRow(title: "Keep copies for") {
                Picker("Keep copies for", selection: viewModel.settingsBinding(\.clipboardHistoryRetention) { _ in
                    notifyClipboardSettingsChanged()
                }) {
                    ForEach(ClipboardRetention.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }

            SettingsRow(title: "Keep a source tag on each copy") {
                Toggle(
                    "Keep a source tag on each copy",
                    isOn: viewModel.settingsBinding(\.clipboardHistorySourceTags) { _ in
                        notifyClipboardSettingsChanged()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Read text from copied images (on-device)") {
                Toggle(
                    "Read text from copied images (on-device)",
                    isOn: viewModel.settingsBinding(\.clipboardHistoryOCR) { _ in
                        notifyClipboardSettingsChanged()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Text recognition") {
                Picker("Text recognition", selection: viewModel.settingsBinding(\.clipboardHistoryOCRMode) { _ in
                    notifyClipboardSettingsChanged()
                }) {
                    ForEach(ClipboardOCRMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(!viewModel.settings.clipboardHistoryOCR)
            }

            SettingsRow(title: "Include copies from Universal Clipboard") {
                Toggle(
                    "Include copies from Universal Clipboard",
                    isOn: viewModel.settingsBinding(\.clipboardHistoryCaptureRemote) { _ in
                        notifyClipboardSettingsChanged()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(
                title: "Skip copies from these apps",
                detail: "Bundle identifiers, for example com.apple.Passwords. A copy is skipped when one of these apps is in front when the copy is observed (a once-a-second check); existing history is not purged. Concealed and transient copies are always skipped."
            ) {
                HStack(spacing: House.Spacing.xs) {
                    TextField("com.example.app", text: $newDisabledSource)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                        .onSubmit { addDisabledSource() }
                    Button("Add") { addDisabledSource() }
                        .disabled(newDisabledSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            ForEach(viewModel.settings.clipboardHistoryDisabledSourceBundleIDs, id: \.self) { bundleID in
                SettingsRow(title: bundleID) {
                    Button {
                        removeDisabledSource(bundleID)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(bundleID)")
                }
            }

            SettingsRow(title: "\(viewModel.clipboardEntries.count) saved text items") {
                Button("Clear Clipboard History…", role: .destructive) {
                    confirmsClipboardClear = true
                }
            }

            CardNote {
                CardText("In the list: \u{2318}\u{21E7}P pins an entry, \u{2318}\u{21E7}N saves a snippet, \u{2318}\u{21E7}L creates a Quicklink, and \u{2303}X deletes it.")
            }
        }
    }

    private var screenshotsCard: some View {
        SettingsCard("Screenshots") {
            SettingsRow(
                title: "Include every image and video in these folders",
                detail: "Off lists only files whose name looks like a capture. A video is never pasted or attached as an image.",
                isFirst: true
            ) {
                Toggle(
                    "Include every image and video in these folders",
                    isOn: viewModel.settingsBinding(\.screenshotIncludeAllMedia) { _ in
                        viewModel.invalidateLauncherRanking()
                    }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Layout") {
                Picker("Layout", selection: viewModel.settingsBinding(\.screenshotUseGrid) { _ in
                    viewModel.invalidateLauncherRanking()
                }) {
                    Text("List").tag(false)
                    Text("Grid").tag(true)
                }
                .labelsHidden()
                .frame(width: 120)
            }

            SettingsRow(title: "Text recognition") {
                Picker("Text recognition", selection: viewModel.settingsBinding(\.screenshotOCRMode) { mode in
                    viewModel.reindexScreenshotText(mode: mode)
                }) {
                    ForEach(ClipboardOCRMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            if viewModel.settings.screenshotUseGrid {
                SettingsRow(title: "Grid columns") {
                    Stepper(
                        "Grid columns",
                        value: viewModel.settingsBinding(\.screenshotColumns) { _ in
                            viewModel.invalidateLauncherRanking()
                        },
                        in: 2...6
                    )
                    .labelsHidden()
                }
            }

            SettingsRow(
                title: "Add a folder to browse",
                detail: "The system screenshot folder is always included. Only these folders are scanned, never your whole home."
            ) {
                HStack(spacing: House.Spacing.xs) {
                    TextField("~/Pictures/Captures", text: $newScreenshotFolder)
                        .textFieldStyle(.plain)
                        .frame(width: 200)
                        .onSubmit { addScreenshotFolder() }
                    Button("Add") { addScreenshotFolder() }
                        .disabled(newScreenshotFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            ForEach(viewModel.settings.screenshotFolders, id: \.self) { path in
                SettingsRow(title: path) {
                    Button {
                        removeScreenshotFolder(path)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(path)")
                }
            }

            CardNote {
                CardText("Saving a capture from the composer writes a new PNG here; nothing existing is overwritten or deleted, and pins are never expired.")
            }

            CardNote {
                CardText("Annotate in Preview works on a fresh copy. Annotation copies live in Application Support and are yours to edit and keep; Quick Launch never deletes or overwrites them, and never touches the original.")
            }
        }
    }

    private var screenTextCard: some View {
        SettingsCard("Text from Screen") {
            SettingsRow(title: "Keep line breaks in text read from the screen", isFirst: true) {
                Toggle(
                    "Keep line breaks in text read from the screen",
                    isOn: viewModel.settingsBinding(\.ocrKeepLineBreaks)
                )
                .toggleStyle(InkToggleStyle())
            }

            CardNote {
                CardText("Off joins the recognized lines into one paragraph, which suits prose. On keeps code and lists as they were laid out.")
            }
        }
    }

    private var quicklinksCard: some View {
        SettingsCard("Quicklinks") {
            SettingsRow(title: "Open links in", isFirst: true) {
                Picker("Open links in", selection: browserSelection) {
                    Text("Default browser").tag("")
                    ForEach(browsers) { browser in
                        Text(browser.name).tag(browser.bundleIdentifier ?? "")
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }

            CardNote {
                CardText("Applies to every Quicklink. Links with {{input}} ask for text first.")
            }
        }
    }

    private var catalogCard: some View {
        SettingsCard("Snippets & Quicklinks") {
            CardNote(isFirst: true) {
                HStack(spacing: House.Spacing.md) {
                    Label("\(viewModel.snippets.count) snippets", systemImage: "text.quote")
                    Label("\(viewModel.quickLinks.count) Quicklinks", systemImage: "link")
                    Spacer(minLength: House.Spacing.sm)
                    Button("Reload") { viewModel.reloadLauncherCatalog() }
                }
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            CardNote {
                if let loadError = viewModel.launcherCatalogErrorMessage {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(AQDesign.TypeToken.body)
                        .foregroundStyle(AQDesign.ColorToken.warning)
                } else {
                    CardText("Stored privately on this Mac by Quick Launch. Legacy Tuna items are imported once when available.")
                }
            }
        }
    }

    private var browserSelection: Binding<String> {
        viewModel.settingsBinding(
            get: { $0.quickLinkBrowserBundleID ?? "" },
            set: { settings, value in settings.quickLinkBrowserBundleID = value.isEmpty ? nil : value }
        )
    }

    private func notifyClipboardSettingsChanged() {
        NotificationCenter.default.post(name: .clipboardHistorySettingsChanged, object: nil)
    }

    private func addDisabledSource() {
        let trimmed = newDisabledSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        newDisabledSource = ""
        viewModel.updateSettings { settings in
            if !settings.clipboardHistoryDisabledSourceBundleIDs.contains(trimmed) {
                settings.clipboardHistoryDisabledSourceBundleIDs.append(trimmed)
            }
        }
        notifyClipboardSettingsChanged()
    }

    private func removeDisabledSource(_ bundleID: String) {
        viewModel.updateSettings { settings in
            settings.clipboardHistoryDisabledSourceBundleIDs.removeAll { $0 == bundleID }
        }
        notifyClipboardSettingsChanged()
    }

    private func addScreenshotFolder() {
        let trimmed = newScreenshotFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        newScreenshotFolder = ""
        viewModel.updateSettings { settings in
            if !settings.screenshotFolders.contains(trimmed) {
                settings.screenshotFolders.append(trimmed)
            }
        }
        viewModel.invalidateLauncherRanking()
    }

    private func removeScreenshotFolder(_ path: String) {
        viewModel.updateSettings { settings in
            settings.screenshotFolders.removeAll { $0 == path }
        }
        viewModel.invalidateLauncherRanking()
    }
}
