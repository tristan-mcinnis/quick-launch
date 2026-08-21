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
            throw QuickServiceError.serverError("Model refresh failed: HTTP \(status)")
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

        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--offline", "--list-models"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "Pi model discovery failed"
                throw QuickServiceError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return Self.parsePiModels(text)
        }.value
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
