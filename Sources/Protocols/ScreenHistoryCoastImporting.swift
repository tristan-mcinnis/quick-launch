import Foundation

/// Explicit phases shown while Coast history is copied into Quick Launch's
/// owned local store. Capture stays independent from this migration.
enum ScreenHistoryCoastImportState: Equatable, Sendable {
    case idle
    case checkingSource
    case ready
    case unavailable
    case previewingMetadata
    case previewReady(ScreenHistoryCoastImportPreview)
    case previewInvalidated
    case importingMetadata
    case copyingVerifiedMedia
    case preparingVerificationSample
    case completed(ScreenHistoryCoastImportSummary)
    case failed(ScreenHistoryCoastImportFailurePhase)
}

enum ScreenHistoryCoastImportFailurePhase: String, Equatable, Sendable {
    case preview
    case metadata
    case media
    case verificationSample
}

/// A read-only count of the Coast rows that the current exclusion policy would
/// import. The opaque authorization is issued by the production importer and
/// is consumed by one explicit import attempt.
struct ScreenHistoryCoastImportPreview: Equatable, Sendable {
    let authorizationID: UUID
    let sourceRows: Int
    let importedRows: Int
    let excludedRows: Int
    let invalidRows: Int
    let reconciliation: ScreenHistoryMigrationReconciliation
    let policyFingerprint: String
    let sourceFingerprint: String

    var reconciles: Bool { reconciliation.reconciles }

    init(
        authorizationID: UUID,
        sourceRows: Int,
        importedRows: Int,
        excludedRows: Int,
        invalidRows: Int,
        reconciliation: ScreenHistoryMigrationReconciliation? = nil,
        policyFingerprint: String,
        sourceFingerprint: String
    ) {
        self.authorizationID = authorizationID
        self.sourceRows = sourceRows
        self.importedRows = importedRows
        self.excludedRows = excludedRows
        self.invalidRows = invalidRows
        self.reconciliation = reconciliation ?? .frameOnly(
            source: sourceRows,
            imported: importedRows,
            excluded: excludedRows,
            invalid: invalidRows
        )
        self.policyFingerprint = policyFingerprint
        self.sourceFingerprint = sourceFingerprint
    }
}

enum ScreenHistoryCoastImportError: Error, Equatable, Sendable {
    case stalePreview
    case sourceChanged
}

struct ScreenHistoryCoastImportSummary: Equatable, Sendable {
    static let verificationSampleTarget = 100

    let sourceRows: Int
    let importedRows: Int
    let excludedRows: Int
    let invalidRows: Int
    let newOwnedRows: Int
    let copiedFiles: Int
    let mediaFailures: Int
    /// Number of metadata-only moments prepared for later human review.
    let verificationSampleCount: Int
    let verificationSampleTarget: Int

    init(
        sourceRows: Int,
        importedRows: Int,
        excludedRows: Int,
        invalidRows: Int,
        newOwnedRows: Int,
        copiedFiles: Int,
        mediaFailures: Int,
        verificationSampleCount: Int,
        verificationSampleTarget: Int = Self.verificationSampleTarget
    ) {
        self.sourceRows = sourceRows
        self.importedRows = importedRows
        self.excludedRows = excludedRows
        self.invalidRows = invalidRows
        self.newOwnedRows = newOwnedRows
        self.copiedFiles = copiedFiles
        self.mediaFailures = mediaFailures
        self.verificationSampleCount = verificationSampleCount
        self.verificationSampleTarget = verificationSampleTarget
    }
}

/// Split into explicit stages so Settings can show meaningful progress and a
/// stopped run can safely resume at the first incomplete stage.
protocol ScreenHistoryCoastImporting: Sendable {
    func sourceIsAvailable() async -> Bool
    func previewMetadata(policy: ScreenHistoryMigrationPolicy) async throws -> ScreenHistoryCoastImportPreview
    func invalidatePreview() async
    func importMetadata(
        preview: ScreenHistoryCoastImportPreview,
        policy: ScreenHistoryMigrationPolicy
    ) async throws -> ScreenHistoryMigrationResult
    func copyVerifiedMedia() async throws -> ScreenHistoryMediaMigrationResult
    func verificationSampleCount(limit: Int) async throws -> Int
}

struct ScreenHistoryMenuBarPresentation: Equatable, Sendable {
    let symbolName: String
    let accessibilityName: String
    let forcesVisibility: Bool

    static func make(status: ScreenHistoryCaptureStatus?) -> Self {
        switch status?.state {
        case .running:
            Self(
                symbolName: "record.circle.fill",
                accessibilityName: "Quick Launch, Screen History running",
                forcesVisibility: true
            )
        case .pausedForInactivity:
            Self(
                symbolName: "pause.circle.fill",
                accessibilityName: "Quick Launch, Screen History paused",
                forcesVisibility: true
            )
        case .stopped, .disabled, nil:
            Self(
                symbolName: "bolt.fill",
                accessibilityName: "Quick Launch",
                forcesVisibility: false
            )
        }
    }
}
