import Foundation
import Observation

/// Per-model choices: which models the user turned off, and the reasoning
/// effort chosen for the ones that take one.
///
/// Everything a model *is* (its window, its ratings) comes from the curated
/// catalogue in `ModelProfile`; this store only holds what the user changed,
/// so a curated fact added later reaches every existing install.
///
/// The file is `AppPaths.modelPreferencesFile`: owner-only JSON, written
/// through `JSONFileStore`, keyed `"<provider UUID>|<model id>"` so the same
/// model id can be enabled on one endpoint and not another. The carried
/// reasoning effort rides along in the same file.
@Observable @MainActor
final class ModelPreferenceStore {
    /// What the user changed about one model. Both fields are optional so a
    /// profile written by an older build still decodes, and so "no choice
    /// yet" stays distinct from "chose Model default".
    struct StoredProfile: Codable, Sendable, Equatable {
        var enabled: Bool? = nil
        var reasoningEffort: ReasoningEffort? = nil
    }

    private struct Snapshot: Codable, Sendable {
        var profiles: [String: StoredProfile] = [:]
        var carriedReasoningEffort: ReasoningEffort = .modelDefault
    }

    /// The one store the app reads. Views take the store as a parameter as
    /// well, so previews and tests can pass an in-memory one.
    static let shared = ModelPreferenceStore()

    private(set) var profiles: [String: StoredProfile] = [:]

    /// The last effort chosen, on any model. A reasoning model with no choice
    /// of its own reads this back, which is what carries the choice over to
    /// the next model that supports the setting.
    private(set) var carriedReasoningEffort: ReasoningEffort = .modelDefault

    @ObservationIgnored private let file: JSONFileStore<Snapshot>?

    /// Pass `nil` for an in-memory store (tests, previews).
    init(fileURL: URL? = ModelPreferenceStore.defaultFileURL()) {
        self.file = fileURL.map { JSONFileStore(fileURL: $0, schemaVersion: 1) }
        load()
    }

    static func defaultFileURL() -> URL {
        AppPaths.modelPreferencesFile
    }

    // MARK: - Reading

    /// The resolved profile for one model: the curated facts with the user's
    /// choices on top. A model with no data reads as unknown, never guessed.
    func profile(providerID: UUID, model: String) -> ModelProfile {
        var profile = ModelProfile.curated(forModelID: model)
        let stored = profiles[ModelKey.make(providerID: providerID, model: model)]
        profile.enabled = stored?.enabled ?? profile.enabled
        if profile.supportsReasoningEffort {
            profile.reasoningEffort = stored?.reasoningEffort ?? carriedReasoningEffort
        } else {
            // A model that cannot take the setting always reads it back as
            // Model default, whatever was chosen elsewhere.
            profile.reasoningEffort = .modelDefault
        }
        return profile
    }

    /// Whether model pickers may offer this model. The default is on, unless
    /// the curated catalogue ships the model turned off (a sunset id).
    func isEnabled(providerID: UUID, model: String) -> Bool {
        profiles[ModelKey.make(providerID: providerID, model: model)]?.enabled
            ?? ModelProfile.curated(forModelID: model).enabled
    }

    /// Every model the given providers report, resolved, as rows for the
    /// Manage Models list. Providers keep their order, and so do their models.
    func entries(for providers: [InferenceProvider]) -> [ModelListEntry] {
        providers.flatMap { provider in
            provider.models.map { model in
                ModelListEntry(
                    providerID: provider.id,
                    providerName: provider.name,
                    model: model,
                    profile: profile(providerID: provider.id, model: model)
                )
            }
        }
    }

    // MARK: - Writing

    func setEnabled(_ enabled: Bool, providerID: UUID, model: String) {
        update(providerID: providerID, model: model) { $0.enabled = enabled }
    }

    /// Records an effort for one model and carries it to the next reasoning
    /// model that has no choice of its own.
    func setReasoningEffort(_ effort: ReasoningEffort, providerID: UUID, model: String) {
        carriedReasoningEffort = effort
        update(providerID: providerID, model: model) { $0.reasoningEffort = effort }
    }

    /// Called when the user switches to a model. A model that does not
    /// support reasoning effort clears the carried choice, so the next one
    /// that does starts back at Model default.
    func noteModelSelection(providerID: UUID, model: String) {
        guard !ModelProfile.curated(forModelID: model).supportsReasoningEffort,
              carriedReasoningEffort != .modelDefault
        else { return }
        carriedReasoningEffort = .modelDefault
        save()
    }

    /// Forgets every choice. The curated catalogue is untouched.
    func reset() {
        profiles.removeAll()
        carriedReasoningEffort = .modelDefault
        save()
    }

    /// Tests: block until queued writes are on disk.
    func waitForPendingWrites() {
        file?.flush()
    }

    // MARK: - Persistence

    private func update(
        providerID: UUID,
        model: String,
        mutation: (inout StoredProfile) -> Void
    ) {
        let key = ModelKey.make(providerID: providerID, model: model)
        var stored = profiles[key] ?? StoredProfile()
        mutation(&stored)
        profiles[key] = stored
        save()
    }

    private func load() {
        guard let snapshot = file?.load() else { return }
        profiles = snapshot.profiles
        carriedReasoningEffort = snapshot.carriedReasoningEffort
    }

    private func save() {
        file?.save(Snapshot(profiles: profiles, carriedReasoningEffort: carriedReasoningEffort))
    }
}
