import Foundation
import HouseChatCore

/// One request's model route, captured at Send and never re-read.
///
/// The chat keeps its own chosen model, but a turn's record must show what
/// that turn actually used. Freezing the provider, the model, the thinking
/// level, and the destination here means a later model change, a provider
/// edit, or a vision fallback cannot rewrite an earlier turn's history.
struct FrozenChatModel: Sendable, Equatable {
    let providerID: UUID
    let providerName: String
    let providerKind: InferenceProviderKind
    let location: InferenceProviderLocation
    /// The exact model id the provider was asked for.
    let model: String
    /// The reasoning level sent, or nil when the provider decides.
    let thinking: String?
    /// What the pre-Send label shows: "Sent to DeepSeek", "Only on this Mac".
    let destination: String
    /// The endpoint the request went to, sanitized (no userinfo, no query).
    let endpoint: EndpointDescriptor?

    /// The chosen side of the turn's `ModelSelection`.
    var choice: ModelChoice {
        ModelChoice(provider: providerName, model: model, thinking: thinking)
    }

    /// A frozen route with no effective fallback recorded yet.
    var selection: ModelSelection {
        ModelSelection(chosen: choice, effective: choice)
    }

    /// The same route with an explicit effective side, for a labelled
    /// fallback (a vision model, a downgrade).
    func selection(effective: ModelChoice?) -> ModelSelection {
        ModelSelection(chosen: choice, effective: effective ?? choice)
    }
}

/// Builds a `FrozenChatModel` from the app's live configuration.
enum ChatModelFreeze {
    /// Captures the route. Everything is copied by value, so the result is
    /// immune to a later change to the provider, settings, or chat.
    static func freeze(
        provider: InferenceProvider,
        model: String,
        thinking: ReasoningEffort,
        supportsThinking: Bool = false,
        destination: String? = nil
    ) -> FrozenChatModel {
        FrozenChatModel(
            providerID: provider.id,
            providerName: provider.name,
            providerKind: provider.kind,
            location: provider.location,
            model: model,
            thinking: Self.thinkingValue(thinking, supported: supportsThinking),
            destination: destination ?? destinationLabel(for: provider),
            endpoint: URL(string: provider.baseURL).flatMap { EndpointDescriptor(url: $0) }
        )
    }

    /// `nil` when the provider is sent no thinking directive, otherwise the
    /// value the wire carries. A known thinking-capable model with the model
    /// default sends an explicit "disabled" (DeepSeek's own `thinking.type`),
    /// so "Fast" is a fact on the wire and not merely an omitted field.
    static func thinkingValue(_ effort: ReasoningEffort, supported: Bool = false) -> String? {
        switch effort {
        case .modelDefault: supported ? "disabled" : nil
        case .low: "low"
        case .high: "high"
        }
    }

    static func destinationLabel(for provider: InferenceProvider) -> String {
        switch provider.location {
        case .cloud: "Sent to \(provider.name)"
        case .local: provider.kind == .commandLine ? "Run on this Mac" : "Only on this Mac"
        }
    }
}
