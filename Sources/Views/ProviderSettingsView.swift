import SwiftUI

/// Provider configuration stays deliberately compact: choose a source, choose
/// a model, and edit only the fields that source needs.
struct ProviderSettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var apiKey = ""
    @State private var keyStatus: String?

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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Models").font(.headline)
                    Spacer()
                    Button("Add endpoint") {
                        _ = viewModel.addOpenAICompatibleProvider()
                        loadKey()
                    }
                }

                LabeledContent("Provider") {
                    Picker("", selection: selectedProviderID) {
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
                }

                if let provider, let selectedIndex {
                    providerEditor(provider, index: selectedIndex)
                }

                Divider()

                VisionModelPicker(viewModel: viewModel)

                Divider()

                Text("Quick-action instruction")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $viewModel.settings.systemPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 82)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                    .onChange(of: viewModel.settings.systemPrompt) { _, _ in
                        viewModel.settings.save()
                    }
                Text("This instruction applies to every provider. Saved actions add their own prompt.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { loadKey() }
    }

    @ViewBuilder
    private func providerEditor(_ provider: InferenceProvider, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !provider.isBuiltIn {
                LabeledContent("Name") {
                    TextField("Provider name", text: providerBinding(index, \.name))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 330)
                }
            }

            LabeledContent("Model") {
                HStack(spacing: 8) {
                    if !provider.models.isEmpty {
                        Picker("", selection: modelBinding(provider.id)) {
                            ForEach(provider.models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 245)
                    } else {
                        TextField("Model ID", text: customModelBinding(provider.id))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 245)
                    }

                    if provider.discovery != .none {
                        Button {
                            Task { await viewModel.refreshModels(providerID: provider.id) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh models")
                    }
                }
            }

            if provider.kind == .openAICompatible {
                LabeledContent("Base URL") {
                    TextField("https://host.example/v1", text: providerBinding(index, \.baseURL))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 330)
                }

                LabeledContent("API key") {
                    HStack(spacing: 8) {
                        SecureField("Optional for local servers", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                        Button("Save") { saveKey(provider.id) }
                        Button("Remove") {
                            try? APIKeyStore.delete(providerID: provider.id)
                            apiKey = ""
                            keyStatus = "Key removed"
                        }
                        .disabled(apiKey.isEmpty && APIKeyStore.load(providerID: provider.id) == nil)
                    }
                }
            } else if provider.kind == .commandLine {
                LabeledContent("Command") {
                    Text(provider.command?.executable ?? "Not configured")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(
                            provider.command.flatMap { ExecutableResolver.resolve($0.executable) } == nil
                                ? .red : .secondary
                        )
                }
            }

            if let message = viewModel.modelRefreshMessage ?? keyStatus {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !provider.isBuiltIn {
                Button("Remove endpoint", role: .destructive) {
                    viewModel.removeProvider(id: provider.id)
                    loadKey()
                }
            }
        }
    }

    private func providerBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<InferenceProvider, String>
    ) -> Binding<String> {
        Binding(
            get: { viewModel.settings.providers[index][keyPath: keyPath] },
            set: {
                viewModel.settings.providers[index][keyPath: keyPath] = $0
                viewModel.settings.save()
            }
        )
    }

    private func modelBinding(_ providerID: UUID) -> Binding<String> {
        Binding(
            get: {
                viewModel.settings.providers.first(where: { $0.id == providerID })?.selectedModel ?? ""
            },
            set: { viewModel.selectModel(providerID: providerID, model: $0) }
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

    private func saveKey(_ providerID: UUID) {
        do {
            try APIKeyStore.save(apiKey, providerID: providerID)
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
                var list = [Option(id: "\(provider.id.uuidString)|", label: "\(provider.name) · \(current)")]
                for model in provider.models where model != provider.selectedModel {
                    list.append(Option(id: "\(provider.id.uuidString)|\(model)", label: "\(provider.name) · \(model)"))
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
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Vision model") {
                Picker("", selection: selection) {
                    ForEach(options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(width: 330)
            }
            Text("Screenshots attached with ⌘⇧S or ⌘⇧D go only to this model. A local model keeps the image on this Mac. Refresh a provider's models to see new vision models.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
