import SwiftUI

/// Canonical chat retention is keep-all. Legacy history flags and cache
/// limits remain decodable for rollback, but are not retention controls.
struct HistorySettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var confirmsDeletion = false

    var body: some View {
        SettingsCard("History") {
            SettingsRow(
                title: "Saved chats and sources",
                detail: "Submitted chats and sources stay on this Mac until you delete them. Unsent attachments are not saved.",
                isFirst: true
            ) {
                Text("Keep all")
                    .font(House.TypeToken.meta)
                    .foregroundStyle(House.ColorToken.textSecondary)
            }

            if viewModel.archiveDamagedCount > 0 {
                SettingsRow(
                    title: "Saved chats need attention",
                    detail: "\(viewModel.archiveDamagedCount) records could not be fully read. Their files are kept; nothing is silently replaced."
                ) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(House.ColorToken.warning)
                }
            }

            SettingsRow(
                title: "Delete saved chats",
                detail: "Removes saved chats and their unshared copies. Original files and Clipboard History are kept."
            ) {
                Button(viewModel.isClearingHistory ? "Deleting…" : "Delete all saved chats…", role: .destructive) {
                    confirmsDeletion = true
                }
                .disabled(viewModel.isClearingHistory)
            }

            if let error = viewModel.savedHistoryOperationError {
                SettingsRow(title: "Could not finish deletion", detail: error) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(House.ColorToken.danger)
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
        .alert("Delete all saved chats?", isPresented: $confirmsDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete all saved chats", role: .destructive) {
                viewModel.clearHistory()
            }
        } message: {
            Text("This deletes Quick AI and AI Chat history and the saved sources no other chat uses. It cannot be undone here. Original files and Clipboard History are not deleted.")
        }
    }
}
