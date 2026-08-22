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
                    Toggle("Keep text clipboard history", isOn: $viewModel.settings.clipboardHistoryEnabled)
                        .onChange(of: viewModel.settings.clipboardHistoryEnabled) { _, _ in saveClipboardSettings() }
                    Stepper(
                        "Keep \(viewModel.settings.clipboardHistoryLimit) items (pinned items never expire)",
                        value: $viewModel.settings.clipboardHistoryLimit,
                        in: 10...200,
                        step: 10
                    )
                    .onChange(of: viewModel.settings.clipboardHistoryLimit) { _, _ in saveClipboardSettings() }
                    HStack {
                        Text("Open Clipboard History")
                        Spacer()
                        HotkeyRecorderView(
                            keyCode: Binding(
                                get: { viewModel.settings.clipboardHistoryHotkey.keyCode },
                                set: { viewModel.settings.clipboardHistoryHotkey.keyCode = $0 }
                            ),
                            modifiers: Binding(
                                get: { viewModel.settings.clipboardHistoryHotkey.modifiers },
                                set: { viewModel.settings.clipboardHistoryHotkey.modifiers = $0 }
                            ),
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
                    Text("In the list: ⌘⇧P pins an entry to the top, ⌘⇧N saves it as a snippet, ⌘⇧L saves it as a Quick Link, ⌃X deletes it.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Quick Links") {
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
                    Text("Applies to every Quick Link. Links with {{input}} ask for text first.")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                }

                section("Tuna stores") {
                    HStack {
                        Label("\(viewModel.snippets.count) snippets", systemImage: "text.quote")
                        Label("\(viewModel.quickLinks.count) Quick Links", systemImage: "link")
                        Spacer()
                        Button("Reload") { viewModel.reloadTunaCatalogs() }
                    }
                    .font(AQDesign.TypeToken.label)
                    Text("Snippets and Quick Links are read live from Tuna's files. Edits, new snippets, and new links are written back there with a backup.")
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

    private var browserSelection: Binding<String> {
        Binding(
            get: { viewModel.settings.quickLinkBrowserBundleID ?? "" },
            set: { value in
                viewModel.settings.quickLinkBrowserBundleID = value.isEmpty ? nil : value
                viewModel.settings.save()
            }
        )
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func saveClipboardSettings() {
        viewModel.settings.save()
        NotificationCenter.default.post(name: .clipboardHistorySettingsChanged, object: nil)
    }
}
