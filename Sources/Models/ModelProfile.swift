import Foundation

/// One model's local profile: what the user chose about it, plus what the app
/// ships knowing about it.
///
/// Nothing here is fetched. Quick Launch talks to user-configured
/// OpenAI-compatible endpoints, which publish model ids and nothing else, so
/// every number below is either curated in `ModelProfile.curatedTable` or
/// absent. A field with no data stays `nil` and reads "Unknown": a model with
/// no data is never given a guessed number.
struct ModelProfile: Codable, Sendable, Equatable, Hashable {
    /// Whether the model pickers may offer this model. Off means hidden
    /// everywhere, not deleted.
    var enabled: Bool
    /// Curated 1 to 5 rating, 5 fastest. `nil` means not known.
    var speed: ModelRating?
    /// Curated 1 to 5 rating, 5 strongest. `nil` means not known.
    var intelligence: ModelRating?
    /// Total context window in tokens. `nil` means not known.
    var contextWindow: Int?
    /// Whether the provider takes a reasoning-effort parameter for this model.
    var supportsReasoningEffort: Bool
    /// The chosen effort. `.modelDefault` lets the provider decide.
    var reasoningEffort: ReasoningEffort

    init(
        enabled: Bool = true,
        speed: ModelRating? = nil,
        intelligence: ModelRating? = nil,
        contextWindow: Int? = nil,
        supportsReasoningEffort: Bool = false,
        reasoningEffort: ReasoningEffort = .modelDefault
    ) {
        self.enabled = enabled
        self.speed = speed
        self.intelligence = intelligence
        self.contextWindow = contextWindow
        self.supportsReasoningEffort = supportsReasoningEffort
        self.reasoningEffort = reasoningEffort
    }
}

// MARK: - Display

extension ModelProfile {
    /// "Unknown" when nothing is known, otherwise a compact token count such
    /// as `1M`, `256K`, or `131.1K`.
    var contextWindowLabel: String {
        Self.contextWindowLabel(contextWindow)
    }

    static func contextWindowLabel(_ tokens: Int?) -> String {
        guard let tokens, tokens > 0 else { return "Unknown" }
        if tokens >= 1_000_000 {
            let millions = Double(tokens) / 1_000_000
            return millions == millions.rounded()
                ? "\(Int(millions))M"
                : String(format: "%.1fM", millions)
        }
        if tokens >= 1_000 {
            let thousands = Double(tokens) / 1_000
            return thousands == thousands.rounded()
                ? "\(Int(thousands))K"
                : String(format: "%.1fK", thousands)
        }
        return "\(tokens)"
    }
}

// MARK: - The curated catalogue

extension ModelProfile {
    /// What the app ships knowing about the model ids its own providers
    /// reference. Keys are lowercased, because ids come back from servers.
    ///
    /// Facts come from the vendor's own model documentation: the context
    /// window, and whether the API takes a reasoning-effort parameter for
    /// that id. Speed and intelligence are not vendor-published numbers; they
    /// are this app's local curation of the vendor's stated positioning, with
    /// a `flash` / `highspeed` / `mini` tier rated for speed and a `pro` /
    /// flagship tier rated for intelligence. Anything not listed here, and
    /// anything listed without a number, reads as unknown in the UI.
    static let curatedTable: [String: ModelProfile] = [
        // DeepSeek API (api-docs.deepseek.com). V4 is a thinking family, so
        // every V4 id takes a reasoning effort, and all three serve a
        // 1M-token context.
        "deepseek-v4-flash": ModelProfile(
            speed: .five,
            intelligence: .four,
            contextWindow: 1_000_000,
            supportsReasoningEffort: true
        ),
        "deepseek-v4-pro": ModelProfile(
            speed: .three,
            intelligence: .five,
            contextWindow: 1_000_000,
            supportsReasoningEffort: true
        ),
        // The image-capable V4 id.
        "deepseek-v4-flash-vision-exp": ModelProfile(
            speed: .four,
            intelligence: .four,
            contextWindow: 1_000_000,
            supportsReasoningEffort: true
        ),
        // Moonshot / Kimi API (platform.moonshot.ai). K3 is the 1M-context
        // flagship and takes a reasoning effort. K2.6 and K2.7 Code steer
        // thinking with their own `thinking` object instead, so they get no
        // reasoning-effort control.
        "kimi-k3": ModelProfile(
            speed: .three,
            intelligence: .five,
            contextWindow: 1_000_000,
            supportsReasoningEffort: true
        ),
        "kimi-k2.6": ModelProfile(
            speed: .four,
            intelligence: .four,
            contextWindow: 256_000
        ),
        "kimi-k2.7-code-highspeed": ModelProfile(
            speed: .five,
            intelligence: .four,
            contextWindow: 256_000
        ),
        // Local models served by the local-models daemon. The window is the
        // vendor's published figure for the open-weight family; no reasoning
        // effort is offered, because the daemon documents no such parameter.
        // `s1-mini` is left unknown: the name covers more than one family.
        "qwen3-vl": ModelProfile(speed: .four, intelligence: .three, contextWindow: 256_000),
        "qwen3.5": ModelProfile(speed: .four, intelligence: .three, contextWindow: 256_000),
        "gemma-it": ModelProfile(speed: .five, intelligence: .two, contextWindow: 128_000),
        "s1-mini": ModelProfile(),
    ]

    /// The curated profile for `modelID`, or an all-unknown profile when the
    /// app ships no data for it.
    static func curated(forModelID modelID: String) -> ModelProfile {
        curatedTable[modelID.lowercased()] ?? ModelProfile()
    }
}

// MARK: - Rating

/// A curated 1 to 5 rating on one axis. Five is always the good end: fastest
/// for speed, strongest for intelligence.
enum ModelRating: Int, Codable, Sendable, CaseIterable, Identifiable, Comparable {
    case one = 1
    case two
    case three
    case four
    case five

    /// The number of dots a rating is drawn with, and the top of the scale.
    static let scale = 5

    var id: Int { rawValue }

    static func < (lhs: ModelRating, rhs: ModelRating) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// VoiceOver-friendly wording: "4 of 5".
    var title: String { "\(rawValue) of \(Self.scale)" }
}

// MARK: - Reasoning effort

/// How hard a reasoning model should think before answering. This is the
/// provider's own parameter; `.modelDefault` sends nothing and lets the
/// provider choose.
///
/// Only `low` and `high` sit beside the default. Both are documented by every
/// provider in the curated catalogue that takes the parameter (DeepSeek's V4
/// family and Moonshot's K3), so no option offered here is a value the app
/// invented. A per-provider ladder belongs here if one is ever needed.
enum ReasoningEffort: String, Codable, Sendable, CaseIterable, Identifiable {
    case modelDefault
    case low
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modelDefault: "Model default"
        case .low: "Low"
        case .high: "High"
        }
    }
}

// MARK: - Sorting

/// The five ways the Manage Models list can be ordered, in the order the
/// control offers them.
enum ModelSortOrder: String, Sendable, CaseIterable, Identifiable {
    case brand
    case alphabetically
    case speed
    case intelligence
    case contextWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brand: "Brand"
        case .alphabetically: "Alphabetically"
        case .speed: "Speed"
        case .intelligence: "Intelligence"
        case .contextWindow: "Context Window"
        }
    }
}

// MARK: - Rows

/// The key a profile is stored under: one model on one endpoint. The same
/// model id on two endpoints is two rows with two profiles.
enum ModelKey {
    static func make(providerID: UUID, model: String) -> String {
        "\(providerID.uuidString)|\(model)"
    }
}

/// One row of the Manage Models list: a model, the provider it belongs to,
/// and its resolved profile.
struct ModelListEntry: Identifiable, Sendable, Equatable {
    let providerID: UUID
    let providerName: String
    let model: String
    var profile: ModelProfile

    var id: String { ModelKey.make(providerID: providerID, model: model) }

    /// The maker of the model, used by the Brand sort.
    var brand: String { ModelBrand.of(modelID: model) }
}

/// A provider's rows, for the grouped list.
struct ModelGroup: Identifiable, Sendable, Equatable {
    let providerID: UUID
    let providerName: String
    var entries: [ModelListEntry]

    var id: UUID { providerID }
}

/// The maker of a model, read from its id. Used only to order the list, never
/// shown as a fact about the model.
enum ModelBrand {
    /// Matched in order against the whole id, and against the provider
    /// prefix of an id such as `deepseek/deepseek-v4-flash`.
    private static let known: [(needle: String, brand: String)] = [
        ("deepseek", "DeepSeek"),
        ("moonshot", "Moonshot"),
        ("kimi", "Moonshot"),
        ("anthropic", "Anthropic"),
        ("claude", "Anthropic"),
        ("sonnet", "Anthropic"),
        ("opus", "Anthropic"),
        ("haiku", "Anthropic"),
        ("openai", "OpenAI"),
        ("gpt", "OpenAI"),
        ("qwen", "Qwen"),
        ("gemini", "Google"),
        ("gemma", "Google"),
        ("llama", "Meta"),
        ("mistral", "Mistral"),
        ("mixtral", "Mistral"),
        ("xiaomi", "Xiaomi"),
        ("mimo", "Xiaomi"),
    ]

    /// "Other" when the id names no maker this app knows.
    static func of(modelID: String) -> String {
        let folded = modelID.lowercased()
        if let prefix = folded.split(separator: "/").first, folded.contains("/") {
            let head = String(prefix)
            if let match = known.first(where: { head.contains($0.needle) }) {
                return match.brand
            }
        }
        if let match = known.first(where: { folded.contains($0.needle) }) {
            return match.brand
        }
        return "Other"
    }
}

// MARK: - List assembly

/// Search, sorting, and grouping for the Manage Models list, kept out of the
/// view so the ordering can be tested on its own.
enum ModelList {
    /// Rows matching `query` by model name, provider name, or brand. An empty
    /// query matches everything.
    static func matching(_ entries: [ModelListEntry], query: String) -> [ModelListEntry] {
        let needle = FuzzyMatcher.fold(query)
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            FuzzyMatcher.fold(entry.model).contains(needle)
                || FuzzyMatcher.fold(entry.providerName).contains(needle)
                || FuzzyMatcher.fold(entry.brand).contains(needle)
        }
    }

    /// `entries` in the chosen order. Ties break on provider then model name,
    /// so the list is stable.
    static func sorted(_ entries: [ModelListEntry], by order: ModelSortOrder) -> [ModelListEntry] {
        entries.sorted { lhs, rhs in
            switch order {
            case .brand:
                if lhs.brand != rhs.brand { return ascending(lhs.brand, rhs.brand) }
            case .speed:
                if lhs.profile.speed != rhs.profile.speed {
                    return ranked(lhs.profile.speed, rhs.profile.speed)
                }
            case .intelligence:
                if lhs.profile.intelligence != rhs.profile.intelligence {
                    return ranked(lhs.profile.intelligence, rhs.profile.intelligence)
                }
            case .contextWindow:
                if lhs.profile.contextWindow != rhs.profile.contextWindow {
                    return ranked(lhs.profile.contextWindow, rhs.profile.contextWindow)
                }
            case .alphabetically:
                break
            }
            return tieBreak(lhs, rhs)
        }
    }

    /// One group per provider, in the order the providers were given.
    static func grouped(_ entries: [ModelListEntry]) -> [ModelGroup] {
        var order: [UUID] = []
        var names: [UUID: String] = [:]
        var rows: [UUID: [ModelListEntry]] = [:]
        for entry in entries {
            if rows[entry.providerID] == nil {
                order.append(entry.providerID)
                names[entry.providerID] = entry.providerName
            }
            rows[entry.providerID, default: []].append(entry)
        }
        return order.map { id in
            ModelGroup(providerID: id, providerName: names[id] ?? "", entries: rows[id] ?? [])
        }
    }

    /// The whole list, ready to draw: filtered, sorted, and grouped or flat.
    static func build(
        _ entries: [ModelListEntry],
        query: String,
        order: ModelSortOrder,
        groupsByProvider: Bool
    ) -> (flat: [ModelListEntry], groups: [ModelGroup]) {
        let sorted = sorted(matching(entries, query: query), by: order)
        return (sorted, groupsByProvider ? grouped(sorted) : [])
    }

    // MARK: Ordering helpers

    /// Known ratings sort above unknown ones; higher is better.
    private static func ranked<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs: lhs > rhs
        case (nil, _?): false
        case (_?, nil): true
        default: false
        }
    }

    private static func ascending(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func tieBreak(_ lhs: ModelListEntry, _ rhs: ModelListEntry) -> Bool {
        if lhs.model != rhs.model { return ascending(lhs.model, rhs.model) }
        if lhs.providerName != rhs.providerName {
            return ascending(lhs.providerName, rhs.providerName)
        }
        return lhs.id < rhs.id
    }
}
