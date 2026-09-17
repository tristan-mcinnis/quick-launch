import Foundation

/// One provider and model a route may use, copied by value so a later
/// Settings change cannot move a turn that already resolved.
struct ChatRouteEndpoint: Equatable, Sendable {
    var provider: InferenceProvider
    var model: String

    var displayName: String {
        model.isEmpty ? provider.name : "\(provider.name) · \(ModelProfile.displayName(forModelID: model))"
    }
}

/// How a turn's images travel.
enum ChatImageMode: String, Equatable, Sendable {
    /// The turn carries no images.
    case none
    /// The images are sent to the provider as inline `data:` content.
    case inline
    /// The images stay on this Mac; only text read locally reaches the model.
    case textOnly
}

/// What the resolver is given. Every field is a fact from the app, so the
/// resolver itself is pure and testable without a view model.
struct ChatRouteRequest {
    /// What the user chose for this chat (or the Quick AI default).
    var selected: ChatRouteEndpoint
    /// The explicitly configured image route (Settings › Models), when one is
    /// configured. This is the only provider an image turn may fall back to.
    var vision: ChatRouteEndpoint?
    /// Whether the turn carries images at all, earlier turns' included.
    var hasImages: Bool
    /// Whether an image was attached to *this* turn (a screenshot or a tray
    /// chip) as opposed to only riding a turn already in the thread.
    var hasNewImages: Bool
    /// Whether the user explicitly accepted reading this turn's image as text
    /// on this Mac when no image route is available. False is the default and
    /// the only value the composer produces.
    var allowsTextOnlyFallback: Bool = false
    /// Whether an endpoint can actually run: a model is chosen, and a cloud
    /// OpenAI-compatible provider has its key (or a test service was injected).
    var isUsable: (ChatRouteEndpoint) -> Bool
    /// What the app knows about a model's image input.
    var capability: (ChatRouteEndpoint) -> ModelImageCapability
    /// The reasoning effort chosen for a model, and whether that model takes
    /// an explicit thinking directive. Read for the *effective* endpoint, so
    /// the recorded value matches what the provider receives.
    var effort: (ChatRouteEndpoint) -> ReasoningEffort
    var supportsThinking: (ChatRouteEndpoint) -> Bool

    init(
        selected: ChatRouteEndpoint,
        vision: ChatRouteEndpoint? = nil,
        hasImages: Bool,
        hasNewImages: Bool = false,
        allowsTextOnlyFallback: Bool = false,
        capability: @escaping (ChatRouteEndpoint) -> ModelImageCapability,
        isUsable: @escaping (ChatRouteEndpoint) -> Bool,
        effort: @escaping (ChatRouteEndpoint) -> ReasoningEffort = { _ in .modelDefault },
        supportsThinking: @escaping (ChatRouteEndpoint) -> Bool = { _ in false }
    ) {
        self.selected = selected
        self.vision = vision
        self.hasImages = hasImages
        self.hasNewImages = hasNewImages
        self.allowsTextOnlyFallback = allowsTextOnlyFallback
        self.capability = capability
        self.isUsable = isUsable
        self.effort = effort
        self.supportsThinking = supportsThinking
    }
}

/// One turn's fully resolved route: what the user chose, what will actually
/// serve the turn, where its images go, the thinking level the wire will
/// carry, and why the turn is blocked when it is.
///
/// The pre-Send label and the send path both read this one value, so the
/// label cannot disagree with what is sent.
struct ResolvedChatRoute: Equatable, Sendable {
    var chosen: ChatRouteEndpoint
    var effective: ChatRouteEndpoint
    var imageMode: ChatImageMode
    /// True only when the effective endpoint is a labelled vision fallback
    /// rather than the model the user picked.
    var isVisionFallback: Bool
    /// True when the chosen model is known to reject images, which is what
    /// makes the fallback a swap worth naming. False when the chosen model's
    /// capability is simply unknown.
    var chosenRejectsImages: Bool
    /// The reasoning effort the request will carry.
    var thinking: ReasoningEffort
    /// True when the provider takes an explicit thinking directive, so the
    /// wire carries "off" rather than omitting the field.
    var thinkingSupported: Bool
    /// Non-nil when the resolved route cannot run. The caller must not send.
    var warning: String?

    var isUsable: Bool { warning == nil }
    var hasImages: Bool { imageMode != .none }
    var canSendImages: Bool { imageMode == .inline }

    /// The thinking value the frozen route records, matching the wire.
    var thinkingValue: String? {
        ChatModelFreeze.thinkingValue(thinking, supported: thinkingSupported)
    }

    /// The one line the composer shows before Send.
    var label: String {
        guard warning == nil else {
            return hasImages ? "No vision model: this image cannot be sent" : "No model available"
        }
        switch imageMode {
        case .none:
            return effective.provider.location == .local ? "Only on this Mac" : "Will send to \(effective.provider.name)"
        case .textOnly:
            return "Will send as text (read on this Mac)"
        case .inline:
            if isVisionFallback, chosenRejectsImages {
                return "\(chosen.provider.name) cannot read images; will send the image to \(effective.provider.name)"
            }
            return "Will send the image to \(effective.provider.name)"
        }
    }
}

/// Resolves the one route a turn will use.
///
/// The rules the approved plan fixes:
///
/// - the model the user selected is preferred whenever it is *known* to read
///   images, even when the global vision default names another provider;
/// - the configured vision endpoint is a labelled fallback, used only when
///   the selected model is not known to read images;
/// - a missing credential blocks with the fix, and never quietly switches
///   provider or model;
/// - an image attached to *this* turn is refused rather than silently read by
///   OCR, unless the user explicitly accepted that;
/// - an image carried from an earlier turn falls back to on-Mac text when no
///   image route is available, because the user attached nothing new.
enum ChatRouteResolver {
    static func resolve(_ request: ChatRouteRequest) -> ResolvedChatRoute {
        let selectedCapability = request.capability(request.selected)

        guard request.hasImages else {
            var route = makeRoute(
                request: request,
                effective: request.selected,
                imageMode: .none,
                isFallback: false,
                chosenRejectsImages: false
            )
            route.warning = usabilityWarning(for: request.selected, request: request)
            return route
        }

        // 1. The selected model is known to read images: it wins. A missing
        //    key blocks rather than swapping to the vision default.
        if selectedCapability == .acceptsImages {
            var route = makeRoute(
                request: request,
                effective: request.selected,
                imageMode: .inline,
                isFallback: false,
                chosenRejectsImages: false
            )
            route.warning = usabilityWarning(for: request.selected, request: request)
            return route
        }

        // 2. The configured vision endpoint, when it is usable, is the one
        //    labelled fallback an image turn may take. When it is the same
        //    endpoint the user already selected, the configuration itself is
        //    the evidence and nothing is labelled as a swap.
        if let vision = request.vision, request.isUsable(vision) {
            let sameEndpoint = vision.provider.id == request.selected.provider.id
                && vision.model == request.selected.model
            return makeRoute(
                request: request,
                effective: vision,
                imageMode: .inline,
                isFallback: !sameEndpoint,
                chosenRejectsImages: !sameEndpoint && selectedCapability == .textOnly
            )
        }

        // 3. No image route. A newly attached image is refused unless the
        //    user accepted on-Mac text; an image carried from an earlier turn
        //    is read locally, since nothing new was attached.
        if request.hasNewImages, !request.allowsTextOnlyFallback {
            var route = makeRoute(
                request: request,
                effective: request.selected,
                imageMode: .textOnly,
                isFallback: false,
                chosenRejectsImages: selectedCapability == .textOnly
            )
            route.warning = imageWarning(for: request.selected, capability: selectedCapability)
            return route
        }

        var route = makeRoute(
            request: request,
            effective: request.selected,
            imageMode: .textOnly,
            isFallback: false,
            chosenRejectsImages: selectedCapability == .textOnly
        )
        route.warning = usabilityWarning(for: request.selected, request: request)
        return route
    }

    /// One route, with the reasoning the effective model will really send.
    private static func makeRoute(
        request: ChatRouteRequest,
        effective: ChatRouteEndpoint,
        imageMode: ChatImageMode,
        isFallback: Bool,
        chosenRejectsImages: Bool
    ) -> ResolvedChatRoute {
        ResolvedChatRoute(
            chosen: request.selected,
            effective: effective,
            imageMode: imageMode,
            isVisionFallback: isFallback,
            chosenRejectsImages: chosenRejectsImages,
            thinking: request.effort(effective),
            thinkingSupported: request.supportsThinking(effective),
            warning: nil
        )
    }

    /// A provider that cannot run at all: no model, or a cloud
    /// OpenAI-compatible endpoint with no key. Never a reason to swap.
    private static func usabilityWarning(
        for endpoint: ChatRouteEndpoint,
        request: ChatRouteRequest
    ) -> String? {
        if endpoint.model.isEmpty {
            return "Choose a provider and model in Settings."
        }
        if !request.isUsable(endpoint) {
            return "\(endpoint.provider.name) needs an API key. Add it under Settings › Models."
        }
        return nil
    }

    private static func imageWarning(
        for selected: ChatRouteEndpoint,
        capability: ModelImageCapability
    ) -> String {
        capability == .textOnly
            ? "\(selected.provider.name) · \(selected.model) cannot read images. Choose a vision model in Settings › Models, or remove the image."
            : "\(selected.provider.name) is not known to read images. Choose a vision model in Settings › Models, or remove the image."
    }
}
