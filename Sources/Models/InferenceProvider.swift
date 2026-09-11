import Foundation

enum InferenceProviderKind: String, Codable, Sendable, CaseIterable {
    case openAICompatible
    case commandLine
}

enum InferenceProviderLocation: String, Codable, Sendable {
    case local
    case cloud
}

enum ModelDiscoveryStrategy: String, Codable, Sendable {
    case none
    case openAI
    case lmStudio
    case pi
}

struct CommandConfiguration: Codable, Sendable, Equatable, Hashable {
    var executable: String
    var arguments: [String]

    init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// One selectable inference source. Providers own their model catalogue, while
/// `QuickSettings.selectedProviderID` identifies the active source.
struct InferenceProvider: Codable, Sendable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var kind: InferenceProviderKind
    var location: InferenceProviderLocation
    var baseURL: String
    var models: [String]
    var selectedModel: String
    var discovery: ModelDiscoveryStrategy
    var command: CommandConfiguration?
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        kind: InferenceProviderKind,
        location: InferenceProviderLocation,
        baseURL: String = "",
        models: [String] = [],
        selectedModel: String = "",
        discovery: ModelDiscoveryStrategy = .none,
        command: CommandConfiguration? = nil,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.baseURL = baseURL
        self.models = models
        self.selectedModel = selectedModel
        self.discovery = discovery
        self.command = command
        self.isBuiltIn = isBuiltIn
    }

    var displayModel: String {
        selectedModel.isEmpty ? "Choose model" : selectedModel
    }
}

extension InferenceProvider {
    static let lmStudioID = UUID(uuidString: "EB79F178-A20A-4BB2-B0CE-C751E6480E0D")!
    static let deepSeekID = UUID(uuidString: "D49908A5-649F-462B-A569-F75495568A82")!
    /// DeepSeek's one flash model (DeepSeek V4.1 Flash), for text and images.
    /// The DeepSeek API lists only `deepseek-flash` and `deepseek-v4-pro`;
    /// the older ids below still resolve to it as aliases (checked
    /// 2026-09-11), and pi uses the same id.
    static let deepSeekDefaultModel = "deepseek-flash"
    /// Images go to the same model: `deepseek-flash` reads them.
    static let deepSeekVisionModel = deepSeekDefaultModel
    /// Retired DeepSeek ids, moved to `deepSeekDefaultModel` on load.
    static let legacyDeepSeekFlashModels: Set<String> = [
        "deepseek-v4-flash", "deepseek-v4-flash-vision-exp",
    ]
    static let moonshotID = UUID(uuidString: "9001D74E-B44B-46F7-B8BF-803E743A64C1")!
    static let openAIID = UUID(uuidString: "343A1F1C-C113-493F-92B8-F93D0636603F")!
    static let claudeCodeID = UUID(uuidString: "DD72A9CC-D388-471A-A081-A8C5DD55BC3E")!
    static let piID = UUID(uuidString: "288A36B5-DA8E-4916-8A33-6CD5777762BB")!
    static let mlxVisionID = UUID(uuidString: "9D12D3E7-3E4F-4C37-93BB-59CE9D61C66B")!
    /// local-models daemon (127.0.0.1:8078), OpenAI passthrough under /v1.
    static let localModelsBaseURL = "http://127.0.0.1:8078/v1"
    static let localModelsDefaultModel = "qwen3-vl"
    /// Where the local vision provider pointed before 2026-09-02: the raw
    /// mlx-vlm port. Settings still on it are moved to the daemon.
    static let legacyMLXVisionBaseURL = "http://127.0.0.1:8080"

    static var defaults: [InferenceProvider] {
        return [
            InferenceProvider(
                id: lmStudioID,
                name: "LM Studio",
                kind: .openAICompatible,
                location: .local,
                baseURL: "http://127.0.0.1:1234/v1",
                discovery: .lmStudio,
                isBuiltIn: true
            ),
            InferenceProvider(
                id: mlxVisionID,
                name: "Local Models",
                kind: .openAICompatible,
                location: .local,
                // The local-models daemon: one OpenAI-compatible door for
                // every local backend, never a backend port directly.
                baseURL: Self.localModelsBaseURL,
                models: ["qwen3-vl", "qwen3.5", "gemma-it", "s1-mini"],
                selectedModel: Self.localModelsDefaultModel,
                discovery: .openAI,
                isBuiltIn: true
            ),
            InferenceProvider(
                id: deepSeekID,
                name: "DeepSeek API",
                kind: .openAICompatible,
                location: .cloud,
                baseURL: "https://api.deepseek.com",
                models: [deepSeekDefaultModel, "deepseek-v4-pro"],
                selectedModel: deepSeekDefaultModel,
                discovery: .openAI,
                isBuiltIn: true
            ),
            InferenceProvider(
                id: moonshotID,
                name: "Moonshot / Kimi API",
                kind: .openAICompatible,
                location: .cloud,
                baseURL: "https://api.moonshot.ai/v1",
                models: ["kimi-k3", "kimi-k2.7-code-highspeed", "kimi-k2.6"],
                selectedModel: "kimi-k3",
                discovery: .openAI,
                isBuiltIn: true
            ),
            InferenceProvider(
                id: openAIID,
                name: "OpenAI API",
                kind: .openAICompatible,
                location: .cloud,
                baseURL: "https://api.openai.com/v1",
                models: [],
                selectedModel: "",
                discovery: .openAI,
                isBuiltIn: true
            ),
            InferenceProvider(
                id: claudeCodeID,
                name: "Claude Code subscription",
                kind: .commandLine,
                location: .cloud,
                models: ["sonnet", "fable", "opus", "haiku"],
                selectedModel: "sonnet",
                command: CommandConfiguration(
                    executable: "claude",
                    arguments: [
                        "-p",
                        "--no-session-persistence",
                        "--output-format", "text",
                        "--tools", "",
                        "--model", "{{model}}",
                        "--system-prompt", "{{systemPrompt}}",
                    ]
                ),
                isBuiltIn: true
            ),
            InferenceProvider(
                id: piID,
                name: "Pi tools and skills",
                kind: .commandLine,
                location: .cloud,
                models: [],
                selectedModel: "",
                discovery: .pi,
                command: CommandConfiguration(
                    executable: "pi",
                    arguments: [
                        "--print",
                        "--no-session",
                        "--no-context-files",
                        "--no-builtin-tools",
                        "--model", "{{model}}",
                        "--system-prompt", "{{systemPrompt}}",
                    ]
                ),
                isBuiltIn: true
            ),
        ]
    }
}

/// Decodes an array and drops elements that no longer decode, for example a
/// provider kind that was removed, instead of failing the whole settings blob.
struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else if (try? container.decode(Skip.self)) == nil {
                break
            }
        }
        elements = result
    }
}
