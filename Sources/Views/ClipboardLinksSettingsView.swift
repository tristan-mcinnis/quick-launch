import AppKit
import SwiftUI

/// Clipboard History retention and hotkey, plus where Quick Links open.
/// One card per group, 40 pt rows, ink toggles.
struct ClipboardLinksSettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var browsers: [LaunchableApplication] = []

    var body: some View {
        SettingsPaneScroller(pane: .clipboard) {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                clipboardCard.settingsAnchor("clipboard.history")
                colorsCard.settingsAnchor("clipboard.colors")
                emojiCard.settingsAnchor("clipboard.emoji")
                screenTextCard.settingsAnchor("clipboard.screenText")
                quicklinksCard.settingsAnchor("clipboard.quicklinks")
                catalogCard.settingsAnchor("clipboard.catalog")
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, House.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { browsers = QuickViewModel.installedBrowsers }
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

            SettingsRow(title: "\(viewModel.clipboardEntries.count) saved text items") {
                Button("Clear Clipboard History", role: .destructive) {
                    viewModel.clearClipboardHistory()
                }
            }

            CardNote {
                CardText("In the list: \u{2318}\u{21E7}P pins an entry, \u{2318}\u{21E7}N saves a snippet, \u{2318}\u{21E7}L creates a Quicklink, and \u{2303}X deletes it.")
            }
        }
    }

    private var colorsCard: some View {
        SettingsCard("Colors") {
            SettingsRow(title: "Copy picked colors as", isFirst: true) {
                Picker("Copy picked colors as", selection: colorFormatSelection) {
                    ForEach(ColorFormat.allCases) { format in
                        Text("\(format.title)  \u{00B7}  \(format.sample)").tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            SettingsRow(
                title: "Keep \(viewModel.settings.colorHistoryLimit) picked colors (pinned colors never expire)"
            ) {
                Stepper(
                    "Keep \(viewModel.settings.colorHistoryLimit) picked colors (pinned colors never expire)",
                    value: viewModel.settingsBinding(\.colorHistoryLimit),
                    in: 10...200,
                    step: 10
                )
                .labelsHidden()
            }

            SettingsRow(title: "\(viewModel.colorItems.count) saved colors") {
                Button("Clear Colors", role: .destructive) {
                    viewModel.clearColorHistory()
                }
            }

            CardNote {
                CardText("Run \u{201C}Pick Color from Screen\u{201D} to magnify any pixel on any display. In the Colors list: \u{2318}1…\u{2318}4 copy the other notations, \u{2318}\u{21E7}P pins, and \u{2303}X deletes.")
            }
        }
    }

    private var emojiCard: some View {
        SettingsCard("Emoji & Symbols") {
            SettingsRow(title: "Skin tone", isFirst: true) {
                Picker("Skin tone", selection: skinToneSelection) {
                    ForEach(Array(EmojiCatalog.skinToneTitles.enumerated()), id: \.offset) { index, title in
                        Text("\(EmojiCatalog.applyingSkinTone(index, to: "\u{1F44D}"))  \(title)").tag(index)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            CardNote {
                CardText("Applies to the emoji that accept a tone. Symbols, flags, and objects are unchanged.")
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

    private var colorFormatSelection: Binding<ColorFormat> {
        Binding(
            get: { viewModel.settings.colorFormat },
            set: { viewModel.applyColorFormat($0) }
        )
    }

    private var skinToneSelection: Binding<Int> {
        viewModel.settingsBinding(\.emojiSkinTone) { _ in viewModel.invalidateLauncherRanking() }
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
}
