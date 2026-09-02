import AppKit
import SwiftUI

/// Clipboard History retention and hotkey, plus where Quick Links open.
struct ClipboardLinksSettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var browsers: [LaunchableApplication] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Clipboard History") {
                    Toggle(
                        "Keep text clipboard history",
                        isOn: viewModel.settingsBinding(\.clipboardHistoryEnabled) { _ in notifyClipboardSettingsChanged() }
                    )
                    Stepper(
                        "Keep \(viewModel.settings.clipboardHistoryLimit) items (pinned items never expire)",
                        value: viewModel.settingsBinding(\.clipboardHistoryLimit) { _ in notifyClipboardSettingsChanged() },
                        in: 10...200,
                        step: 10
                    )
                    HStack {
                        Text("Open Clipboard History")
                        Spacer()
                        HotkeyRecorderView(
                            keyCode: viewModel.settingsBinding(\.clipboardHistoryHotkey.keyCode),
                            modifiers: viewModel.settingsBinding(\.clipboardHistoryHotkey.modifiers),
                            label: "",
                            changeNotification: .clipboardHistorySettingsChanged
                        )
                        .frame(width: 200)
                    }
                    if let conflict = viewModel.settings.clipboardHistoryHotkeyConflict()
                        ?? viewModel.clipboardHistoryHotkeyRegistrationError {
                        Text(conflict).font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.danger)
                    }
                    HStack {
                        Text("\(viewModel.clipboardEntries.count) saved text items")
                            .font(AQDesign.TypeToken.label)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear Clipboard History", role: .destructive) {
                            viewModel.clearClipboardHistory()
                        }
                    }
                    Text("In the list: ⌘⇧P pins an entry, ⌘⇧N saves a snippet, ⌘⇧L creates a Quicklink, and ⌃X deletes it.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Colors") {
                    HStack {
                        Text("Copy picked colors as")
                        Spacer()
                        Picker("", selection: colorFormatSelection) {
                            ForEach(ColorFormat.allCases) { format in
                                Text("\(format.title)  ·  \(format.sample)").tag(format)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                    Stepper(
                        "Keep \(viewModel.settings.colorHistoryLimit) picked colors (pinned colors never expire)",
                        value: viewModel.settingsBinding(\.colorHistoryLimit),
                        in: 10...200,
                        step: 10
                    )
                    HStack {
                        Text("\(viewModel.colorItems.count) saved colors")
                            .font(AQDesign.TypeToken.label)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear Colors", role: .destructive) {
                            viewModel.clearColorHistory()
                        }
                    }
                    Text("Run \u{201C}Pick Color from Screen\u{201D} to magnify any pixel on any display. In the Colors list: ⌘1…⌘4 copy the other notations, ⌘⇧P pins, and ⌃X deletes.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Emoji & Symbols") {
                    HStack {
                        Text("Skin tone")
                        Spacer()
                        Picker("", selection: skinToneSelection) {
                            ForEach(Array(EmojiCatalog.skinToneTitles.enumerated()), id: \.offset) { index, title in
                                Text("\(EmojiCatalog.applyingSkinTone(index, to: "\u{1F44D}"))  \(title)").tag(index)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    Text("Applies to the emoji that accept a tone. Symbols, flags, and objects are unchanged.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Text from Screen") {
                    Toggle("Keep line breaks in text read from the screen", isOn: viewModel.settingsBinding(\.ocrKeepLineBreaks))
                    Text("Off joins the recognized lines into one paragraph, which suits prose. On keeps code and lists as they were laid out.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Quicklinks") {
                    HStack {
                        Text("Open links in")
                        Spacer()
                        Picker("", selection: browserSelection) {
                            Text("Default browser").tag("")
                            ForEach(browsers) { browser in
                                Text(browser.name).tag(browser.bundleIdentifier ?? "")
                            }
                        }
                        .labelsHidden()
                        .frame(width: 240)
                    }
                    Text("Applies to every Quicklink. Links with {{input}} ask for text first.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                }

                section("Tuna stores") {
                    HStack {
                        Label("\(viewModel.snippets.count) snippets", systemImage: "text.quote")
                        Label("\(viewModel.quickLinks.count) Quicklinks", systemImage: "link")
                        Spacer()
                        Button("Reload") { viewModel.reloadTunaCatalogs() }
                    }
                    .font(AQDesign.TypeToken.label)
                    Text("Snippets and Quicklinks are read live from Tuna. Edits are written back with a backup.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(AQDesign.Space.window)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { browsers = QuickViewModel.installedBrowsers }
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

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AQDesign.TypeToken.heading)
            content()
        }
    }

    private func notifyClipboardSettingsChanged() {
        NotificationCenter.default.post(name: .clipboardHistorySettingsChanged, object: nil)
    }
}
