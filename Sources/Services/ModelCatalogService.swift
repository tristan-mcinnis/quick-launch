import Foundation

struct ModelCatalogService: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func models(for provider: InferenceProvider, apiKey: String?) async throws -> [String] {
        switch provider.discovery {
        case .none:
            return provider.models
        case .pi:
            return try await commandModels(for: provider)
        case .lmStudio:
            let models = await Task.detached(priority: .utility) {
                LocalModelDiscovery.lmStudioModels()
            }.value
            return models.isEmpty
                ? try await endpointModels(for: provider, apiKey: apiKey)
                : models
        case .openAI:
            return try await endpointModels(for: provider, apiKey: apiKey)
        }
    }

    private func endpointModels(
        for provider: InferenceProvider,
        apiKey: String?
    ) async throws -> [String] {
        guard let baseURL = URL(string: provider.baseURL) else {
            throw QuickServiceError.connectionFailed("Invalid provider URL")
        }

        let modelsURL: URL
        if provider.discovery == .lmStudio {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = "/api/v0/models"
            modelsURL = components?.url ?? baseURL.appendingPathComponent("models")
        } else {
            modelsURL = baseURL.appendingPathComponent("models")
        }

        var request = URLRequest(url: modelsURL)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw QuickServiceError.serverError(Self.refreshFailureMessage(
                status: status,
                providerName: provider.name,
                hasAPIKey: !(apiKey ?? "").isEmpty
            ))
        }
        return try Self.parseModels(data)
    }

    private func commandModels(for provider: InferenceProvider) async throws -> [String] {
        guard let command = provider.command,
              let executable = ExecutableResolver.resolve(command.executable)
        else {
            throw QuickServiceError.commandFailed("\(provider.name) is not installed")
        }
        guard provider.discovery == .pi else { return provider.models }

        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: executable,
                arguments: ["--offline", "--list-models"],
                currentDirectory: FileManager.default.temporaryDirectory
            )
        } catch let error as ProcessRunnerError {
            throw QuickServiceError.commandFailed(error.localizedDescription)
        }
        guard result.status == 0 else {
            throw QuickServiceError.commandFailed(result.trimmedStderr ?? "Pi model discovery failed")
        }
        return Self.parsePiModels(result.stdoutText)
    }

    // MARK: - Visibility

    /// The models a picker may offer: everything the provider reports, minus
    /// the models the user turned off on the Manage Models screen. This is
    /// the one filter every model picker in the app goes through.
    ///
    /// `currentModel` stays in the list even when it is disabled, so a picker
    /// can always render what is selected. Pass nothing for a bare list.
    @MainActor
    static func visibleModels(
        for provider: InferenceProvider,
        currentModel: String? = nil,
        preferences: ModelPreferenceStore = .shared
    ) -> [String] {
        var models = provider.models.filter {
            preferences.isEnabled(providerID: provider.id, model: $0)
        }
        if let currentModel,
           !currentModel.isEmpty,
           provider.models.contains(currentModel),
           !models.contains(currentModel) {
            models.append(currentModel)
        }
        return models
    }

    static func refreshFailureMessage(status: Int, providerName: String, hasAPIKey: Bool) -> String {
        switch status {
        case 401 where !hasAPIKey:
            return "\(providerName) needs an API key. Add one under Settings › Models."
        case 401, 403:
            return "\(providerName) rejected the API key (HTTP \(status)). Check the key under Settings › Models."
        case 404:
            return "\(providerName) has no models endpoint at this URL (HTTP 404)."
        case 429:
            return "\(providerName) is rate limiting requests (HTTP 429). Try again in a moment."
        default:
            return "Model refresh failed: HTTP \(status)"
        }
    }

    static func parseModels(_ data: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [[String: Any]]
        else { throw QuickServiceError.streamError("Invalid model catalogue") }
        return Array(Set(entries.compactMap { $0["id"] as? String })).sorted()
    }

    static func parsePiModels(_ text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).dropFirst()
        return Array(Set(lines.compactMap { line -> String? in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 2 else { return nil }
            return "\(columns[0])/\(columns[1])"
        })).sorted()
    }
}
