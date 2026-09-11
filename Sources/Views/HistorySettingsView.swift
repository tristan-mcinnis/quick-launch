import SwiftUI

/// The History card in the General pane: whether chats are kept, how many
/// unpinned chats stay (`QuickSettings.historyLimit`, bounded by
/// `QuickHistoryStore`; pinned chats are never pruned), Clear history, and
/// how long the launcher keeps its place after closing.
struct HistorySettingsView: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        SettingsCard("History") {
            SettingsRow(
                title: "Keep chat history",
                detail: "Chats from Quick AI and AI Chat, kept on this Mac.",
                isFirst: true
            ) {
                Toggle(
                    "Keep chat history",
                    isOn: viewModel.settingsBinding(\.historyEnabled) { enabled in
                        if enabled {
                            viewModel.loadHistory()
                        } else {
                            viewModel.history = []
                        }
                    }
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(
                title: "Chats to keep",
                detail: "The newest chats stay. Pinned chats are always kept and do not count."
            ) {
                Picker("Chats to keep", selection: historyLimit) {
                    ForEach(viewModel.historyLimitChoices, id: \.self) { limit in
                        Text("\(limit)").tag(limit)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .disabled(!viewModel.settings.historyEnabled)
                .accessibilityLabel("Chats to keep")
            }

            SettingsRow(title: "Saved history") {
                Button("Clear history", role: .destructive) {
                    viewModel.clearHistory()
                }
            }

            SettingsRow(title: "Keep my place after closing") {
                Picker("Keep my place after closing", selection: viewModel.settingsBinding(\.reopenRetentionSeconds)) {
                    Text("Do not keep").tag(0)
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
    }

    /// Chats to keep: a lower limit prunes the oldest unpinned chats now.
    private var historyLimit: Binding<Int> {
        Binding(
            get: { viewModel.settings.historyLimit },
            set: { viewModel.setHistoryLimit($0) }
        )
    }
}
