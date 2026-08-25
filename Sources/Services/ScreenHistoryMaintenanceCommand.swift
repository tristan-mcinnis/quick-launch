import Foundation

enum ScreenHistoryMaintenanceCommand: String, Sendable {
    case prepareImport = "--screen-history-prepare-import"

    static func parse(_ arguments: [String]) -> Self? {
        arguments.compactMap(Self.init(rawValue:)).first
    }
}

struct ScreenHistoryMaintenanceEquation: Codable, Equatable, Sendable {
    let source: Int
    let imported: Int
    let excluded: Int
    let invalid: Int
    let reconciles: Bool

    init(_ equation: ScreenHistoryMigrationFamilyEquation) {
        source = equation.source
        imported = equation.imported
        excluded = equation.excluded
        invalid = equation.invalid
        reconciles = equation.reconciles
    }
}

struct ScreenHistoryMaintenanceReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let completedAt: Date
    let freezeManifestSHA256: String
    let freezeFileCount: Int
    let freezeByteCount: Int64
    let sourceRows: Int
    let importedRows: Int
    let excludedRows: Int
    let invalidRows: Int
    let policyFingerprint: String
    let sourceFingerprint: String
    let equations: [String: ScreenHistoryMaintenanceEquation]
    let ownedRowDelta: Int
    let migrationHashDelta: Int
    let mappingCount: Int
    let migrationLedgerCount: Int
    let mediaSourceRows: Int
    let uniqueMediaLocators: Int
    let copiedFileDelta: Int
    let mediaHashDelta: Int
    let updatedMediaRows: Int
    let mediaFailureCount: Int
    let verificationSampleCount: Int
    let ownedFrameCount: Int
    let normalizedStructureDrift: Int
    let mediaIntegrityFailureMoments: Int
}

enum ScreenHistoryMaintenanceError: Error {
    case unavailable
    case freezeUnavailable
    case freezeIncomplete
    case reconciliationFailed
    case mediaFailures(Int)
    case verificationSampleIncomplete(Int)
}

actor ScreenHistoryMaintenanceRunner {
    private let store: SQLiteScreenHistoryStore
    private let importer: ScreenHistoryCoastImportService
    private let freezeReceipt: ScreenHistoryCoastFreezeReceiptService
    private let reviewer: ScreenHistoryRetirementReviewService
    private let clock: @Sendable () -> Date

    init(
        store: SQLiteScreenHistoryStore,
        importer: ScreenHistoryCoastImportService,
        freezeReceipt: ScreenHistoryCoastFreezeReceiptService,
        reviewer: ScreenHistoryRetirementReviewService,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.importer = importer
        self.freezeReceipt = freezeReceipt
        self.reviewer = reviewer
        self.clock = clock
    }

    func prepareImport(policy: ScreenHistoryMigrationPolicy) async throws -> ScreenHistoryMaintenanceReceipt {
        guard await importer.sourceIsAvailable() else {
            throw ScreenHistoryMaintenanceError.unavailable
        }

        let freeze = try await freezeReceipt.makePrimaryReceipt(maximumNewFiles: nil)
        guard freeze.isComplete, let frozen = freeze.receipt else {
            throw ScreenHistoryMaintenanceError.freezeIncomplete
        }

        let preview = try await importer.previewMetadata(policy: policy)
        guard preview.reconciles else {
            throw ScreenHistoryMaintenanceError.reconciliationFailed
        }
        let migration = try await importer.importMetadata(preview: preview, policy: policy)
        guard migration.reconciles else {
            throw ScreenHistoryMaintenanceError.reconciliationFailed
        }

        let media = try await importer.copyVerifiedMedia()
        guard media.failures.isEmpty else {
            throw ScreenHistoryMaintenanceError.mediaFailures(media.failures.count)
        }
        let sampleCount = try await importer.verificationSampleCount(
            limit: ScreenHistoryCoastImportSummary.verificationSampleTarget
        )
        guard sampleCount == ScreenHistoryCoastImportSummary.verificationSampleTarget else {
            throw ScreenHistoryMaintenanceError.verificationSampleIncomplete(sampleCount)
        }
        let review = try await reviewer.refresh()
        let ownedCount = try await store.count()
        let equations = Self.equations(preview.reconciliation)
        guard equations.values.allSatisfy(\.reconciles) else {
            throw ScreenHistoryMaintenanceError.reconciliationFailed
        }

        return ScreenHistoryMaintenanceReceipt(
            schemaVersion: Int(SQLiteScreenHistoryStore.schemaVersion),
            completedAt: clock(),
            freezeManifestSHA256: frozen.primary.manifestSHA256,
            freezeFileCount: frozen.primary.files.count + 1,
            freezeByteCount: frozen.primary.files.reduce(frozen.primary.database.byteCount) { $0 + $1.byteCount },
            sourceRows: preview.sourceRows,
            importedRows: preview.importedRows,
            excludedRows: preview.excludedRows,
            invalidRows: preview.invalidRows,
            policyFingerprint: preview.policyFingerprint,
            sourceFingerprint: preview.sourceFingerprint,
            equations: equations,
            ownedRowDelta: migration.ownedRowDelta,
            migrationHashDelta: migration.hashDelta,
            mappingCount: migration.mappingCount,
            migrationLedgerCount: migration.ledgerCount,
            mediaSourceRows: media.sourceRows,
            uniqueMediaLocators: media.uniqueLocators,
            copiedFileDelta: media.copiedFileDelta,
            mediaHashDelta: media.hashDelta,
            updatedMediaRows: media.updatedRowDelta,
            mediaFailureCount: media.failures.count,
            verificationSampleCount: sampleCount,
            ownedFrameCount: ownedCount,
            normalizedStructureDrift: review.readiness.normalizedStructureDrift,
            mediaIntegrityFailureMoments: review.readiness.mediaIntegrityFailureMoments
        )
    }

    private static func equations(
        _ reconciliation: ScreenHistoryMigrationReconciliation
    ) -> [String: ScreenHistoryMaintenanceEquation] {
        var result = ["frame": ScreenHistoryMaintenanceEquation(reconciliation.frame)]
        for (name, equation) in [
            ("ocr", reconciliation.ocr),
            ("application", reconciliation.application),
            ("domain", reconciliation.domain),
            ("sequence", reconciliation.sequence),
            ("media", reconciliation.media),
        ] {
            if let equation { result[name] = ScreenHistoryMaintenanceEquation(equation) }
        }
        return result
    }
}
