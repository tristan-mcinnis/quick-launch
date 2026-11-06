import SwiftUI

/// One binding and one picker in General → Chat and Models → Web search.
struct WebSearchProviderRow: View {
    @Bindable var viewModel: QuickViewModel
    var isFirst = false
    @State private var missingKey = false

    var body: some View {
        let provider = viewModel.settings.webSearchProvider
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
        .task(id: provider) { missingKey = WebSearchKeys.isMissingKey(for: provider) }
        if missingKey {
            CardNote {
                CardText(
                    "\(provider.title) has no API key, so web search will fail. Add one under Models › Web search, or choose Automatic.",
                    tone: AQDesign.ColorToken.danger
                )
            }
        }
    }
}
