import SwiftUI

/// One binding and one picker in General → Chat and Models → Web search.
struct WebSearchProviderRow: View {
    @Bindable var viewModel: QuickViewModel
    var isFirst = false

    var body: some View {
        SettingsRow(
            title: "Search provider",
            detail: viewModel.settings.webSearchProvider.detail,
            isFirst: isFirst
        ) {
            Picker("Search provider", selection: viewModel.settingsBinding(\.webSearchProvider)) {
                ForEach(WebSearchProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Web search provider")
        }
    }
}
