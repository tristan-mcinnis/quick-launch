import Foundation
import CryptoKit

enum ScreenHistoryMigrationStatus: String, Sendable {
    case imported
    case excluded
    case invalid
}

enum ScreenHistoryMigrationFamily: String, CaseIterable, Hashable, Sendable {
    case frame
    case ocr
    case application
    case domain
    case sequence
    case media
}

struct ScreenHistoryMigrationFamilyEquation: Equatable, Sendable {
    let source: Int
    let imported: Int
    let excluded: Int
    let invalid: Int

    var reconciles: Bool { source == imported + excluded + invalid }
}

/// Content-free migration proof. Optional equations mean the legacy schema
/// did not expose that family, so no unsupported zero is presented as proof.
struct ScreenHistoryMigrationReconciliation: Equatable, Sendable {
    let frame: ScreenHistoryMigrationFamilyEquation
    let ocr: ScreenHistoryMigrationFamilyEquation?
    let application: ScreenHistoryMigrationFamilyEquation?
    let domain: ScreenHistoryMigrationFamilyEquation?
    let sequence: ScreenHistoryMigrationFamilyEquation?
    let media: ScreenHistoryMigrationFamilyEquation?

    var reconciles: Bool {
        [frame, ocr, application, domain, sequence, media]
            .compactMap { $0 }
            .allSatisfy(\.reconciles)
    }

    static func frameOnly(
        source: Int,
        imported: Int,
        excluded: Int,
        invalid: Int
    ) -> Self {
        Self(
            frame: ScreenHistoryMigrationFamilyEquation(
                source: source,
                imported: imported,
                excluded: excluded,
                invalid: invalid
            ),
            ocr: nil,
            application: nil,
            domain: nil,
            sequence: nil,
            media: nil
        )
    }
}

struct ScreenHistoryMigrationFamilyMembership: Equatable, Sendable {
    let sourceIdentifier: String
    let ocrIdentifier: String?
    let applicationIdentifier: String?
    let domainIdentifier: String?
    let sequenceIdentifier: String?
    let mediaIdentifiers: Set<String>
}

struct ScreenHistoryMigrationSourceBatch: Equatable, Sendable {
    let rows: [ScreenHistoryFrameInput]
    let supportedFamilies: Set<ScreenHistoryMigrationFamily>
    let memberships: [ScreenHistoryMigrationFamilyMembership]
}

struct ScreenHistoryMigrationPolicy: Equatable, Sendable {
    var excludedBundleIdentifiers: Set<String>
    var excludedApplications: Set<String>
    var excludedDomains: Set<String>
    var financeBundleIdentifiers: Set<String>
    var financeApplications: Set<String>
    var financeDomains: Set<String>

    static let safeDefault = ScreenHistoryMigrationPolicy()

    init(
        excludedBundleIdentifiers: Set<String> = [],
        excludedApplications: Set<String> = [],
        excludedDomains: Set<String> = [],
        financeBundleIdentifiers: Set<String> = [],
        financeApplications: Set<String> = [],
        financeDomains: Set<String> = []
    ) {
        self.excludedBundleIdentifiers = Self.normalized(excludedBundleIdentifiers)
            .union(ScreenHistoryCaptureConfiguration.safeDefaultExcludedBundleIdentifiers)
            .union(ScreenHistoryCaptureConfiguration.safeDefaultCaptureOnlyExcludedBundleIdentifiers)
            .union([ScreenHistoryCaptureConfiguration.ownBundleIdentifier])
        self.excludedApplications = Self.normalized(excludedApplications)
        self.excludedDomains = Self.normalized(excludedDomains)
            .union(ScreenHistoryCaptureConfiguration.safeDefaultExcludedDomains)
        self.financeBundleIdentifiers = Self.normalized(financeBundleIdentifiers)
        self.financeApplications = Self.normalized(financeApplications)
        self.financeDomains = Self.normalized(financeDomains)
    }

    fileprivate func status(for frame: ScreenHistoryFrameInput, now: Date) -> ScreenHistoryMigrationStatus {
        let timestamp = frame.capturedAt.timeIntervalSince1970
        let legacyFrameID = Int64(frame.sourceIdentifier)
        guard timestamp.isFinite, timestamp >= 0, frame.capturedAt <= now,
              let legacyFrameID, legacyFrameID > 0
        else { return .invalid }

        let bundle = Self.clean(frame.bundleIdentifier)
        let application = Self.clean(frame.application)
        let domain = Self.clean(frame.domain)
        let title = Self.clean(frame.windowTitle) ?? ""

        if let bundle, excludedBundleIdentifiers.contains(bundle) { return .excluded }
        if let application, excludedApplications.contains(application) { return .excluded }
        if let domain, Self.matchesDomain(domain, exclusions: excludedDomains) { return .excluded }

        if bundle == nil || bundle == "unknown" || bundle == "unknown.bundle"
            || bundle?.hasPrefix("unknown.") == true {
            return .excluded
        }

        let passwordSignals = ["1password", "lastpass", "bitwarden", "dashlane", "password", "keychain access"]
        if passwordSignals.contains(where: { bundle?.contains($0) == true || application?.contains($0) == true }) {
            return .excluded
        }

        let privateWindowSignals = ["private browsing", "incognito", "inprivate"]
        if privateWindowSignals.contains(where: title.contains) { return .excluded }

        if let bundle, financeBundleIdentifiers.contains(bundle) { return .excluded }
        if let application, financeApplications.contains(application) { return .excluded }
        if let domain, Self.matchesDomain(domain, exclusions: financeDomains) { return .excluded }
        guard ScreenHistoryPrivacyPolicy.allowsStoredContent(
            bundleIdentifier: bundle,
            windowTitle: title,
            domain: domain,
            excludedBundleIdentifiers: excludedBundleIdentifiers.union(financeBundleIdentifiers),
            excludedDomains: excludedDomains.union(financeDomains)
        ) else { return .excluded }
        return .imported
    }

    /// Stable identity for the complete effective policy, including hard
    /// defaults added by the initializer. A preview is valid only for this
    /// exact value.
    var fingerprint: String {
        let groups = [
            excludedBundleIdentifiers,
            excludedApplications,
            excludedDomains,
            financeBundleIdentifiers,
            financeApplications,
            financeDomains,
        ]
        var canonical = Data()
        for group in groups {
            var count = UInt64(group.count).bigEndian
            withUnsafeBytes(of: &count) { canonical.append(contentsOf: $0) }
            for value in group.sorted() {
                Self.appendLengthPrefixed(value, to: &canonical)
            }
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalized(_ values: Set<String>) -> Set<String> {
        Set(values.compactMap(clean))
    }

    private static func clean(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty
        else { return nil }
        return normalized
    }

    private static func matchesDomain(_ domain: String, exclusions: Set<String>) -> Bool {
        exclusions.contains { domain == $0 || domain.hasSuffix(".\($0)") }
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }
}

struct ScreenHistoryMigrationPreviewResult: Equatable, Sendable {
    let source: Int
    let imported: Int
    let excluded: Int
    let invalid: Int
    let reconciliation: ScreenHistoryMigrationReconciliation
    let policyFingerprint: String
    let sourceFingerprint: String
    let lastLegacyFrameID: Int64?
    let evaluatedAt: Date

    var reconciles: Bool { reconciliation.reconciles }
}

struct ScreenHistoryMigrationResult: Equatable, Sendable {
    let source: Int
    let imported: Int
    let excluded: Int
    let invalid: Int
    let reconciliation: ScreenHistoryMigrationReconciliation
    let ownedRowDelta: Int
    let hashDelta: Int
    let mappingCount: Int
    let ledgerCount: Int
    let lastLegacyFrameID: Int64?

    var reconciles: Bool { reconciliation.reconciles }

    init(
        source: Int,
        imported: Int,
        excluded: Int,
        invalid: Int,
        reconciliation: ScreenHistoryMigrationReconciliation? = nil,
        ownedRowDelta: Int,
        hashDelta: Int,
        mappingCount: Int,
        ledgerCount: Int,
        lastLegacyFrameID: Int64?
    ) {
        self.source = source
        self.imported = imported
        self.excluded = excluded
        self.invalid = invalid
        self.reconciliation = reconciliation ?? .frameOnly(
            source: source,
            imported: imported,
            excluded: excluded,
            invalid: invalid
        )
        self.ownedRowDelta = ownedRowDelta
        self.hashDelta = hashDelta
        self.mappingCount = mappingCount
        self.ledgerCount = ledgerCount
        self.lastLegacyFrameID = lastLegacyFrameID
    }
}

struct ScreenHistoryMigrationStoreChange: Equatable, Sendable {
    let ownedRowDelta: Int
    let hashDelta: Int
}

actor ScreenHistoryMigrationService {
    private let reader: any CoastLegacyReading
    private let store: SQLiteScreenHistoryStore
    private let policy: ScreenHistoryMigrationPolicy
    private let clock: @Sendable () -> Date

    private struct ReconciliationAccumulator {
        private(set) var supportedFamilies: Set<ScreenHistoryMigrationFamily>?
        private var frameCounts: [ScreenHistoryMigrationStatus: Int] = [:]
        private var identities: [ScreenHistoryMigrationFamily: [String: ScreenHistoryMigrationStatus]] = [:]

        mutating func add(
            batch: ScreenHistoryMigrationSourceBatch,
            statuses: [String: ScreenHistoryMigrationStatus]
        ) throws {
            if let supportedFamilies, supportedFamilies != batch.supportedFamilies {
                throw LocalSQLiteError.step("legacy migration family support changed during scan")
            }
            supportedFamilies = batch.supportedFamilies
            let memberships = Dictionary(
                batch.memberships.map { ($0.sourceIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            guard memberships.count == batch.memberships.count else {
                throw LocalSQLiteError.step("duplicate legacy migration family membership")
            }
            for row in batch.rows {
                guard let status = statuses[row.sourceIdentifier],
                      let membership = memberships[row.sourceIdentifier]
                else {
                    throw LocalSQLiteError.step("missing legacy migration family membership")
                }
                frameCounts[status, default: 0] += 1
                add(membership.ocrIdentifier, family: .ocr, status: status)
                add(membership.applicationIdentifier, family: .application, status: status)
                add(membership.domainIdentifier, family: .domain, status: status)
                add(membership.sequenceIdentifier, family: .sequence, status: status)
                for identity in membership.mediaIdentifiers {
                    add(identity, family: .media, status: status)
                }
            }
        }

        func result() -> ScreenHistoryMigrationReconciliation {
            let supported = supportedFamilies ?? [.frame]
            return ScreenHistoryMigrationReconciliation(
                frame: equation(counts: frameCounts),
                ocr: supported.contains(.ocr) ? equation(family: .ocr) : nil,
                application: supported.contains(.application) ? equation(family: .application) : nil,
                domain: supported.contains(.domain) ? equation(family: .domain) : nil,
                sequence: supported.contains(.sequence) ? equation(family: .sequence) : nil,
                media: supported.contains(.media) ? equation(family: .media) : nil
            )
        }

        private mutating func add(
            _ identity: String?,
            family: ScreenHistoryMigrationFamily,
            status: ScreenHistoryMigrationStatus
        ) {
            guard let identity, !identity.isEmpty else { return }
            let existing = identities[family]?[identity]
            if existing.map({ Self.rank(status) > Self.rank($0) }) ?? true {
                identities[family, default: [:]][identity] = status
            }
        }

        private func equation(family: ScreenHistoryMigrationFamily) -> ScreenHistoryMigrationFamilyEquation {
            let values = identities[family].map { Array($0.values) } ?? []
            let counts = Dictionary(grouping: values, by: { $0 })
                .mapValues(\.count)
            return equation(counts: counts)
        }

        private func equation(
            counts: [ScreenHistoryMigrationStatus: Int]
        ) -> ScreenHistoryMigrationFamilyEquation {
            let imported = counts[.imported, default: 0]
            let excluded = counts[.excluded, default: 0]
            let invalid = counts[.invalid, default: 0]
            return ScreenHistoryMigrationFamilyEquation(
                source: imported + excluded + invalid,
                imported: imported,
                excluded: excluded,
                invalid: invalid
            )
        }

        private static func rank(_ status: ScreenHistoryMigrationStatus) -> Int {
            switch status {
            case .imported: 3
            case .excluded: 2
            case .invalid: 1
            }
        }
    }

    init(
        reader: any CoastLegacyReading,
        store: SQLiteScreenHistoryStore,
        policy: ScreenHistoryMigrationPolicy = .safeDefault,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.store = store
        self.policy = policy
        self.clock = clock
    }

    /// Imports metadata only. Media files remain in the read-only legacy root
    /// until the separate media proof and retirement gate passes.
    func migrate(
        afterLegacyFrameID: Int64? = nil,
        maximumSourceRows: Int? = nil,
        batchSize: Int = CoastLegacyReader.maximumImportRows
    ) async throws -> ScreenHistoryMigrationResult {
        let boundedBatchSize = min(max(1, batchSize), CoastLegacyReader.maximumImportRows)
        let boundedMaximum = maximumSourceRows.map { max(0, $0) }
        var cursor = afterLegacyFrameID
        var source = 0
        var imported = 0
        var excluded = 0
        var invalid = 0
        var ownedRowDelta = 0
        var hashDelta = 0
        var reconciliation = ReconciliationAccumulator()

        while boundedMaximum.map({ source < $0 }) ?? true {
            let remaining = boundedMaximum.map { $0 - source } ?? boundedBatchSize
            let requestCount = min(boundedBatchSize, remaining)
            if requestCount <= 0 { break }
            let batch = try await reader.migrationSourceBatch(
                afterFrameID: cursor,
                limit: requestCount
            )
            let rows = batch.rows
            if rows.isEmpty {
                try reconciliation.add(batch: batch, statuses: [:])
                break
            }

            var statuses: [String: ScreenHistoryMigrationStatus] = [:]
            for frame in rows {
                source += 1
                let status = policy.status(for: frame, now: clock())
                switch status {
                case .imported: imported += 1
                case .excluded: excluded += 1
                case .invalid: invalid += 1
                }
                statuses[frame.sourceIdentifier] = status
                let change = try await store.applyMigration(frame, status: status, migratedAt: clock())
                ownedRowDelta += change.ownedRowDelta
                hashDelta += change.hashDelta
                if let id = Int64(frame.sourceIdentifier) { cursor = id }
            }
            try reconciliation.add(batch: batch, statuses: statuses)
            if rows.count < requestCount { break }
        }

        let mappingCount = try await store.migrationLedgerCount(source: .coast, status: .imported)
        let ledgerCount = try await store.migrationLedgerCount(source: .coast, status: nil)
        return ScreenHistoryMigrationResult(
            source: source,
            imported: imported,
            excluded: excluded,
            invalid: invalid,
            reconciliation: reconciliation.result(),
            ownedRowDelta: ownedRowDelta,
            hashDelta: hashDelta,
            mappingCount: mappingCount,
            ledgerCount: ledgerCount,
            lastLegacyFrameID: cursor
        )
    }

    /// Reads and classifies Coast metadata without touching the owned store or
    /// any media locator. The source fingerprint binds the visible counts to
    /// the exact metadata snapshot that was reviewed.
    func preview(
        afterLegacyFrameID: Int64? = nil,
        maximumSourceRows: Int? = nil,
        batchSize: Int = CoastLegacyReader.maximumImportRows
    ) async throws -> ScreenHistoryMigrationPreviewResult {
        let boundedBatchSize = min(max(1, batchSize), CoastLegacyReader.maximumImportRows)
        let boundedMaximum = maximumSourceRows.map { max(0, $0) }
        var cursor = afterLegacyFrameID
        var source = 0
        var imported = 0
        var excluded = 0
        var invalid = 0
        var sourceHasher = SHA256()
        var reconciliation = ReconciliationAccumulator()
        let evaluatedAt = clock()

        while boundedMaximum.map({ source < $0 }) ?? true {
            let remaining = boundedMaximum.map { $0 - source } ?? boundedBatchSize
            let requestCount = min(boundedBatchSize, remaining)
            if requestCount <= 0 { break }
            let batch = try await reader.migrationSourceBatch(
                afterFrameID: cursor,
                limit: requestCount
            )
            let rows = batch.rows
            if rows.isEmpty {
                try reconciliation.add(batch: batch, statuses: [:])
                break
            }

            var statuses: [String: ScreenHistoryMigrationStatus] = [:]
            for frame in rows {
                source += 1
                let status = policy.status(for: frame, now: evaluatedAt)
                switch status {
                case .imported: imported += 1
                case .excluded: excluded += 1
                case .invalid: invalid += 1
                }
                statuses[frame.sourceIdentifier] = status
                var rowIdentity = Data()
                Self.appendLengthPrefixed(frame.sourceIdentifier, to: &rowIdentity)
                Self.appendLengthPrefixed(frame.contentHash, to: &rowIdentity)
                Self.appendLengthPrefixed(status.rawValue, to: &rowIdentity)
                sourceHasher.update(data: rowIdentity)
                if let id = Int64(frame.sourceIdentifier) { cursor = id }
            }
            try reconciliation.add(batch: batch, statuses: statuses)
            for membership in batch.memberships.sorted(by: { $0.sourceIdentifier < $1.sourceIdentifier }) {
                Self.appendLengthPrefixed(membership.sourceIdentifier, to: &sourceHasher)
                Self.appendLengthPrefixed(membership.ocrIdentifier ?? "", to: &sourceHasher)
                Self.appendLengthPrefixed(membership.applicationIdentifier ?? "", to: &sourceHasher)
                Self.appendLengthPrefixed(membership.domainIdentifier ?? "", to: &sourceHasher)
                Self.appendLengthPrefixed(membership.sequenceIdentifier ?? "", to: &sourceHasher)
                for identity in membership.mediaIdentifiers.sorted() {
                    Self.appendLengthPrefixed(identity, to: &sourceHasher)
                }
            }
            if rows.count < requestCount { break }
        }

        return ScreenHistoryMigrationPreviewResult(
            source: source,
            imported: imported,
            excluded: excluded,
            invalid: invalid,
            reconciliation: reconciliation.result(),
            policyFingerprint: policy.fingerprint,
            sourceFingerprint: sourceHasher.finalize().map { String(format: "%02x", $0) }.joined(),
            lastLegacyFrameID: cursor,
            evaluatedAt: evaluatedAt
        )
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }

    private static func appendLengthPrefixed(_ value: String, to hasher: inout SHA256) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: bytes)
    }
}
