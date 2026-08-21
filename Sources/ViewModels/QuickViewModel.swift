import Foundation
import AppKit
import Observation

@Observable @MainActor final class QuickViewModel {

    // MARK: - Published state

    var input: String = ""
    var output: String = ""
    var isStreaming: Bool = false
    var errorMessage: String? = nil
    var settings: QuickSettings
    var updateState: UpdateState = .idle
    var history: [QuickConversation] = []
    var currentConversation: QuickConversation?
    var modelRefreshMessage: String?
    /// True briefly after auto-copy fires, so the UI can flash a "Copied!" indicator.
    var justCopied: Bool = false

    // MARK: - Dependencies

    var service: (any QuickService)?

    // How long submit() waits for `service` to be injected before giving up.
    // Exposed so tests can lower this to keep them fast.
    @ObservationIgnored var serviceWaitTimeout: Duration = .seconds(5)

    // How long the "just copied" flag stays true after auto-copy.
    @ObservationIgnored var justCopiedTimeout: Duration = .seconds(2)
    @ObservationIgnored private var justCopiedTask: Task<Void, Never>?

    // MARK: - Private

    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored let currentVersion: String

    // MARK: - Init

    init(
        settings: QuickSettings = QuickSettings(),
        service: (any QuickService)? = nil,
        currentVersion: String = "1.0.0"
    ) {
        self.settings = settings
        self.service = service
        self.currentVersion = currentVersion
    }

    // MARK: - Submit

    /// Saved-prompt aliases matching the current `input`, sorted alphabetically.
    /// Empty whenever the input is not a prefix-based command.
    var savedPromptMatches: [SavedPrompt] {
        SavedPromptResolver.matches(
            input: input,
            prefix: settings.savedPromptPrefix,
            savedPrompts: settings.savedPrompts
        )
    }

    var activeProvider: InferenceProvider? { settings.selectedProvider }
    var activeModelDisplay: String {
        guard let provider = activeProvider else { return "No model" }
        return provider.selectedModel.isEmpty ? provider.name : provider.selectedModel
    }

    var isFollowUp: Bool { !(currentConversation?.messages.isEmpty ?? true) }

    /// Replace `input` with `<prefix><alias> ` so the user can keep typing
    /// context after committing to a saved prompt.
    func complete(savedPrompt: SavedPrompt) {
        input = settings.savedPromptPrefix + savedPrompt.alias + " "
    }

    func submit() async {
        guard !input.isEmpty else { return }
        let submittedInput = input

        // Expand saved-prompt aliases before anything else. Non-matches
        // (including inputs that look like `/foo` but reference an unknown
        // alias) fall through to the regular path below.
        let action = SavedPromptResolver.resolveAction(
            input: input,
            prefix: settings.savedPromptPrefix,
            savedPrompts: settings.savedPrompts
        )
        let effectivePrompt = action?.prompt ?? input

        // Math shortcut — evaluate locally without the AI
        if MathExpressionDetector.isMathExpression(effectivePrompt) {
            errorMessage = nil
            do {
                let result = try MathCalculator.evaluate(effectivePrompt)
                output = MathCalculator.format(result)
                if settings.autoCopy {
                    copyOutput()
                    markJustCopied()
                }
            } catch {
                errorMessage = "Math error: \(error)"
            }
            return
        }

        guard let provider = provider(for: action?.providerID),
              let model = resolvedModel(for: provider, override: action?.model)
        else {
            errorMessage = "Choose a provider and model in Settings."
            return
        }

        if shouldStartNewConversation || (action != nil && isFollowUp) {
            startNewConversation()
        }
        if currentConversation == nil {
            currentConversation = QuickConversation(
                providerID: provider.id,
                model: model
            )
        }
        currentConversation?.providerID = provider.id
        currentConversation?.model = model
        let submittedMessage = QuickMessage(role: .user, content: effectivePrompt)
        currentConversation?.messages.append(submittedMessage)
        currentConversation?.updatedAt = Date()
        let requestMessages = currentConversation?.messages ?? [
            QuickMessage(role: .user, content: effectivePrompt)
        ]
        input = ""

        errorMessage = nil
        output = ""
        isStreaming = true
        let waitingService = await waitForService(
            provider: provider,
            model: model,
            timeout: serviceWaitTimeout
        )
        guard let service = waitingService else {
            isStreaming = false
            rollbackSubmission(messageID: submittedMessage.id, restoring: submittedInput)
            errorMessage = provider.kind == .managedApfel
                ? "Still starting on-device AI — please try again in a moment."
                : "\(provider.name) is not available. Check its model, endpoint, or installed command."
            return
        }

        let stream = service.send(messages: requestMessages)

        streamTask = Task {
            do {
                for try await delta in stream {
                    if Task.isCancelled { break }
                    if let text = delta.text {
                        output += text
                    }
                }
                // Stream completed normally
                isStreaming = false
                if !output.isEmpty {
                    currentConversation?.messages.append(
                        QuickMessage(role: .assistant, content: output)
                    )
                    currentConversation?.updatedAt = Date()
                    persistCurrentConversation()
                }
                if settings.autoCopy && !output.isEmpty {
                    copyOutput()
                    markJustCopied()
                }
            } catch is CancellationError {
                // Cancelled — do not set errorMessage
                isStreaming = false
                output = ""
                rollbackSubmission(messageID: submittedMessage.id, restoring: submittedInput)
            } catch {
                errorMessage = error.localizedDescription
                isStreaming = false
                rollbackSubmission(messageID: submittedMessage.id, restoring: submittedInput)
            }
        }

        await streamTask?.value
    }

    // MARK: - Provider and model routing

    func selectModel(providerID: UUID, model: String) {
        settings.select(providerID: providerID, model: model)
        settings.save()
        modelRefreshMessage = nil
        NotificationCenter.default.post(name: .providerChanged, object: nil)
    }

    func selectProvider(providerID: UUID) {
        settings.select(providerID: providerID)
        settings.save()
        modelRefreshMessage = nil
        NotificationCenter.default.post(name: .providerChanged, object: nil)
    }

    func setCustomModel(providerID: UUID, model: String) {
        guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else {
            return
        }
        settings.selectedProviderID = providerID
        settings.providers[index].selectedModel = model
        settings.save()
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
        settings.save()
        return provider.id
    }

    func removeProvider(id: UUID) {
        guard let provider = settings.providers.first(where: { $0.id == id }),
              !provider.isBuiltIn
        else { return }
        settings.providers.removeAll { $0.id == id }
        if settings.selectedProviderID == id {
            settings.selectedProviderID = settings.providers.first?.id
                ?? InferenceProvider.managedApfelID
        }
        try? APIKeyStore.delete(providerID: id)
        settings.save()
        NotificationCenter.default.post(name: .providerChanged, object: nil)
    }

    func refreshModels(providerID: UUID) async {
        guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
        let provider = settings.providers[index]
        modelRefreshMessage = "Refreshing \(provider.name)…"
        do {
            let models = try await ModelCatalogService().models(
                for: provider,
                apiKey: APIKeyStore.load(providerID: provider.id)
            )
            settings.providers[index].models = models
            if settings.providers[index].selectedModel.isEmpty ||
                !models.contains(settings.providers[index].selectedModel) {
                settings.providers[index].selectedModel = models.first ?? ""
            }
            settings.save()
            modelRefreshMessage = models.isEmpty
                ? "No models found"
                : "Found \(models.count) models"
        } catch {
            modelRefreshMessage = error.localizedDescription
        }
    }

    func refreshDetectedModels() async {
        let ids = settings.providers
            .filter { $0.discovery == .lmStudio || $0.discovery == .pi }
            .map(\.id)
        for id in ids { await refreshModels(providerID: id) }
    }

    private func provider(for overrideID: UUID?) -> InferenceProvider? {
        if let overrideID,
           let provider = settings.providers.first(where: { $0.id == overrideID }) {
            return provider
        }
        return settings.selectedProvider
    }

    private func resolvedModel(for provider: InferenceProvider, override: String?) -> String? {
        let model = override.flatMap { $0.isEmpty ? nil : $0 } ?? provider.selectedModel
        return model.isEmpty ? nil : model
    }

    private func makeService(
        provider: InferenceProvider,
        model: String
    ) -> (any QuickService)? {
        switch provider.kind {
        case .managedApfel:
            return service
        case .openAICompatible:
            guard let url = URL(string: provider.baseURL) else { return nil }
            return ApfelQuickService(
                baseURL: url,
                modelName: model,
                apiKey: APIKeyStore.load(providerID: provider.id),
                systemPrompt: settings.systemPrompt,
                ensureV1: false
            )
        case .commandLine:
            guard let command = provider.command else { return nil }
            return CommandQuickService(
                configuration: command,
                model: model,
                systemPrompt: settings.systemPrompt
            )
        }
    }

    private func waitForService(
        provider: InferenceProvider,
        model: String,
        timeout: Duration
    ) async -> (any QuickService)? {
        if let resolved = makeService(provider: provider, model: model) { return resolved }
        guard provider.kind == .managedApfel else { return nil }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let pollInterval: Duration = .milliseconds(50)
        while ContinuousClock.now < deadline {
            if let resolved = makeService(provider: provider, model: model) { return resolved }
            try? await Task.sleep(for: pollInterval)
        }
        return makeService(provider: provider, model: model)
    }

    // MARK: - Cancel

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        output = ""
    }

    // MARK: - Copy

    func copyOutput() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    // MARK: - Just-copied flash

    func markJustCopied() {
        justCopiedTask?.cancel()
        justCopied = true
        justCopiedTask = Task { @MainActor [weak self, timeout = justCopiedTimeout] in
            try? await Task.sleep(for: timeout)
            self?.justCopied = false
        }
    }

    // MARK: - Clear

    func clearOutput() {
        output = ""
        errorMessage = nil
    }

    // MARK: - Lightweight follow-up history

    private var shouldStartNewConversation: Bool {
        guard let updatedAt = currentConversation?.updatedAt else { return false }
        return Date().timeIntervalSince(updatedAt)
            > Double(max(1, settings.newConversationAfterMinutes) * 60)
    }

    func loadHistory() {
        history = settings.historyEnabled ? QuickHistoryStore.load() : []
    }

    func startNewConversation() {
        currentConversation = nil
        output = ""
        errorMessage = nil
        input = ""
    }

    func clearHistory() {
        history = []
        currentConversation = nil
        QuickHistoryStore.clear()
        output = ""
        errorMessage = nil
    }

    func loadConversation(id: UUID) {
        guard let conversation = history.first(where: { $0.id == id }) else { return }
        currentConversation = conversation
        output = conversation.messages.last(where: { $0.role == .assistant })?.content ?? ""
        settings.select(providerID: conversation.providerID, model: conversation.model)
        settings.save()
        errorMessage = nil
        input = ""
    }

    private func persistCurrentConversation() {
        guard settings.historyEnabled, let conversation = currentConversation else { return }
        history = QuickHistoryStore.upserting(
            conversation,
            into: history,
            limit: settings.historyLimit
        )
        QuickHistoryStore.save(history, limit: settings.historyLimit)
    }

    private func rollbackSubmission(messageID: UUID, restoring submittedInput: String) {
        currentConversation?.messages.removeAll { $0.id == messageID }
        currentConversation?.updatedAt = Date()
        input = submittedInput
    }

    // MARK: - Launch at login

    func applyLaunchAtLogin() {
        let controller = SystemLaunchAtLoginController()
        try? controller.setEnabled(settings.launchAtLogin)
    }

    // MARK: - Install update

    func installUpdate() {
        guard case .updateAvailable(let version) = updateState else { return }
        updateState = .installing(newVersion: version)
        let isHB = FileManager.default.fileExists(atPath: "/opt/homebrew/Caskroom/apfel-quick")
        guard isHB else {
            NSWorkspace.shared.open(
                URL(string: "https://github.com/Arthur-Ficial/apfel-quick/releases/latest")!
            )
            updateState = .idle
            return
        }

        Task { [weak self, version] in
            let installError = await Task.detached(priority: .utility) { () -> String? in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "brew upgrade apfel-quick"]
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                        ? nil
                        : "Homebrew exited with status \(process.terminationStatus)"
                } catch {
                    return error.localizedDescription
                }
            }.value

            if let installError {
                self?.updateState = .error(message: installError)
            } else {
                self?.updateState = .installed(newVersion: version)
            }
        }
    }

    // MARK: - Manual update check

    func checkForUpdateManual() async {
        updateState = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/Arthur-Ficial/apfel-quick/releases/latest")!
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                updateState = .error(message: "Could not parse release info")
                return
            }
            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            await handleUpdateCheck(remoteVersion: latestVersion)
        } catch {
            updateState = .error(message: error.localizedDescription)
        }
    }

    // MARK: - Update check

    func handleUpdateCheck(remoteVersion: String) async {
        if QuickViewModel.isVersionNewer(remoteVersion, than: currentVersion) {
            updateState = .updateAvailable(newVersion: remoteVersion)
        } else {
            updateState = .upToDate
        }
    }

    // MARK: - Version comparison

    nonisolated static func isVersionNewer(_ candidate: String, than current: String) -> Bool {
        let normalize: (String) -> [Int] = { version in
            let stripped = version.hasPrefix("v") ? String(version.dropFirst()) : version
            return stripped.split(separator: ".").compactMap { Int($0) }
        }

        var lhs = normalize(candidate)
        var rhs = normalize(current)

        // Pad shorter array with zeros
        let maxLen = max(lhs.count, rhs.count)
        while lhs.count < maxLen { lhs.append(0) }
        while rhs.count < maxLen { rhs.append(0) }

        for (l, r) in zip(lhs, rhs) {
            if l > r { return true }
            if l < r { return false }
        }
        return false // equal
    }
}
