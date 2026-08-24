import Foundation

enum ScreenHistoryCoastFreezeScanKind: String, Codable, Equatable, Sendable {
    case primary
    case secondCheck = "second_check"
}

enum ScreenHistoryCoastFileFamily: String, Codable, CaseIterable, Equatable, Sendable {
    case frames
    case videos
    case icons
    case support
}

enum ScreenHistoryCoastRuntimeExclusion: String, Codable, CaseIterable, Equatable, Sendable {
    case commandSocket = "command_socket"
    case sqliteSharedMemory = "sqlite_shared_memory"
}

struct ScreenHistoryCoastFrozenFile: Codable, Equatable, Sendable {
    /// A path below the Coast root. Absolute paths are never persisted.
    let relativePath: String
    let family: ScreenHistoryCoastFileFamily
    let byteCount: Int64
    let modifiedAt: Date
    let sha256: String
}

struct ScreenHistoryCoastFamilySummary: Codable, Equatable, Sendable {
    let family: ScreenHistoryCoastFileFamily
    let fileCount: Int
    let byteCount: Int64
}

struct ScreenHistoryCoastDatabaseSchema: Codable, Equatable, Sendable {
    let userVersion: Int64
    let applicationID: Int64
    let schemaSHA256: String
    let tableCount: Int
    let indexCount: Int
    let triggerCount: Int
    let viewCount: Int
}

struct ScreenHistoryCoastDatabaseCounts: Codable, Equatable, Sendable {
    let frames: Int64
    let videos: Int64
    let segments: Int64
    let ocrBoxes: Int64
    let accessibilitySnapshots: Int64
    let applications: Int64
    let domains: Int64
}

struct ScreenHistoryCoastDatabaseRecord: Codable, Equatable, Sendable {
    let relativePath: String
    let byteCount: Int64
    let modifiedAt: Date
    let sha256: String
    let schema: ScreenHistoryCoastDatabaseSchema
    let counts: ScreenHistoryCoastDatabaseCounts
    let earliestFrameAt: Date?
    let latestFrameAt: Date?
}

struct ScreenHistoryCoastFreezeManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let createdAt: Date
    let database: ScreenHistoryCoastDatabaseRecord
    let files: [ScreenHistoryCoastFrozenFile]
    let families: [ScreenHistoryCoastFamilySummary]
    let runtimeExclusions: [ScreenHistoryCoastRuntimeExclusion]
    /// SHA-256 of the canonical content fields. Scan time is excluded so an
    /// independent second pass can compare the same Coast state.
    let manifestSHA256: String
}

enum ScreenHistoryCoastRetirementApprovalState: String, Codable, Equatable, Sendable {
    case awaitingRollbackHold = "awaiting_rollback_hold"
    case awaitingSecondCheck = "awaiting_second_check"
    case notApproved = "not_approved"
    case approvedForRetirement = "approved_for_retirement"
    case revoked
}

struct ScreenHistoryCoastFreezeReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let primary: ScreenHistoryCoastFreezeManifest
    let secondCheckedAt: Date?
    let secondCheckManifestSHA256: String?
    let secondCheckMatched: Bool
    let rollbackHoldStartedAt: Date?
    let rollbackHoldUntil: Date?
    let approvalRecordedAt: Date?
    let approvalState: ScreenHistoryCoastRetirementApprovalState
    /// HMAC-SHA-256 over every other receipt field, using an app-scoped key.
    /// Loading a modified receipt fails before approval state is returned.
    let receiptHMACSHA256: String
}

struct ScreenHistoryCoastFreezeProgress: Equatable, Sendable {
    let kind: ScreenHistoryCoastFreezeScanKind
    let processedFiles: Int
    let totalFiles: Int
    let isComplete: Bool
    let receipt: ScreenHistoryCoastFreezeReceipt?
}

protocol ScreenHistoryCoastFreezeReceipting: Sendable {
    /// Builds or resumes the owner-only primary manifest. The source is read
    /// only. `maximumNewFiles` is a deterministic test and scheduling bound.
    func makePrimaryReceipt(maximumNewFiles: Int?) async throws -> ScreenHistoryCoastFreezeProgress

    /// Records the start and end of the recoverable rollback period after the
    /// Coast app is retired. It does not change the Coast root.
    func beginRollbackHold(
        expectedReceiptHMACSHA256: String
    ) async throws -> ScreenHistoryCoastFreezeReceipt

    /// Re-hashes the source independently and compares it with the primary
    /// manifest. It never reuses primary file digests.
    func performSecondCheck(maximumNewFiles: Int?) async throws -> ScreenHistoryCoastFreezeProgress

    /// Records explicit owner approval against the exact current receipt.
    /// Approval is unavailable until the hold ends and a later independent
    /// second check matches. This service has no Coast deletion capability.
    func recordRetirementApproval(
        expectedReceiptHMACSHA256: String,
        approved: Bool
    ) async throws -> ScreenHistoryCoastFreezeReceipt

    func currentReceipt() async throws -> ScreenHistoryCoastFreezeReceipt?
}
