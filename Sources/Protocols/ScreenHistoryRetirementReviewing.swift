import Foundation

/// A content-free gate summary plus the bounded metadata review sample.
/// Eligibility requires metadata equality, normalized structure, and present
/// owned media whose bytes match the migration ledger hash.
struct ScreenHistoryRetirementSamplePopulation: Equatable, Sendable {
    let totalImportedMoments: Int
    let eligibleImportedMoments: Int
    let mediaIntegrityFailureMoments: Int
    let normalizedStructureDrift: Int
    let moments: [ScreenHistoryFrame]

    init(
        totalImportedMoments: Int,
        eligibleImportedMoments: Int,
        mediaIntegrityFailureMoments: Int = 0,
        normalizedStructureDrift: Int = 0,
        moments: [ScreenHistoryFrame]
    ) {
        self.totalImportedMoments = totalImportedMoments
        self.eligibleImportedMoments = eligibleImportedMoments
        self.mediaIntegrityFailureMoments = mediaIntegrityFailureMoments
        self.normalizedStructureDrift = normalizedStructureDrift
        self.moments = moments
    }
}

protocol ScreenHistoryRetirementSampling: Sendable {
    func coastRetirementSample(limit: Int) async throws -> ScreenHistoryRetirementSamplePopulation
}

enum ScreenHistoryRetirementReviewDecision: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case flagged
}

struct ScreenHistoryRetirementReviewMoment: Equatable, Sendable, Identifiable {
    let sampleID: String
    let contentHash: String
    let frame: ScreenHistoryFrame
    let decision: ScreenHistoryRetirementReviewDecision
    let reviewedAt: Date?

    var id: String { sampleID }
}

struct ScreenHistoryRetirementReadiness: Equatable, Sendable {
    static let requiredSampleSize = 100

    let isReady: Bool
    let totalImportedMoments: Int
    let eligibleImportedMoments: Int
    let mediaIntegrityFailureMoments: Int
    let normalizedStructureDrift: Int
    let requiredAcceptedMoments: Int
    let acceptedMoments: Int
    let flaggedMoments: Int
    let pendingMoments: Int

    var hasCompleteImportedPopulation: Bool {
        totalImportedMoments > 0
            && eligibleImportedMoments == totalImportedMoments
            && mediaIntegrityFailureMoments == 0
            && normalizedStructureDrift == 0
    }
}

struct ScreenHistoryRetirementReviewSnapshot: Equatable, Sendable {
    let moments: [ScreenHistoryRetirementReviewMoment]
    let readiness: ScreenHistoryRetirementReadiness
    let sampleFingerprint: String
}

enum ScreenHistoryRetirementReviewError: Error, Equatable, Sendable {
    case invalidLedger
    case staleSample
    case unknownSampleID
}

protocol ScreenHistoryRetirementReviewing: Sendable {
    /// Reconciles the persistent review ledger with the current imported Coast
    /// population. Any sample, population, or content-hash drift resets all
    /// decisions to pending.
    func refresh() async throws -> ScreenHistoryRetirementReviewSnapshot

    /// Records a human review decision for the exact current sample identity.
    /// The service supplies the timestamp and rejects stale UI state.
    func decide(
        sampleID: String,
        contentHash: String,
        decision: ScreenHistoryRetirementReviewDecision
    ) async throws -> ScreenHistoryRetirementReviewSnapshot
}
