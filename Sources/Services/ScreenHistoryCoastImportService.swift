import Foundation

/// Production bridge for the explicit Coast import control. It only reads the
/// Coast root. Metadata and verified copies are written through owned stores.
/// Source files are never removed or modified.
actor ScreenHistoryCoastImportService: ScreenHistoryCoastImporting {
    private let reader: any CoastLegacyReading
    private let store: SQLiteScreenHistoryStore
    private let legacyContentRootURL: URL
    private let ownedMediaDirectoryURL: URL
    private var approvedPreview: ApprovedPreview?

    private struct ApprovedPreview: Sendable {
        let publicValue: ScreenHistoryCoastImportPreview
        let policy: ScreenHistoryMigrationPolicy
        let migrationValue: ScreenHistoryMigrationPreviewResult
    }

    init(
        reader: any CoastLegacyReading,
        store: SQLiteScreenHistoryStore,
        legacyContentRootURL: URL,
        ownedMediaDirectoryURL: URL = ScreenHistoryMediaMigrationService.defaultOwnedMediaDirectoryURL()
    ) {
        self.reader = reader
        self.store = store
        self.legacyContentRootURL = legacyContentRootURL
        self.ownedMediaDirectoryURL = ownedMediaDirectoryURL
    }

    func sourceIsAvailable() async -> Bool {
        await reader.isAvailable()
    }

    func previewMetadata(policy: ScreenHistoryMigrationPolicy) async throws -> ScreenHistoryCoastImportPreview {
        let migration = try await ScreenHistoryMigrationService(
            reader: reader,
            store: store,
            policy: policy
        ).preview()
        let preview = ScreenHistoryCoastImportPreview(
            authorizationID: UUID(),
            sourceRows: migration.source,
            importedRows: migration.imported,
            excludedRows: migration.excluded,
            invalidRows: migration.invalid,
            reconciliation: migration.reconciliation,
            policyFingerprint: migration.policyFingerprint,
            sourceFingerprint: migration.sourceFingerprint
        )
        approvedPreview = ApprovedPreview(
            publicValue: preview,
            policy: policy,
            migrationValue: migration
        )
        return preview
    }

    func invalidatePreview() {
        approvedPreview = nil
    }

    func importMetadata(
        preview: ScreenHistoryCoastImportPreview,
        policy: ScreenHistoryMigrationPolicy
    ) async throws -> ScreenHistoryMigrationResult {
        guard let approvedPreview,
              approvedPreview.publicValue == preview,
              approvedPreview.policy == policy,
              preview.policyFingerprint == policy.fingerprint
        else {
            self.approvedPreview = nil
            throw ScreenHistoryCoastImportError.stalePreview
        }

        let service = ScreenHistoryMigrationService(
            reader: reader,
            store: store,
            policy: approvedPreview.policy,
            clock: { approvedPreview.migrationValue.evaluatedAt }
        )
        let current = try await service.preview()
        guard self.approvedPreview?.publicValue.authorizationID == preview.authorizationID else {
            self.approvedPreview = nil
            throw ScreenHistoryCoastImportError.stalePreview
        }
        guard current == approvedPreview.migrationValue else {
            self.approvedPreview = nil
            throw ScreenHistoryCoastImportError.sourceChanged
        }

        // Consume the one-shot authorization before the first owned write.
        self.approvedPreview = nil
        return try await service.migrate()
    }

    func copyVerifiedMedia() async throws -> ScreenHistoryMediaMigrationResult {
        try await ScreenHistoryMediaMigrationService(
            store: store,
            legacyContentRootURL: legacyContentRootURL,
            ownedMediaDirectoryURL: ownedMediaDirectoryURL
        ).migrate()
    }

    func verificationSampleCount(limit: Int) async throws -> Int {
        try await ScreenHistoryMediaMigrationService(
            store: store,
            legacyContentRootURL: legacyContentRootURL,
            ownedMediaDirectoryURL: ownedMediaDirectoryURL
        ).migratedMomentSample(limit: limit).count
    }
}
