import CryptoKit
import Foundation

/// Persists the human review gate for Coast retirement. This actor reads only
/// imported metadata supplied by `ScreenHistoryRetirementSampling`; it never
/// reads media bytes and has no deletion capability.
actor ScreenHistoryRetirementReviewService: ScreenHistoryRetirementReviewing {
    nonisolated static let ledgerVersion = 1

    private struct LedgerEntry: Codable, Equatable {
        let sampleID: String
        let contentHash: String
        var decision: ScreenHistoryRetirementReviewDecision
        var reviewedAt: Date?
    }

    private struct Ledger: Codable, Equatable {
        let version: Int
        let totalImportedMoments: Int
        let eligibleImportedMoments: Int
        let mediaIntegrityFailureMoments: Int
        let normalizedStructureDrift: Int
        let sampleFingerprint: String
        let preparedAt: Date
        var entries: [LedgerEntry]
    }

    private let sampler: any ScreenHistoryRetirementSampling
    private let ledgerURL: URL
    private let clock: @Sendable () -> Date

    static func defaultLedgerURL() -> URL {
        SQLiteScreenHistoryStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("screen-history-retirement-review.json")
    }

    init(
        sampler: any ScreenHistoryRetirementSampling,
        ledgerURL: URL = ScreenHistoryRetirementReviewService.defaultLedgerURL(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sampler = sampler
        self.ledgerURL = ledgerURL
        self.clock = clock
    }

    func refresh() async throws -> ScreenHistoryRetirementReviewSnapshot {
        let population = try await sampler.coastRetirementSample(
            limit: ScreenHistoryRetirementReadiness.requiredSampleSize
        )
        let identity = try Self.sampleIdentity(for: population)
        let current = try readLedgerIfPresent()
        let ledger: Ledger

        if let current, Self.matches(current, population: population, identity: identity) {
            ledger = current
        } else {
            ledger = Ledger(
                version: Self.ledgerVersion,
                totalImportedMoments: population.totalImportedMoments,
                eligibleImportedMoments: population.eligibleImportedMoments,
                mediaIntegrityFailureMoments: population.mediaIntegrityFailureMoments,
                normalizedStructureDrift: population.normalizedStructureDrift,
                sampleFingerprint: identity,
                preparedAt: clock(),
                entries: population.moments.map {
                    LedgerEntry(
                        sampleID: Self.sampleID(for: $0),
                        contentHash: $0.contentHash,
                        decision: .pending,
                        reviewedAt: nil
                    )
                }
            )
            try write(ledger)
        }
        return try Self.snapshot(population: population, ledger: ledger)
    }

    func decide(
        sampleID: String,
        contentHash: String,
        decision: ScreenHistoryRetirementReviewDecision
    ) async throws -> ScreenHistoryRetirementReviewSnapshot {
        let population = try await sampler.coastRetirementSample(
            limit: ScreenHistoryRetirementReadiness.requiredSampleSize
        )
        let identity = try Self.sampleIdentity(for: population)
        guard var ledger = try readLedgerIfPresent(),
              Self.matches(ledger, population: population, identity: identity)
        else {
            // Persist the new pending sample before rejecting stale UI state.
            _ = try await refresh()
            throw ScreenHistoryRetirementReviewError.staleSample
        }
        guard let index = ledger.entries.firstIndex(where: { $0.sampleID == sampleID }) else {
            throw ScreenHistoryRetirementReviewError.unknownSampleID
        }
        guard ledger.entries[index].contentHash == contentHash else {
            throw ScreenHistoryRetirementReviewError.staleSample
        }
        ledger.entries[index].decision = decision
        ledger.entries[index].reviewedAt = decision == .pending ? nil : clock()
        try write(ledger)
        return try Self.snapshot(population: population, ledger: ledger)
    }

    private func readLedgerIfPresent() throws -> Ledger? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: ledgerURL.path) else { return nil }
        guard try !Self.isSymbolicLink(ledgerURL) else {
            throw ScreenHistoryRetirementReviewError.invalidLedger
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let ledger = try decoder.decode(Ledger.self, from: Data(contentsOf: ledgerURL))
            guard Self.isStructurallyValid(ledger) else {
                throw ScreenHistoryRetirementReviewError.invalidLedger
            }
            return ledger
        } catch let error as ScreenHistoryRetirementReviewError {
            throw error
        } catch {
            throw ScreenHistoryRetirementReviewError.invalidLedger
        }
    }

    private func write(_ ledger: Ledger) throws {
        let fileManager = FileManager.default
        let directory = ledgerURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) {
            guard try !Self.isSymbolicLink(directory) else {
                throw ScreenHistoryRetirementReviewError.invalidLedger
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: ledgerURL.path), try Self.isSymbolicLink(ledgerURL) {
            throw ScreenHistoryRetirementReviewError.invalidLedger
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(ledger)
        data.append(0x0A)
        try data.write(to: ledgerURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledgerURL.path)
    }

    private static func snapshot(
        population: ScreenHistoryRetirementSamplePopulation,
        ledger: Ledger
    ) throws -> ScreenHistoryRetirementReviewSnapshot {
        let decisions = Dictionary(uniqueKeysWithValues: ledger.entries.map { ($0.sampleID, $0) })
        let moments = try population.moments.map { frame -> ScreenHistoryRetirementReviewMoment in
            let sampleID = sampleID(for: frame)
            guard let entry = decisions[sampleID], entry.contentHash == frame.contentHash else {
                throw ScreenHistoryRetirementReviewError.invalidLedger
            }
            return ScreenHistoryRetirementReviewMoment(
                sampleID: sampleID,
                contentHash: frame.contentHash,
                frame: frame,
                decision: entry.decision,
                reviewedAt: entry.reviewedAt
            )
        }
        let accepted = moments.count { $0.decision == .accepted }
        let flagged = moments.count { $0.decision == .flagged }
        let pending = moments.count { $0.decision == .pending }
        let required = min(
            population.totalImportedMoments,
            ScreenHistoryRetirementReadiness.requiredSampleSize
        )
        let completePopulation = population.totalImportedMoments > 0
            && population.eligibleImportedMoments == population.totalImportedMoments
            && population.mediaIntegrityFailureMoments == 0
            && population.normalizedStructureDrift == 0
        let ready = completePopulation
            && moments.count == required
            && accepted == required
            && flagged == 0
            && pending == 0
        return ScreenHistoryRetirementReviewSnapshot(
            moments: moments,
            readiness: ScreenHistoryRetirementReadiness(
                isReady: ready,
                totalImportedMoments: population.totalImportedMoments,
                eligibleImportedMoments: population.eligibleImportedMoments,
                mediaIntegrityFailureMoments: population.mediaIntegrityFailureMoments,
                normalizedStructureDrift: population.normalizedStructureDrift,
                requiredAcceptedMoments: required,
                acceptedMoments: accepted,
                flaggedMoments: flagged,
                pendingMoments: pending
            ),
            sampleFingerprint: ledger.sampleFingerprint
        )
    }

    private static func matches(
        _ ledger: Ledger,
        population: ScreenHistoryRetirementSamplePopulation,
        identity: String
    ) -> Bool {
        guard ledger.version == ledgerVersion,
              ledger.totalImportedMoments == population.totalImportedMoments,
              ledger.eligibleImportedMoments == population.eligibleImportedMoments,
              ledger.mediaIntegrityFailureMoments == population.mediaIntegrityFailureMoments,
              ledger.normalizedStructureDrift == population.normalizedStructureDrift,
              ledger.sampleFingerprint == identity,
              ledger.entries.count == population.moments.count
        else { return false }
        return zip(ledger.entries, population.moments).allSatisfy { entry, frame in
            entry.sampleID == sampleID(for: frame) && entry.contentHash == frame.contentHash
        }
    }

    private static func isStructurallyValid(_ ledger: Ledger) -> Bool {
        guard ledger.version == ledgerVersion,
              ledger.totalImportedMoments >= 0,
              ledger.eligibleImportedMoments >= 0,
              ledger.eligibleImportedMoments <= ledger.totalImportedMoments,
              ledger.mediaIntegrityFailureMoments >= 0,
              ledger.mediaIntegrityFailureMoments <= ledger.totalImportedMoments,
              ledger.normalizedStructureDrift >= 0,
              ledger.sampleFingerprint.count == 64,
              ledger.entries.count <= ScreenHistoryRetirementReadiness.requiredSampleSize,
              Set(ledger.entries.map(\.sampleID)).count == ledger.entries.count
        else { return false }
        return ledger.entries.allSatisfy {
            !$0.sampleID.isEmpty
                && $0.contentHash.count == 64
                && (($0.decision == .pending) == ($0.reviewedAt == nil))
        }
    }

    private static func sampleIdentity(
        for population: ScreenHistoryRetirementSamplePopulation
    ) throws -> String {
        guard population.totalImportedMoments >= 0,
              population.eligibleImportedMoments >= 0,
              population.eligibleImportedMoments <= population.totalImportedMoments,
              population.mediaIntegrityFailureMoments >= 0,
              population.mediaIntegrityFailureMoments <= population.totalImportedMoments,
              population.normalizedStructureDrift >= 0,
              population.moments.count <= ScreenHistoryRetirementReadiness.requiredSampleSize,
              Set(population.moments.map { sampleID(for: $0) }).count == population.moments.count,
              population.moments.allSatisfy({ $0.source == .coast && $0.contentHash.count == 64 })
        else { throw ScreenHistoryRetirementReviewError.invalidLedger }

        var hasher = SHA256()
        append(String(ledgerVersion), to: &hasher)
        append(String(population.totalImportedMoments), to: &hasher)
        append(String(population.eligibleImportedMoments), to: &hasher)
        append(String(population.mediaIntegrityFailureMoments), to: &hasher)
        append(String(population.normalizedStructureDrift), to: &hasher)
        for frame in population.moments {
            append(sampleID(for: frame), to: &hasher)
            append(frame.contentHash, to: &hasher)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: String, to hasher: inout SHA256) {
        let data = Data(value.utf8)
        var count = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &count) { hasher.update(data: Data($0)) }
        hasher.update(data: data)
    }

    private static func sampleID(for frame: ScreenHistoryFrame) -> String {
        "coast:\(frame.sourceIdentifier)"
    }

    private static func isSymbolicLink(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }
}
