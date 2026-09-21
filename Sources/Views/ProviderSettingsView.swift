import SwiftUI

/// Provider configuration stays deliberately compact: choose a source, choose
/// a model, and edit only the fields that source needs. One card per group.
struct ProviderSettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var apiKey = ""
    @State private var keyStatus: String?
    @State private var tavilyKey = ""
    @State private var braveKey = ""
    @State private var bochaKey = ""
    @State private var exaKey = ""
    @State private var searchKeyStatus: String?
    @State private var showingManageModels = false

    /// The shared model profiles. A parameter would be better, but this pane
    /// is built by `SettingsView`, which owns the pane list.
    private var preferences: ModelPreferenceStore { .shared }

    private var selectedProviderID: Binding<UUID> {
        Binding(
            get: { viewModel.settings.selectedProviderID },
            set: { viewModel.selectProvider(providerID: $0); loadKey() }
        )
    }

    private var selectedIndex: Int? {
        viewModel.settings.providers.firstIndex {
            $0.id == viewModel.settings.selectedProviderID
        }
    }

    private var provider: InferenceProvider? {
        guard let selectedIndex else { return nil }
        return viewModel.settings.providers[selectedIndex]
    }

    var body: some View {
        Group {
            if showingManageModels {
                ManageModelsView(viewModel: viewModel) { showingManageModels = false }
            } else {
                providerPane
            }
        }
    }

    private var providerPane: some View {
        SettingsPaneScroller(pane: .models) {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                providerCard.settingsAnchor("models.provider")
                visionCard.settingsAnchor("models.vision")
                webSearchCard.settingsAnchor("models.webSearch")
                instructionCard.settingsAnchor("models.instruction")
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, House.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            loadKey()
            loadSearchKeys()
        }
    }

    private var providerCard: some View {
        SettingsCard("Provider") {
            SettingsRow(title: "Provider", isFirst: true) {
                HStack(spacing: House.Spacing.sm) {
                    Picker("Provider", selection: selectedProviderID) {
                        ForEach(viewModel.settings.providers) { item in
                            Label(
                                item.name,
                                systemImage: item.location == .local ? "laptopcomputer" : "cloud"
                            )
                            .tag(item.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 330)
                    Button("Add endpoint") {
                        _ = viewModel.addOpenAICompatibleProvider()
                        loadKey()
                    }
                }
            }

            if let provider, let selectedIndex {
                providerEditor(provider, index: selectedIndex)
            }

            CardNote {
                VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
                    Button("Manage models") { showingManageModels = true }
                        .accessibilityLabel("Manage models")
                    CardText("Every model from every provider, with the switch that hides it from the pickers and its reasoning effort.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func providerEditor(_ provider: InferenceProvider, index: Int) -> some View {
        if !provider.isBuiltIn {
            SettingsRow(title: "Name") {
                TextField("Provider name", text: providerBinding(index, \.name))
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.body)
                    .padding(.horizontal, AQDesign.Space.standard)
                    .frame(width: 330, height: House.Control.compact)
                    .background(fieldBackground)
            }
        }

        SettingsRow(title: "Model") {
            HStack(spacing: AQDesign.Space.standard) {
                if !provider.models.isEmpty {
                    Picker("Model", selection: modelBinding(provider.id)) {
                        ForEach(visibleModels(for: provider), id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 245)
                } else {
                    TextField("Model ID", text: customModelBinding(provider.id))
                        .textFieldStyle(.plain)
                        .font(AQDesign.TypeToken.body)
                        .padding(.horizontal, AQDesign.Space.standard)
                        .frame(width: 245, height: House.Control.compact)
                        .background(fieldBackground)
                }

                if provider.discovery != .none {
                    Button {
                        Task { await viewModel.refreshModels(providerID: provider.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh models")
                }
            }
        }

        if provider.kind == .openAICompatible {
            SettingsRow(title: "Base URL") {
                TextField("https://host.example/v1", text: providerBinding(index, \.baseURL))
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.code)
                    .padding(.horizontal, AQDesign.Space.standard)
                    .frame(width: 330, height: House.Control.compact)
                    .background(fieldBackground)
            }

            SettingsRow(title: "API key") {
                HStack(spacing: AQDesign.Space.standard) {
                    SecureField("Optional for local servers", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(AQDesign.TypeToken.body)
                        .padding(.horizontal, AQDesign.Space.standard)
                        .frame(width: 220, height: House.Control.compact)
                        .background(fieldBackground)
                    Button("Save") { saveKey(provider.id) }
                    Button("Remove") {
                        try? APIKeyStore.delete(providerID: provider.id)
                        viewModel.invalidateAPIKeyPresence()
                        apiKey = ""
                        keyStatus = "Key removed"
                    }
                    .disabled(apiKey.isEmpty && APIKeyStore.load(providerID: provider.id) == nil)
                }
            }
        } else if provider.kind == .commandLine {
            SettingsRow(title: "Command") {
                Text(provider.command?.executable ?? "Not configured")
                    .font(AQDesign.TypeToken.code)
                    .foregroundStyle(
                        provider.command.flatMap { ExecutableResolver.resolve($0.executable) } == nil
                            ? AQDesign.ColorToken.danger
                            : AQDesign.ColorToken.textSecondary
                    )
            }
        }

        if let message = viewModel.modelRefreshMessage ?? keyStatus {
            CardNote { CardText(message) }
        }

        if !provider.isBuiltIn {
            CardNote {
                Button("Remove endpoint", role: .destructive) {
                    viewModel.removeProvider(id: provider.id)
                    loadKey()
                }
            }
        }
    }

    private var visionCard: some View {
        SettingsCard("Vision") {
            VisionModelPicker(viewModel: viewModel)
        }
    }

    /// The same provider picker as General › Chat; every surface shares it.
    private var webSearchCard: some View {
        SettingsCard("Web search") {
            WebSearchProviderRow(viewModel: viewModel, isFirst: true)
            searchKeyRow(
                title: "Tavily key",
                text: $tavilyKey,
                featureKey: APIKeyStore.FeatureKey.tavilySearch
            )
            searchKeyRow(
                title: "Brave key",
                text: $braveKey,
                featureKey: APIKeyStore.FeatureKey.braveSearch
            )
            searchKeyRow(
                title: "Bocha key",
                text: $bochaKey,
                featureKey: APIKeyStore.FeatureKey.bochaSearch
            )
            searchKeyRow(
                title: "Exa key",
                text: $exaKey,
                featureKey: APIKeyStore.FeatureKey.exaSearch
            )
            if let searchKeyStatus {
                CardNote { CardText(searchKeyStatus) }
            }
            CardNote {
                CardText("Automatic uses Bocha for a Chinese query when a Bocha key is set, then Tavily, then the self-hosted SearXNG, then Brave. Direct backends send the query to that provider; SearXNG stays on vault-vps. Used by Quick AI, AI Chat, and the Translator. Turn web search on or off in General › Chat.")
            }
        }
    }

    /// One Keychain-backed search API key. Never written to settings files.
    private func searchKeyRow(
        title: String,
        text: Binding<String>,
        featureKey: String
    ) -> some View {
        SettingsRow(title: title) {
            HStack(spacing: AQDesign.Space.standard) {
                SecureField("Optional", text: text)
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.body)
                    .padding(.horizontal, AQDesign.Space.standard)
                    .frame(width: 220, height: House.Control.compact)
                    .background(fieldBackground)
                Button("Save") { saveSearchKey(text.wrappedValue, featureKey: featureKey) }
                Button("Remove") {
                    try? APIKeyStore.deleteFeatureKey(featureKey)
                    text.wrappedValue = ""
                    searchKeyStatus = "Key removed"
                }
                .disabled(text.wrappedValue.isEmpty && APIKeyStore.loadFeatureKey(featureKey) == nil)
            }
        }
    }

    private var instructionCard: some View {
        SettingsCard("Quick-action instruction") {
            CardNote(isFirst: true) {
                TextEditor(text: viewModel.settingsBinding(\.systemPrompt))
                    .font(AQDesign.TypeToken.detail)
                    .scrollContentBackground(.hidden)
                    .padding(AQDesign.Space.standard)
                    .frame(minHeight: 82)
                    .background(fieldBackground)
                    .accessibilityLabel("Quick-action instruction")
            }
            CardNote {
                CardText("This instruction applies to every provider. Saved actions add their own prompt.")
            }
        }
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

    private func providerBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<InferenceProvider, String>
    ) -> Binding<String> {
        viewModel.settingsBinding(
            get: { $0.providers[index][keyPath: keyPath] },
            set: { settings, value in settings.providers[index][keyPath: keyPath] = value }
        )
    }

    /// The models this picker may offer: the provider's, minus the ones turned
    /// off on the Manage Models screen, plus the current selection so the
    /// picker can always show what is chosen.
    private func visibleModels(for provider: InferenceProvider) -> [String] {
        ModelCatalogService.visibleModels(
            for: provider,
            currentModel: provider.selectedModel,
            preferences: preferences
        )
    }

    private func modelBinding(_ providerID: UUID) -> Binding<String> {
        Binding(
            get: {
                viewModel.settings.providers.first(where: { $0.id == providerID })?.selectedModel ?? ""
            },
            set: {
                viewModel.selectModel(providerID: providerID, model: $0)
                preferences.noteModelSelection(providerID: providerID, model: $0)
            }
        )
    }

    private func customModelBinding(_ providerID: UUID) -> Binding<String> {
        Binding(
            get: {
                viewModel.settings.providers.first(where: { $0.id == providerID })?.selectedModel ?? ""
            },
            set: { viewModel.setCustomModel(providerID: providerID, model: $0) }
        )
    }

    private func loadKey() {
        apiKey = APIKeyStore.load(providerID: viewModel.settings.selectedProviderID) ?? ""
        keyStatus = nil
    }

    private func loadSearchKeys() {
        tavilyKey = APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.tavilySearch) ?? ""
        braveKey = APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.braveSearch) ?? ""
        bochaKey = APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.bochaSearch) ?? ""
        exaKey = APIKeyStore.loadFeatureKey(APIKeyStore.FeatureKey.exaSearch) ?? ""
        searchKeyStatus = nil
    }

    private func saveSearchKey(_ key: String, featureKey: String) {
        do {
            try APIKeyStore.saveFeatureKey(key, name: featureKey)
            searchKeyStatus = "Key saved in Keychain"
        } catch {
            searchKeyStatus = error.localizedDescription
        }
    }

    private func saveKey(_ providerID: UUID) {
        do {
            try APIKeyStore.save(apiKey, providerID: providerID)
            viewModel.invalidateAPIKeyPresence()
            keyStatus = "Key saved in Keychain"
        } catch {
            keyStatus = error.localizedDescription
        }
    }
}


/// Chooses which provider and model receive attached screenshots.
private struct VisionModelPicker: View {
    @Bindable var viewModel: QuickViewModel

    private struct Option: Identifiable {
        let id: String
        let label: String
    }

    private var options: [Option] {
        viewModel.settings.providers
            .filter { $0.kind == .openAICompatible }
            .flatMap { provider -> [Option] in
                let current = provider.selectedModel.isEmpty ? "selected model" : provider.selectedModel
                var list = [Option(id: "\(provider.id.uuidString)|", label: "\(provider.name) \u{00B7} \(current)")]
                let models = ModelCatalogService.visibleModels(
                    for: provider,
                    currentModel: provider.selectedModel
                )
                for model in models where model != provider.selectedModel {
                    list.append(Option(id: "\(provider.id.uuidString)|\(model)", label: "\(provider.name) \u{00B7} \(model)"))
                }
                return list
            }
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                let settings = viewModel.settings
                let exact = "\(settings.visionProviderID.uuidString)|\(settings.visionModel)"
                if options.contains(where: { $0.id == exact }) { return exact }
                return "\(settings.visionProviderID.uuidString)|"
            },
            set: { value in
                let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                guard let first = parts.first, let providerID = UUID(uuidString: String(first)) else { return }
                let model = parts.count > 1 ? String(parts[1]) : ""
                viewModel.setVisionModel(providerID: providerID, model: model)
            }
        )
    }

    var body: some View {
        SettingsRow(title: "Vision model", isFirst: true) {
            Picker("Vision model", selection: selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .labelsHidden()
            .frame(width: 330)
        }
        CardNote {
            CardText("Screenshots attached with \u{2318}\u{21E7}S or \u{2318}\u{21E7}D go only to this model. A local model keeps the image on this Mac. Refresh a provider's models to see new vision models.")
        }
    }
}
