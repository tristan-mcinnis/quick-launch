import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    /// Opens the chooser for the last answer. Every provider's visible models
    /// are offered, and the row for the model already in use starts selected.
    func openModelChooser(_ purpose: ModelChooserPurpose) {
        let options = modelChooserEntries()
        guard !options.isEmpty else {
            errorMessage = "No model is available. Add a provider in Settings › Models."
            requestInputFocus()
            return
        }
        modelChooserOptions = options
        modelChooserPurpose = purpose
        modelChooserIndex = options.firstIndex { $0.model == activeModelID } ?? 0
        isModelChooserPresented = true
        isAssistantChooserPresented = false
        isCaptureChooserPresented = false
        isActionPalettePresented = false
        closeItemActionPane()
        isApplicationActionPanePresented = false
        isCatalogActionPanePresented = false
        actionQuery = ""
        errorMessage = nil
        requestInputFocus()
    }

    func closeModelChooser() {
        guard isModelChooserPresented else { return }
        isModelChooserPresented = false
        requestInputFocus()
    }

    func moveModelChooserSelection(_ delta: Int) {
        guard !modelChooserOptions.isEmpty else { return }
        modelChooserIndex = ListSelection.wrappedIndex(
            modelChooserIndex,
            by: delta,
            count: modelChooserOptions.count
        )
    }

    /// Return in the open chooser: make the pick active, then regenerate when
    /// the chooser was opened by `⇧⌘R`.
    func runModelChooserSelection() async {
        guard modelChooserOptions.indices.contains(modelChooserIndex) else { return }
        let option = modelChooserOptions[modelChooserIndex]
        let purpose = modelChooserPurpose
        isModelChooserPresented = false
        setActiveModel(providerID: option.providerID, model: option.model)
        switch purpose {
        case .change:
            requestInputFocus()
        case .regenerate:
            await regenerateLastAnswer()
        }
    }

    /// Every row the chooser may offer: each installed provider's visible
    /// models, in provider order.
    func modelChooserEntries() -> [ModelChooserOption] {
        settings.providers.flatMap { provider in
            visibleModels(for: provider).map { model in
                ModelChooserOption(
                    providerID: provider.id,
                    providerName: provider.name,
                    model: model
                )
            }
        }
    }

    /// Change Model, and the model half of `⇧⌘R`: the open chat answers
    /// with this provider and model from here on, and keeps them in history.
    /// Before a chat exists the pick waits for the chat the next question
    /// starts. The Quick AI default in Settings, and the other window, are
    /// left alone. Nothing is sent.
    func setActiveModel(providerID: UUID, model: String) {
        if currentConversation != nil {
            currentConversation?.providerID = providerID
            currentConversation?.model = model
            if !conversationMessages.isEmpty { persistCurrentConversation() }
        } else {
            pendingModelChoice = ChatModelChoice(providerID: providerID, model: model)
        }
        modelRefreshMessage = nil
        noteInteraction()
    }

    // MARK: - Provider and model routing

    /// The models a picker may offer for one provider: everything it reports
    /// minus the models turned off on Manage Models. The provider's current
    /// model stays listed so the picker can always render what is selected.
    func visibleModels(for provider: InferenceProvider) -> [String] {
        ModelCatalogService.visibleModels(
            for: provider,
            currentModel: modelInUse(for: provider),
            preferences: modelPreferences
        )
    }

    /// The model the Quick AI surface would send to for this provider.
    private func modelInUse(for provider: InferenceProvider) -> String? {
        guard activeProvider?.id == provider.id else { return provider.selectedModel }
        return chatModelOverride(for: provider) ?? provider.selectedModel
    }

    /// Whether this provider and model are the pair the surface would use
    /// right now; a model picker ticks exactly this row.
    func isActiveModel(provider: InferenceProvider, model: String) -> Bool {
        activeProvider?.id == provider.id && modelInUse(for: provider) == model
    }

    func selectModel(providerID: UUID, model: String) {
        settings.select(providerID: providerID, model: model)
        persistSettings(settings)
        modelRefreshMessage = nil
    }

    func selectProvider(providerID: UUID) {
        settings.select(providerID: providerID)
        persistSettings(settings)
        modelRefreshMessage = nil
    }

    func setCustomModel(providerID: UUID, model: String) {
        guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else {
            return
        }
        settings.selectedProviderID = providerID
        settings.providers[index].selectedModel = model
        persistSettings(settings)
        modelRefreshMessage = nil
    }

    @discardableResult
    func addOpenAICompatibleProvider() -> UUID {
        let provider = InferenceProvider(
            name: "Custom OpenAI endpoint",
            kind: .openAICompatible,
            location: .local,
            baseURL: "http://127.0.0.1:8000/v1",
            discovery: .openAI
        )
        settings.providers.append(provider)
        settings.selectedProviderID = provider.id
        persistSettings(settings)
        return provider.id
    }

    func removeProvider(id: UUID) {
        guard let provider = settings.providers.first(where: { $0.id == id }),
              !provider.isBuiltIn
        else { return }
        settings.providers.removeAll { $0.id == id }
        if settings.selectedProviderID == id {
            settings.selectedProviderID = settings.providers.first?.id
                ?? InferenceProvider.deepSeekID
        }
        try? APIKeyStore.delete(providerID: id, keychain: keychain)
        invalidateAPIKeyPresence()
        persistSettings(settings)
    }

    func refreshModels(providerID: UUID) async {
        guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
        let provider = settings.providers[index]
        modelRefreshMessage = "Refreshing \(provider.name)…"
        do {
            let models = try await ModelCatalogService().models(
                for: provider,
                apiKey: apiKeyProvider(provider.id)
            )
            // A provider removed while the request was in flight shifts the
            // indices; find it by id again rather than writing the wrong one.
            guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
            settings.providers[index].models = models
            if settings.providers[index].selectedModel.isEmpty ||
                !models.contains(settings.providers[index].selectedModel) {
                // Land on the first model that is still offered, never on one
                // the user turned off on Manage Models.
                settings.providers[index].selectedModel = Self.refreshFallbackModel(
                    for: settings.providers[index], preferences: modelPreferences
                )
            }
            persistSettings(settings)
            modelRefreshMessage = models.isEmpty
                ? "No models found"
                : "Found \(models.count) models"
        } catch {
            modelRefreshMessage = error.localizedDescription
        }
    }

    /// The model a refresh falls back to when the recorded one is gone or
    /// blank: the first model that is still offered, never one the user
    /// turned off on Manage Models.
    static func refreshFallbackModel(
        for provider: InferenceProvider,
        preferences: ModelPreferenceStore = .shared
    ) -> String {
        ModelCatalogService.visibleModels(for: provider, preferences: preferences).first ?? ""
    }

    func refreshDetectedModels() async {
        let ids = settings.providers
            .filter { $0.discovery == .lmStudio || $0.discovery == .pi }
            .map(\.id)
        for id in ids { await refreshModels(providerID: id) }
    }

    func resolvedModel(for provider: InferenceProvider, override: String?) -> String? {
        let model = override.flatMap { $0.isEmpty ? nil : $0 } ?? provider.selectedModel
        return model.isEmpty ? nil : model
    }

    /// The service for the selected provider and model, for the Translator
    /// window. Nil when no usable provider is configured.
    func makeCurrentService() -> (any QuickService)? {
        guard let provider = settings.selectedProvider,
              let model = resolvedModel(for: provider, override: nil)
        else { return nil }
        if service == nil, provider.kind == .openAICompatible, provider.location == .cloud,
           (apiKeyProvider(provider.id) ?? "").isEmpty {
            return nil
        }
        return makeService(provider: provider, model: model, chatTools: false)
    }

    /// The system instruction this surface's request carries on `provider`:
    /// the surface prompt, the grounding sentence when the turn carries a
    /// source, and the assistant's message, composed the way the provider
    /// joins them. The attachment budget and the provider body both read this
    /// one function, so the reserve is the instruction the model reads.
    ///
    /// `assistantInstruction` is the chat's assistant message, which the
    /// provider joins in front of the surface instruction. Pass nil when only
    /// the instruction the service itself carries is wanted, since the
    /// assistant travels on the request's own system message.
    func systemInstruction(
        for provider: InferenceProvider,
        grounded: Bool,
        assistantInstruction: String? = nil
    ) -> String {
        ChatContextGate.systemInstruction(
            surfacePrompt: settings.surfaceSystemPrompt(forChat: isAIChatWindow),
            grounded: grounded,
            lane: provider.kind == .commandLine ? .commandLine : .model,
            assistantInstruction: assistantInstruction
        )
    }

    /// `chatTools` offers the chat's memory and skill tools and lets
    /// the chat's toggle decide web search. The Translator passes false: it
    /// gets web search per the setting and nothing else.
    func makeService(
        provider: InferenceProvider,
        model: String,
        chatTools: Bool = true,
        toolOverride: Set<ChatToolKind>? = nil,
        /// A `.textOnly` saved action offers the model no tools at all,
        /// which is derived here rather than through `toolOverride`.
        textOnly: Bool = false,
        /// True when this turn carries a source. The tools are offered
        /// either way now; this adds the sentence that keeps the answer on
        /// the attached material (`ChatContextGate.groundingDirective`).
        grounded: Bool = false,
        attachmentTrim: ContextBudget.Trim = ContextBudget.Trim(),
        roundRecorder: ChatRoundRecorder? = nil
    ) -> (any QuickService)? {
        if let service { return service }
        // One engine, two surfaces: Quick AI carries the direct overlay
        // instruction, AI Chat its conversational one. Providers, tools,
        // history and attachments stay shared; only this default differs,
        // and a custom instruction is used exactly as written. Both lanes
        // compose their instruction through `systemInstruction(for:grounded:)`
        // so the attachment budget measures the same string.
        switch provider.kind {
        case .openAICompatible:
            guard let url = URL(string: provider.baseURL) else { return nil }
            // A source-grounded request passes the gated set; everything
            // else uses the chat's own offered set. A text-only action gets
            // the empty set no matter what the chat offered.
            let tools = textOnly ? [] : (toolOverride ?? self.chatTools)
            // The model gets a search_web tool so it can look things up
            // mid-answer, using the same provider as explicit searches.
            var webSearch: (@Sendable (String) async throws -> String)?
            let webEnabled = chatTools ? tools.contains(.web) : settings.modelWebSearchEnabled
            if webEnabled, let webSearchService {
                let searchProvider = settings.webSearchProvider
                webSearch = { query in try await webSearchService.search(query, provider: searchProvider) }
            }
            let profile = modelPreferences.profile(providerID: provider.id, model: model)
            // The per-round snapshot hook: the model client hands every
            // request body here before it goes out, so a write failure stops
            // the request. Nil for a service that has no archive (the
            // Translator, and every test that injects its own service).
            var beforeRequest: (@Sendable (ProviderRequestRound) async throws -> Void)?
            if let roundRecorder {
                beforeRequest = { round in
                    try await roundRecorder.beforeRequest(round)
                }
            }
            return OpenAICompatibleService(
                baseURL: url,
                modelName: model,
                apiKey: apiKeyProvider(provider.id),
                systemPrompt: systemInstruction(for: provider, grounded: grounded),
                webSearch: webSearch,
                tools: chatTools && !textOnly
                    ? ChatToolbox(
                        enabled: tools,
                        memory: memoryService,
                        skills: skillLibrary
                    )
                    : ChatToolbox(),
                contextBudget: ContextBudget(contextWindow: profile.contextWindow),
                attachmentTrim: attachmentTrim,
                reasoningEffort: profile.reasoningEffort,
                thinkingSupported: profile.supportsReasoningEffort,
                beforeRequest: beforeRequest
            )
        case .commandLine:
            guard let command = provider.command else { return nil }
            return CommandQuickService(
                configuration: command,
                model: model,
                systemPrompt: systemInstruction(for: provider, grounded: grounded)
            )
        }
    }

    /// The header's model line: opens the model chooser to change the model
    /// for the next message, or closes it when it is already open.
    func toggleModelChooserFromHeader() {
        if isModelChooserPresented {
            closeModelChooser()
        } else {
            openModelChooser(.change)
        }
    }

    /// Whether `providerID` has an API key, from the cache after the first
    /// read. The Keychain itself is the source; this only stops one body pass
    /// from reading it repeatedly.
    func hasAPIKey(_ providerID: UUID) -> Bool {
        if let cached = apiKeyPresence[providerID] { return cached }
        let has = !(apiKeyProvider(providerID) ?? "").isEmpty
        apiKeyPresence[providerID] = has
        return has
    }

    /// A key or a provider was added, removed, or edited: the next check
    /// reads the Keychain again.
    func invalidateAPIKeyPresence() {
        apiKeyPresence.removeAll()
    }
}
