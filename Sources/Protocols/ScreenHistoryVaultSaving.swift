import Foundation

/// The explicit promotion boundary from local screen history to vault triage.
/// Searching or viewing a frame never calls this protocol.
protocol ScreenHistoryVaultSaving: Sendable {
    @discardableResult
    func save(
        _ frame: ScreenHistoryFrame,
        note: String?,
        projectSlug: String?
    ) async throws -> URL
}
