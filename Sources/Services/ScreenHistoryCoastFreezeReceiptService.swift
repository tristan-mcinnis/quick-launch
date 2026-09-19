import AppKit
import CryptoKit
import Darwin
import Foundation
import Security
import SQLite3

enum ScreenHistoryCoastFreezeReceiptError: Error, Equatable, Sendable {
    case sourceUnavailable
    case sourceIsActive
    case sourceIsNotReadOnly
    case unsafeSource
    case unsafeReceiptStorage
    case invalidDatabase
    case sourceChanged
    case corruptedCheckpoint
    case corruptedReceipt
    case primaryReceiptRequired
    case rollbackHoldRequired
    case rollbackHoldActive
    case secondCheckRequired
    case secondCheckMismatch
    case staleReceipt
    case integrityKeyUnavailable(OSStatus)
}

/// Makes a content-free, read-only inventory of Coast before retirement.
/// Media is opened with `O_NOFOLLOW` and fed to SHA-256 in bounded chunks. No
/// image or video is decoded, copied, or loaded as one `Data` value.
actor ScreenHistoryCoastFreezeReceiptService: ScreenHistoryCoastFreezeReceipting {
    nonisolated static let schemaVersion = 1
    nonisolated static let checkpointVersion = 1
    nonisolated static let streamingChunkByteCount = 1_048_576
    nonisolated static let defaultRollbackHoldDays = 14

    nonisolated let coastRootURL: URL
    nonisolated let receiptDirectoryURL: URL
    nonisolated let receiptURL: URL
    nonisolated let primaryCheckpointURL: URL
    nonisolated let secondCheckCheckpointURL: URL
    nonisolated let integrityKeyFileURL: URL

    private let databaseRelativePath: String
    private let rollbackHoldDays: Int
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private let coastProcessIsRunning: @Sendable () -> Bool
    private let integrityKey: SymmetricKey

    init(
        coastRootURL: URL = CoastLegacyReader.defaultDatabaseURL().deletingLastPathComponent(),
        receiptDirectoryURL: URL = ScreenHistoryCoastFreezeReceiptService.defaultReceiptDirectoryURL(),
        databaseRelativePath: String = "rem.db",
        rollbackHoldDays: Int = ScreenHistoryCoastFreezeReceiptService.defaultRollbackHoldDays,
        clock: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = ScreenHistoryCoastFreezeReceiptService.utcCalendar(),
        coastProcessIsRunning: @escaping @Sendable () -> Bool = {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: "inc.attention.rem"
            ).isEmpty
        },
        integrityKeyData: Data? = nil
    ) throws {
        // Preserve an already-canonical physical path such as /private/tmp.
        // `standardizedFileURL` rewrites it to the /tmp symlink alias, which
        // correctly fails our parent-symlink gate but makes safe temp roots
        // impossible to use. Dot components are still rejected downstream.
        self.coastRootURL = URL(
            fileURLWithPath: coastRootURL.path,
            isDirectory: true
        )
        self.receiptDirectoryURL = URL(
            fileURLWithPath: receiptDirectoryURL.path,
            isDirectory: true
        )
        receiptURL = receiptDirectoryURL.appendingPathComponent("coast-freeze-receipt.json")
        primaryCheckpointURL = receiptDirectoryURL.appendingPathComponent("primary-checkpoint.json")
        secondCheckCheckpointURL = receiptDirectoryURL.appendingPathComponent("second-check-checkpoint.json")
        integrityKeyFileURL = receiptDirectoryURL.appendingPathComponent(".integrity-key")
        self.databaseRelativePath = databaseRelativePath
        self.rollbackHoldDays = max(1, rollbackHoldDays)
        self.clock = clock
        self.calendar = calendar
        self.coastProcessIsRunning = coastProcessIsRunning

        guard Self.isSafeRelativePath(databaseRelativePath) else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        try Self.validateSourceRoot(self.coastRootURL)
        try Self.prepareReceiptStorage(
            self.receiptDirectoryURL,
            sourceRoot: self.coastRootURL,
            protectedFiles: [receiptURL, primaryCheckpointURL, secondCheckCheckpointURL, integrityKeyFileURL]
        )
        integrityKey = try integrityKeyData.map(SymmetricKey.init(data:))
            ?? Self.loadOrCreateIntegrityKey(
                receiptDirectoryURL: self.receiptDirectoryURL,
                fallbackFileURL: integrityKeyFileURL
            )
        _ = try Self.loadReceiptIfPresent(receiptURL, key: integrityKey)
    }

    func makePrimaryReceipt(
        maximumNewFiles: Int? = nil
    ) async throws -> ScreenHistoryCoastFreezeProgress {
        if let receipt = try Self.loadReceiptIfPresent(receiptURL, key: integrityKey)?.publicReceipt {
            return ScreenHistoryCoastFreezeProgress(
                kind: .primary,
                processedFiles: 1 + receipt.primary.files.count,
                totalFiles: 1 + receipt.primary.files.count,
                isComplete: true,
                receipt: receipt
            )
        }

        return try scan(
            kind: .primary,
            checkpointURL: primaryCheckpointURL,
            maximumNewFiles: maximumNewFiles
        )
    }

    func beginRollbackHold(
        expectedReceiptHMACSHA256: String
    ) async throws -> ScreenHistoryCoastFreezeReceipt {
        guard let envelope = try Self.loadReceiptIfPresent(receiptURL, key: integrityKey) else {
            throw ScreenHistoryCoastFreezeReceiptError.primaryReceiptRequired
        }
        guard envelope.receiptHMACSHA256 == expectedReceiptHMACSHA256 else {
            throw ScreenHistoryCoastFreezeReceiptError.staleReceipt
        }
        if envelope.payload.rollbackHoldStartedAt != nil {
            return envelope.publicReceipt
        }
        var payload = envelope.payload
        guard !coastProcessIsRunning() else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceIsActive
        }
        try Self.validateSourceIsReadOnly(coastRootURL)
        let startedAt = clock()
        payload.rollbackHoldStartedAt = startedAt
        payload.rollbackHoldUntil = calendar.date(
            byAdding: .day,
            value: rollbackHoldDays,
            to: startedAt
        )
        payload.secondCheckedAt = nil
        payload.secondCheckManifestSHA256 = nil
        payload.secondCheckMatched = false
        payload.approvalRecordedAt = nil
        payload.approvalState = .awaitingSecondCheck
        try Self.writeCheckpoint(
            CheckpointPayload(
                version: Self.checkpointVersion,
                kind: .secondCheck,
                sourceMetadataSHA256: "",
                entries: [],
                isComplete: false
            ),
            to: secondCheckCheckpointURL,
            key: integrityKey
        )
        return try Self.writeReceipt(payload, to: receiptURL, key: integrityKey).publicReceipt
    }

    func performSecondCheck(
        maximumNewFiles: Int? = nil
    ) async throws -> ScreenHistoryCoastFreezeProgress {
        guard let current = try Self.loadReceiptIfPresent(receiptURL, key: integrityKey)?.publicReceipt else {
            throw ScreenHistoryCoastFreezeReceiptError.primaryReceiptRequired
        }
        guard let holdUntil = current.rollbackHoldUntil else {
            throw ScreenHistoryCoastFreezeReceiptError.rollbackHoldRequired
        }
        guard clock() >= holdUntil else {
            throw ScreenHistoryCoastFreezeReceiptError.rollbackHoldActive
        }
        // A completed mismatch is evidence, not a reusable checkpoint. The
        // next explicit check starts a new independent pass. Matching checks
        // also start fresh so no caller can turn cached evidence into approval.
        if current.secondCheckedAt != nil,
           let checkpoint = try Self.loadCheckpointIfPresent(
               secondCheckCheckpointURL,
               expectedKind: .secondCheck,
               key: integrityKey
           ),
           checkpoint.payload.isComplete {
            try Self.writeCheckpoint(
                CheckpointPayload(
                    version: Self.checkpointVersion,
                    kind: .secondCheck,
                    sourceMetadataSHA256: "",
                    entries: [],
                    isComplete: false
                ),
                to: secondCheckCheckpointURL,
                key: integrityKey
            )
        }

        return try scan(
            kind: .secondCheck,
            checkpointURL: secondCheckCheckpointURL,
            maximumNewFiles: maximumNewFiles
        )
    }

    func recordRetirementApproval(
        expectedReceiptHMACSHA256: String,
        approved: Bool
    ) async throws -> ScreenHistoryCoastFreezeReceipt {
        guard let envelope = try Self.loadReceiptIfPresent(receiptURL, key: integrityKey) else {
            throw ScreenHistoryCoastFreezeReceiptError.primaryReceiptRequired
        }
        guard envelope.receiptHMACSHA256 == expectedReceiptHMACSHA256 else {
            throw ScreenHistoryCoastFreezeReceiptError.staleReceipt
        }

        var payload = envelope.payload
        if approved {
            guard payload.secondCheckMatched,
                  let holdUntil = payload.rollbackHoldUntil
            else {
                throw payload.secondCheckedAt == nil
                    ? ScreenHistoryCoastFreezeReceiptError.secondCheckRequired
                    : ScreenHistoryCoastFreezeReceiptError.secondCheckMismatch
            }
            guard clock() >= holdUntil else {
                throw ScreenHistoryCoastFreezeReceiptError.rollbackHoldActive
            }
            do {
                let proof = try freshSourceProof()
                try Self.writeCheckpoint(
                    proof.checkpoint,
                    to: secondCheckCheckpointURL,
                    key: integrityKey
                )
                let verifiedAt = clock()
                payload.secondCheckedAt = verifiedAt
                payload.secondCheckManifestSHA256 = proof.manifest.manifestSHA256
                payload.secondCheckMatched = proof.manifest.manifestSHA256
                    == payload.primary.manifestSHA256
                payload.approvalRecordedAt = nil
                payload.approvalState = payload.secondCheckMatched
                    ? .notApproved
                    : .awaitingSecondCheck
                guard payload.secondCheckMatched else {
                    _ = try Self.writeReceipt(payload, to: receiptURL, key: integrityKey)
                    throw ScreenHistoryCoastFreezeReceiptError.secondCheckMismatch
                }
                payload.approvalRecordedAt = verifiedAt
                payload.approvalState = .approvedForRetirement
            } catch {
                if payload.approvalState == .approvedForRetirement {
                    payload.approvalRecordedAt = clock()
                    payload.approvalState = .revoked
                    AppLog.attempt("Write Coast freeze receipt") {
                        try Self.writeReceipt(payload, to: receiptURL, key: integrityKey)
                    }
                }
                throw error
            }
        } else {
            payload.approvalRecordedAt = clock()
            payload.approvalState = .revoked
        }
        let updated = try Self.writeReceipt(payload, to: receiptURL, key: integrityKey)
        try Self.enforceOwnerOnlyPermissions(
            directoryURL: receiptDirectoryURL,
            files: [receiptURL, primaryCheckpointURL, secondCheckCheckpointURL]
        )
        return updated.publicReceipt
    }

    func currentReceipt() async throws -> ScreenHistoryCoastFreezeReceipt? {
        guard let envelope = try Self.loadReceiptIfPresent(receiptURL, key: integrityKey) else {
            return nil
        }
        guard envelope.payload.approvalState == .approvedForRetirement else {
            return envelope.publicReceipt
        }
        if try approvedSourceMetadataStillMatches() {
            return envelope.publicReceipt
        }
        var payload = envelope.payload
        payload.approvalRecordedAt = clock()
        payload.approvalState = .revoked
        return try Self.writeReceipt(payload, to: receiptURL, key: integrityKey).publicReceipt
    }

    static func loadOrCreateOwnerOnlyIntegrityKeyForTesting(at url: URL) throws -> SymmetricKey {
        try loadOrCreateOwnerOnlyIntegrityKey(at: url)
    }

    static func loadOrCreateIntegrityKeyForTesting(
        receiptDirectoryURL: URL,
        fallbackFileURL: URL,
        keychain: any KeychainStoring
    ) throws -> SymmetricKey {
        try loadOrCreateIntegrityKey(
            receiptDirectoryURL: receiptDirectoryURL,
            fallbackFileURL: fallbackFileURL,
            keychain: keychain
        )
    }

    static var integrityKeyServiceForTesting: String { integrityKeyService }
    static var defaultReceiptDirectoryURLForTesting: URL { defaultReceiptDirectoryURL() }
}

private extension ScreenHistoryCoastFreezeReceiptService {
    struct SourceIdentity: Codable, Equatable, Sendable {
        let relativePath: String
        let family: ScreenHistoryCoastFileFamily
        let byteCount: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let device: UInt64
        let inode: UInt64

        var modifiedAt: Date {
            Date(
                timeIntervalSince1970: TimeInterval(modifiedSeconds)
                    + TimeInterval(modifiedNanoseconds) / 1_000_000_000
            )
        }
    }

    struct Candidate: Sendable {
        let url: URL
        let identity: SourceIdentity
    }

    struct CheckpointEntry: Codable, Equatable, Sendable {
        let identity: SourceIdentity
        let sha256: String
    }

    struct CheckpointPayload: Codable, Equatable, Sendable {
        let version: Int
        let kind: ScreenHistoryCoastFreezeScanKind
        let sourceMetadataSHA256: String
        let entries: [CheckpointEntry]
        let isComplete: Bool
    }

    struct CheckpointEnvelope: Codable, Equatable, Sendable {
        let payload: CheckpointPayload
        let checkpointHMACSHA256: String
    }

    struct FreshSourceProof: Sendable {
        let manifest: ScreenHistoryCoastFreezeManifest
        let checkpoint: CheckpointPayload
    }

    struct ManifestContent: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let database: ScreenHistoryCoastDatabaseRecord
        let files: [ScreenHistoryCoastFrozenFile]
        let families: [ScreenHistoryCoastFamilySummary]
        let runtimeExclusions: [ScreenHistoryCoastRuntimeExclusion]
    }

    struct ReceiptPayload: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let primary: ScreenHistoryCoastFreezeManifest
        var secondCheckedAt: Date?
        var secondCheckManifestSHA256: String?
        var secondCheckMatched: Bool
        var rollbackHoldStartedAt: Date?
        var rollbackHoldUntil: Date?
        var approvalRecordedAt: Date?
        var approvalState: ScreenHistoryCoastRetirementApprovalState
    }

    struct ReceiptEnvelope: Codable, Equatable, Sendable {
        let payload: ReceiptPayload
        let receiptHMACSHA256: String

        var publicReceipt: ScreenHistoryCoastFreezeReceipt {
            ScreenHistoryCoastFreezeReceipt(
                schemaVersion: payload.schemaVersion,
                primary: payload.primary,
                secondCheckedAt: payload.secondCheckedAt,
                secondCheckManifestSHA256: payload.secondCheckManifestSHA256,
                secondCheckMatched: payload.secondCheckMatched,
                rollbackHoldStartedAt: payload.rollbackHoldStartedAt,
                rollbackHoldUntil: payload.rollbackHoldUntil,
                approvalRecordedAt: payload.approvalRecordedAt,
                approvalState: payload.approvalState,
                receiptHMACSHA256: receiptHMACSHA256
            )
        }
    }

    func scan(
        kind: ScreenHistoryCoastFreezeScanKind,
        checkpointURL: URL,
        maximumNewFiles: Int?
    ) throws -> ScreenHistoryCoastFreezeProgress {
        guard !coastProcessIsRunning() else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceIsActive
        }
        try Self.validateSourceRoot(coastRootURL)
        if kind == .secondCheck {
            try Self.validateSourceIsReadOnly(coastRootURL)
        }
        let candidates = try Self.enumerateCandidates(
            rootURL: coastRootURL,
            databaseRelativePath: databaseRelativePath
        )
        let metadataHash = Self.hash(candidates.map(\.identity))
        let loaded = try Self.loadCheckpointIfPresent(
            checkpointURL,
            expectedKind: kind,
            key: integrityKey
        )
        var checkpoint = loaded?.payload
        if checkpoint?.sourceMetadataSHA256 != metadataHash {
            checkpoint = CheckpointPayload(
                version: Self.checkpointVersion,
                kind: kind,
                sourceMetadataSHA256: metadataHash,
                entries: [],
                isComplete: false
            )
        }

        var entries = Dictionary(
            uniqueKeysWithValues: (checkpoint?.entries ?? []).map { ($0.identity.relativePath, $0) }
        )
        if !entries.values.allSatisfy({ entry in
            candidates.contains { $0.identity == entry.identity }
        }) {
            entries.removeAll()
        }

        let boundedLimit = maximumNewFiles.map { max(0, $0) } ?? Int.max
        var newlyHashed = 0
        var writesSinceCheckpoint = 0
        for candidate in candidates where entries[candidate.identity.relativePath] == nil {
            if newlyHashed >= boundedLimit { break }
            let digest = try Self.streamingSHA256(candidate, rootURL: coastRootURL)
            entries[candidate.identity.relativePath] = CheckpointEntry(
                identity: candidate.identity,
                sha256: digest
            )
            newlyHashed += 1
            writesSinceCheckpoint += 1
            if writesSinceCheckpoint >= 25 {
                try Self.writeCheckpoint(
                    Self.checkpointPayload(
                        kind: kind,
                        metadataHash: metadataHash,
                        entries: entries,
                        candidates: candidates,
                        complete: false
                    ),
                    to: checkpointURL,
                    key: integrityKey
                )
                writesSinceCheckpoint = 0
            }
        }

        let complete = entries.count == candidates.count
        let finalCheckpoint = Self.checkpointPayload(
            kind: kind,
            metadataHash: metadataHash,
            entries: entries,
            candidates: candidates,
            complete: complete
        )
        try Self.writeCheckpoint(finalCheckpoint, to: checkpointURL, key: integrityKey)
        try Self.enforceOwnerOnlyPermissions(
            directoryURL: receiptDirectoryURL,
            files: [receiptURL, primaryCheckpointURL, secondCheckCheckpointURL]
        )

        guard complete else {
            return ScreenHistoryCoastFreezeProgress(
                kind: kind,
                processedFiles: entries.count,
                totalFiles: candidates.count,
                isComplete: false,
                receipt: try Self.loadReceiptIfPresent(receiptURL, key: integrityKey)?.publicReceipt
            )
        }

        let manifest = try Self.makeManifest(
            candidates: candidates,
            entries: entries,
            rootURL: coastRootURL,
            databaseRelativePath: databaseRelativePath,
            createdAt: clock()
        )
        let finalCandidates = try Self.enumerateCandidates(
            rootURL: coastRootURL,
            databaseRelativePath: databaseRelativePath
        )
        guard finalCandidates.map(\.identity) == candidates.map(\.identity) else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceChanged
        }
        guard !coastProcessIsRunning() else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceIsActive
        }
        if kind == .secondCheck {
            try Self.validateSourceIsReadOnly(coastRootURL)
        }

        let receipt: ScreenHistoryCoastFreezeReceipt
        switch kind {
        case .primary:
            let payload = ReceiptPayload(
                schemaVersion: Self.schemaVersion,
                primary: manifest,
                secondCheckedAt: nil,
                secondCheckManifestSHA256: nil,
                secondCheckMatched: false,
                rollbackHoldStartedAt: nil,
                rollbackHoldUntil: nil,
                approvalRecordedAt: nil,
                approvalState: .awaitingRollbackHold
            )
            receipt = try Self.writeReceipt(payload, to: receiptURL, key: integrityKey).publicReceipt

        case .secondCheck:
            guard let existing = try Self.loadReceiptIfPresent(receiptURL, key: integrityKey) else {
                throw ScreenHistoryCoastFreezeReceiptError.primaryReceiptRequired
            }
            var payload = existing.payload
            let checkedAt = clock()
            let matches = payload.primary.manifestSHA256 == manifest.manifestSHA256
            payload.secondCheckedAt = checkedAt
            payload.secondCheckManifestSHA256 = manifest.manifestSHA256
            payload.secondCheckMatched = matches
            payload.approvalRecordedAt = nil
            payload.approvalState = matches ? .notApproved : .awaitingSecondCheck
            receipt = try Self.writeReceipt(payload, to: receiptURL, key: integrityKey).publicReceipt
        }

        return ScreenHistoryCoastFreezeProgress(
            kind: kind,
            processedFiles: candidates.count,
            totalFiles: candidates.count,
            isComplete: true,
            receipt: receipt
        )
    }

    func freshSourceProof() throws -> FreshSourceProof {
        guard !coastProcessIsRunning() else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceIsActive
        }
        try Self.validateSourceRoot(coastRootURL)
        try Self.validateSourceIsReadOnly(coastRootURL)
        let candidates = try Self.enumerateCandidates(
            rootURL: coastRootURL,
            databaseRelativePath: databaseRelativePath
        )
        var entries: [String: CheckpointEntry] = [:]
        for candidate in candidates {
            entries[candidate.identity.relativePath] = CheckpointEntry(
                identity: candidate.identity,
                sha256: try Self.streamingSHA256(candidate, rootURL: coastRootURL)
            )
        }
        let manifest = try Self.makeManifest(
            candidates: candidates,
            entries: entries,
            rootURL: coastRootURL,
            databaseRelativePath: databaseRelativePath,
            createdAt: clock()
        )
        let finalCandidates = try Self.enumerateCandidates(
            rootURL: coastRootURL,
            databaseRelativePath: databaseRelativePath
        )
        guard finalCandidates.map(\.identity) == candidates.map(\.identity) else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceChanged
        }
        guard !coastProcessIsRunning() else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceIsActive
        }
        try Self.validateSourceIsReadOnly(coastRootURL)
        let metadataHash = Self.hash(candidates.map(\.identity))
        return FreshSourceProof(
            manifest: manifest,
            checkpoint: Self.checkpointPayload(
                kind: .secondCheck,
                metadataHash: metadataHash,
                entries: entries,
                candidates: candidates,
                complete: true
            )
        )
    }

    func approvedSourceMetadataStillMatches() throws -> Bool {
        guard !coastProcessIsRunning() else { return false }
        do { try Self.validateSourceIsReadOnly(coastRootURL) }
        catch { return false }
        let candidates: [Candidate]
        do {
            candidates = try Self.enumerateCandidates(
                rootURL: coastRootURL,
                databaseRelativePath: databaseRelativePath
            )
        } catch {
            return false
        }
        guard let checkpoint = try Self.loadCheckpointIfPresent(
            secondCheckCheckpointURL,
            expectedKind: .secondCheck,
            key: integrityKey
        ), checkpoint.payload.isComplete else { return false }
        let identities = candidates.map(\.identity)
        return checkpoint.payload.sourceMetadataSHA256 == Self.hash(identities)
            && checkpoint.payload.entries.map(\.identity) == identities
    }

    static func checkpointPayload(
        kind: ScreenHistoryCoastFreezeScanKind,
        metadataHash: String,
        entries: [String: CheckpointEntry],
        candidates: [Candidate],
        complete: Bool
    ) -> CheckpointPayload {
        CheckpointPayload(
            version: checkpointVersion,
            kind: kind,
            sourceMetadataSHA256: metadataHash,
            entries: candidates.compactMap { entries[$0.identity.relativePath] },
            isComplete: complete
        )
    }

    static func makeManifest(
        candidates: [Candidate],
        entries: [String: CheckpointEntry],
        rootURL: URL,
        databaseRelativePath: String,
        createdAt: Date
    ) throws -> ScreenHistoryCoastFreezeManifest {
        guard let databaseCandidate = candidates.first(where: {
            $0.identity.relativePath == databaseRelativePath
        }),
        let databaseDigest = entries[databaseRelativePath]?.sha256
        else { throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase }

        let database = try inspectDatabase(
            at: databaseCandidate.url,
            identity: databaseCandidate.identity,
            sha256: databaseDigest
        )
        let files = try candidates.compactMap { candidate -> ScreenHistoryCoastFrozenFile? in
            guard candidate.identity.relativePath != databaseRelativePath else { return nil }
            guard let entry = entries[candidate.identity.relativePath],
                  entry.identity == candidate.identity,
                  isSHA256(entry.sha256)
            else { throw ScreenHistoryCoastFreezeReceiptError.corruptedCheckpoint }
            return ScreenHistoryCoastFrozenFile(
                relativePath: candidate.identity.relativePath,
                family: candidate.identity.family,
                byteCount: candidate.identity.byteCount,
                modifiedAt: candidate.identity.modifiedAt,
                sha256: entry.sha256
            )
        }
        let families = ScreenHistoryCoastFileFamily.allCases.map { family in
            let matches = files.filter { $0.family == family }
            return ScreenHistoryCoastFamilySummary(
                family: family,
                fileCount: matches.count,
                byteCount: matches.reduce(0) { $0 + $1.byteCount }
            )
        }
        let content = ManifestContent(
            schemaVersion: schemaVersion,
            database: database,
            files: files,
            families: families,
            runtimeExclusions: ScreenHistoryCoastRuntimeExclusion.allCases
        )
        return ScreenHistoryCoastFreezeManifest(
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            database: database,
            files: files,
            families: families,
            runtimeExclusions: ScreenHistoryCoastRuntimeExclusion.allCases,
            manifestSHA256: hash(content)
        )
    }

    static func inspectDatabase(
        at url: URL,
        identity: SourceIdentity,
        sha256: String
    ) throws -> ScreenHistoryCoastDatabaseRecord {
        guard identity.relativePath == "rem.db" || identity.relativePath.hasSuffix("/rem.db"),
              isSHA256(sha256),
              try sourceIdentity(at: url, relativePath: identity.relativePath, family: identity.family) == identity
        else { throw ScreenHistoryCoastFreezeReceiptError.sourceChanged }

        let database: LocalSQLiteConnection
        do {
            database = try LocalSQLiteConnection(
                url: url,
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            )
            try database.execute("PRAGMA query_only = ON;")
        } catch {
            throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase
        }

        let schemaRows = try querySchema(database)
        guard schemaRows.contains(where: { $0.name == "frame" && $0.type == "table" }) else {
            throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase
        }
        var schemaHasher = SHA256()
        for row in schemaRows {
            append(row.type, to: &schemaHasher)
            append(row.name, to: &schemaHasher)
            append(row.tableName, to: &schemaHasher)
            append(row.sql, to: &schemaHasher)
        }
        let objectCounts = Dictionary(grouping: schemaRows, by: \.type).mapValues(\.count)
        let userVersion = try scalarInt64(database, sql: "PRAGMA user_version;")
        let applicationID = try scalarInt64(database, sql: "PRAGMA application_id;")
        let counts = ScreenHistoryCoastDatabaseCounts(
            frames: try rowCount(database, table: "frame"),
            videos: try rowCount(database, table: "video"),
            segments: try rowCount(database, table: "segment"),
            ocrBoxes: try rowCount(database, table: "ocr"),
            accessibilitySnapshots: try rowCount(database, table: "ax_snapshot"),
            applications: try rowCount(database, table: "application"),
            domains: try rowCount(database, table: "domain")
        )
        let range = try frameDateRange(database)

        guard try sourceIdentity(
            at: url,
            relativePath: identity.relativePath,
            family: identity.family
        ) == identity else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceChanged
        }
        return ScreenHistoryCoastDatabaseRecord(
            relativePath: identity.relativePath,
            byteCount: identity.byteCount,
            modifiedAt: identity.modifiedAt,
            sha256: sha256,
            schema: ScreenHistoryCoastDatabaseSchema(
                userVersion: userVersion,
                applicationID: applicationID,
                schemaSHA256: hex(schemaHasher.finalize()),
                tableCount: objectCounts["table", default: 0],
                indexCount: objectCounts["index", default: 0],
                triggerCount: objectCounts["trigger", default: 0],
                viewCount: objectCounts["view", default: 0]
            ),
            counts: counts,
            earliestFrameAt: range.minimum,
            latestFrameAt: range.maximum
        )
    }

    struct SchemaRow {
        let type: String
        let name: String
        let tableName: String
        let sql: String
    }

    static func querySchema(_ database: LocalSQLiteConnection) throws -> [SchemaRow] {
        let statement: OpaquePointer
        do {
            statement = try database.prepare("""
                SELECT type, name, tbl_name, COALESCE(sql, '')
                FROM sqlite_master
                WHERE name NOT LIKE 'sqlite_%'
                ORDER BY type, name, tbl_name;
                """)
        } catch {
            throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }
        var rows: [SchemaRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else {
                throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase
            }
            rows.append(SchemaRow(
                type: SQLiteValue.text(statement, 0) ?? "",
                name: SQLiteValue.text(statement, 1) ?? "",
                tableName: SQLiteValue.text(statement, 2) ?? "",
                sql: SQLiteValue.text(statement, 3) ?? ""
            ))
        }
    }

    static func rowCount(_ database: LocalSQLiteConnection, table: String) throws -> Int64 {
        let allowed = [
            "frame", "video", "segment", "ocr", "ax_snapshot", "application", "domain",
        ]
        guard allowed.contains(table) else {
            throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase
        }
        let exists = try scalarInt64(
            database,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)';"
        )
        guard exists > 0 else { return 0 }
        return try scalarInt64(database, sql: "SELECT COUNT(*) FROM \(table);")
    }

    static func scalarInt64(_ database: LocalSQLiteConnection, sql: String) throws -> Int64 {
        let statement: OpaquePointer
        do { statement = try database.prepare(sql) }
        catch { throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase
        }
        return sqlite3_column_int64(statement, 0)
    }

    static func frameDateRange(
        _ database: LocalSQLiteConnection
    ) throws -> (minimum: Date?, maximum: Date?) {
        let statement: OpaquePointer
        do { statement = try database.prepare("SELECT MIN(timestamp), MAX(timestamp) FROM frame;") }
        catch { throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase
        }
        func date(_ column: Int32) -> Date? {
            guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
            let raw = sqlite3_column_double(statement, column)
            let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
            return Date(timeIntervalSince1970: seconds)
        }
        return (date(0), date(1))
    }

    static func enumerateCandidates(
        rootURL: URL,
        databaseRelativePath: String
    ) throws -> [Candidate] {
        try validateSourceRoot(rootURL)
        var candidates: [Candidate] = []
        try walkDirectory(rootURL, rootURL: rootURL, candidates: &candidates)
        candidates.sort { $0.identity.relativePath < $1.identity.relativePath }
        guard candidates.contains(where: { $0.identity.relativePath == databaseRelativePath }) else {
            throw ScreenHistoryCoastFreezeReceiptError.invalidDatabase
        }
        return candidates
    }

    static func walkDirectory(
        _ directoryURL: URL,
        rootURL: URL,
        candidates: inout [Candidate]
    ) throws {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        for child in children {
            let relativePath = try relativePath(child, below: rootURL)
            var metadata = stat()
            guard lstat(child.path, &metadata) == 0 else {
                throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
            }
            let kind = metadata.st_mode & S_IFMT
            if relativePath == "cli.sock", kind == S_IFSOCK {
                continue
            }
            if relativePath == "rem.db-shm", kind == S_IFREG {
                continue
            }
            if kind == S_IFLNK {
                throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
            }
            if kind == S_IFDIR {
                try walkDirectory(child, rootURL: rootURL, candidates: &candidates)
            } else if kind == S_IFREG {
                candidates.append(Candidate(
                    url: child,
                    identity: try sourceIdentity(
                        at: child,
                        relativePath: relativePath,
                        family: family(relativePath)
                    )
                ))
            } else {
                throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
            }
        }
    }

    static func streamingSHA256(_ candidate: Candidate, rootURL: URL) throws -> String {
        let descriptor = try openReadOnlyFile(
            rootURL: rootURL,
            relativePath: candidate.identity.relativePath
        )
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        guard try identity(descriptor: descriptor, relativePath: candidate.identity.relativePath,
                           family: candidate.identity.family) == candidate.identity else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceChanged
        }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: streamingChunkByteCount), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw ScreenHistoryCoastFreezeReceiptError.sourceChanged
        }
        guard try identity(descriptor: descriptor, relativePath: candidate.identity.relativePath,
                           family: candidate.identity.family) == candidate.identity else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceChanged
        }
        return hex(hasher.finalize())
    }

    static func openReadOnlyFile(rootURL: URL, relativePath: String) throws -> Int32 {
        guard isSafeRelativePath(relativePath) else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        var directoryDescriptor = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        defer { if directoryDescriptor >= 0 { close(directoryDescriptor) } }

        let components = relativePath.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            let next = component.withCString { pointer in
                openat(
                    directoryDescriptor,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard next >= 0 else {
                throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
            }
            close(directoryDescriptor)
            directoryDescriptor = next
        }
        guard let final = components.last else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        let descriptor = final.withCString { pointer in
            openat(directoryDescriptor, pointer, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        return descriptor
    }

    static func sourceIdentity(
        at url: URL,
        relativePath: String,
        family: ScreenHistoryCoastFileFamily
    ) throws -> SourceIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG
        else { throw ScreenHistoryCoastFreezeReceiptError.unsafeSource }
        return identity(metadata, relativePath: relativePath, family: family)
    }

    static func identity(
        descriptor: Int32,
        relativePath: String,
        family: ScreenHistoryCoastFileFamily
    ) throws -> SourceIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG
        else { throw ScreenHistoryCoastFreezeReceiptError.unsafeSource }
        return identity(metadata, relativePath: relativePath, family: family)
    }

    static func identity(
        _ metadata: stat,
        relativePath: String,
        family: ScreenHistoryCoastFileFamily
    ) -> SourceIdentity {
        SourceIdentity(
            relativePath: relativePath,
            family: family,
            byteCount: Int64(metadata.st_size),
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    static func family(_ relativePath: String) -> ScreenHistoryCoastFileFamily {
        let first = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            .first?.lowercased()
        return switch first {
        case "frames": .frames
        case "videos": .videos
        case "icons": .icons
        default: .support
        }
    }

    static func relativePath(_ url: URL, below rootURL: URL) throws -> String {
        let root = rootURL.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        let relative = String(candidate.dropFirst(root.count + 1))
        guard isSafeRelativePath(relative) else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        return relative
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func validateSourceRoot(_ rootURL: URL) throws {
        try validateNoSymlinkComponents(rootURL, allowMissingTail: false)
        var metadata = stat()
        guard lstat(rootURL.path, &metadata) == 0 else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceUnavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_mode & S_IFMT != S_IFLNK,
              rootURL.standardizedFileURL.resolvingSymlinksInPath().path
                == rootURL.standardizedFileURL.path
        else { throw ScreenHistoryCoastFreezeReceiptError.unsafeSource }
    }

    static func validateSourceIsReadOnly(_ rootURL: URL) throws {
        try validateSourceRoot(rootURL)
        try validateNoWriteBits(rootURL, rootURL: rootURL)
    }

    static func validateNoWriteBits(_ url: URL, rootURL: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        let relative = url.path == rootURL.path ? "" : try relativePath(url, below: rootURL)
        let kind = metadata.st_mode & S_IFMT
        if (relative == "cli.sock" && kind == S_IFSOCK)
            || (relative == "rem.db-shm" && kind == S_IFREG) {
            return
        }
        let writeMask = mode_t(S_IWUSR | S_IWGRP | S_IWOTH)
        guard metadata.st_mode & writeMask == 0,
              access(url.path, W_OK) != 0
        else {
            throw ScreenHistoryCoastFreezeReceiptError.sourceIsNotReadOnly
        }
        if kind == S_IFDIR {
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
            }
            for child in children {
                try validateNoWriteBits(child, rootURL: rootURL)
            }
        } else if kind != S_IFREG {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
    }

    static func validateNoSymlinkComponents(
        _ url: URL,
        allowMissingTail: Bool
    ) throws {
        guard url.path.hasPrefix("/") else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        let components = url.pathComponents.dropFirst()
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components {
            current.appendPathComponent(component)
            var metadata = stat()
            if lstat(current.path, &metadata) != 0 {
                if allowMissingTail && errno == ENOENT { return }
                throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
            }
            guard metadata.st_mode & S_IFMT != S_IFLNK else {
                throw ScreenHistoryCoastFreezeReceiptError.unsafeSource
            }
        }
    }

    static func prepareReceiptStorage(
        _ directoryURL: URL,
        sourceRoot: URL,
        protectedFiles: [URL]
    ) throws {
        do {
            try validateNoSymlinkComponents(directoryURL, allowMissingTail: true)
        } catch {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        let source = sourceRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let destination = directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard destination != source, !destination.hasPrefix(source + "/") else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: directoryURL.path) {
            guard try !isSymbolicLink(directoryURL) else {
                throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
            }
        } else {
            do {
                try manager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
            }
        }
        do {
            try validateNoSymlinkComponents(directoryURL, allowMissingTail: false)
        } catch {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        try enforceOwnerOnlyPermissions(directoryURL: directoryURL, files: protectedFiles)
    }

    static func enforceOwnerOnlyPermissions(directoryURL: URL, files: [URL]) throws {
        let manager = FileManager.default
        do {
            try validateNoSymlinkComponents(directoryURL, allowMissingTail: false)
        } catch {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        guard try !isSymbolicLink(directoryURL) else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        for file in files where manager.fileExists(atPath: file.path) {
            guard try !isSymbolicLink(file) else {
                throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    static func writeCheckpoint(
        _ payload: CheckpointPayload,
        to url: URL,
        key: SymmetricKey
    ) throws {
        let envelope = CheckpointEnvelope(
            payload: payload,
            checkpointHMACSHA256: hmac(payload, key: key)
        )
        try writeOwnerOnly(envelope, to: url)
    }

    static func loadCheckpointIfPresent(
        _ url: URL,
        expectedKind: ScreenHistoryCoastFreezeScanKind,
        key: SymmetricKey
    ) throws -> CheckpointEnvelope? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { try validateNoSymlinkComponents(url, allowMissingTail: false) }
        catch { throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage }
        guard try !isSymbolicLink(url) else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        let envelope: CheckpointEnvelope
        do { envelope = try decoder().decode(CheckpointEnvelope.self, from: Data(contentsOf: url)) }
        catch { throw ScreenHistoryCoastFreezeReceiptError.corruptedCheckpoint }
        guard envelope.payload.version == checkpointVersion,
              envelope.payload.kind == expectedKind,
              envelope.checkpointHMACSHA256 == hmac(envelope.payload, key: key),
              Set(envelope.payload.entries.map(\.identity.relativePath)).count
                == envelope.payload.entries.count,
              envelope.payload.entries.allSatisfy({
                  isSafeRelativePath($0.identity.relativePath) && isSHA256($0.sha256)
              })
        else { throw ScreenHistoryCoastFreezeReceiptError.corruptedCheckpoint }
        return envelope
    }

    static func writeReceipt(
        _ payload: ReceiptPayload,
        to url: URL,
        key: SymmetricKey
    ) throws -> ReceiptEnvelope {
        let envelope = ReceiptEnvelope(
            payload: payload,
            receiptHMACSHA256: hmac(payload, key: key)
        )
        try writeOwnerOnly(envelope, to: url)
        return envelope
    }

    static func loadReceiptIfPresent(
        _ url: URL,
        key: SymmetricKey
    ) throws -> ReceiptEnvelope? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { try validateNoSymlinkComponents(url, allowMissingTail: false) }
        catch { throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage }
        guard try !isSymbolicLink(url) else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        let envelope: ReceiptEnvelope
        do { envelope = try decoder().decode(ReceiptEnvelope.self, from: Data(contentsOf: url)) }
        catch { throw ScreenHistoryCoastFreezeReceiptError.corruptedReceipt }
        guard envelope.payload.schemaVersion == schemaVersion,
              envelope.receiptHMACSHA256 == hmac(envelope.payload, key: key),
              envelope.payload.primary.schemaVersion == schemaVersion,
              isSHA256(envelope.payload.primary.manifestSHA256),
              manifestHashIsValid(envelope.payload.primary),
              approvalIsStructurallyValid(envelope.payload)
        else { throw ScreenHistoryCoastFreezeReceiptError.corruptedReceipt }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return envelope
    }

    static func manifestHashIsValid(_ manifest: ScreenHistoryCoastFreezeManifest) -> Bool {
        hash(ManifestContent(
            schemaVersion: manifest.schemaVersion,
            database: manifest.database,
            files: manifest.files,
            families: manifest.families,
            runtimeExclusions: manifest.runtimeExclusions
        )) == manifest.manifestSHA256
    }

    static func approvalIsStructurallyValid(_ payload: ReceiptPayload) -> Bool {
        if payload.secondCheckedAt == nil {
            guard payload.secondCheckManifestSHA256 == nil,
                  !payload.secondCheckMatched
            else { return false }
            if payload.rollbackHoldStartedAt == nil && payload.rollbackHoldUntil == nil {
                return (payload.approvalState == .awaitingRollbackHold
                        && payload.approvalRecordedAt == nil)
                    || (payload.approvalState == .revoked
                        && payload.approvalRecordedAt != nil)
            }
            guard let start = payload.rollbackHoldStartedAt,
                  let end = payload.rollbackHoldUntil,
                  end > start
            else { return false }
            return (payload.approvalState == .awaitingSecondCheck
                    && payload.approvalRecordedAt == nil)
                || (payload.approvalState == .revoked
                    && payload.approvalRecordedAt != nil)
        }
        guard let secondHash = payload.secondCheckManifestSHA256,
              isSHA256(secondHash),
              let holdStart = payload.rollbackHoldStartedAt,
              let holdEnd = payload.rollbackHoldUntil,
              holdEnd > holdStart,
              let checkedAt = payload.secondCheckedAt,
              checkedAt >= holdEnd
        else { return false }
        if payload.secondCheckMatched {
            guard secondHash == payload.primary.manifestSHA256 else { return false }
        } else {
            return payload.approvalState == .awaitingSecondCheck
                && payload.approvalRecordedAt == nil
        }
        switch payload.approvalState {
        case .awaitingRollbackHold, .awaitingSecondCheck:
            return false
        case .notApproved:
            return payload.approvalRecordedAt == nil
        case .approvedForRetirement:
            return payload.secondCheckMatched && payload.approvalRecordedAt != nil
        case .revoked:
            return payload.approvalRecordedAt != nil
        }
    }

    static func writeOwnerOnly<T: Encodable>(_ value: T, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try validateNoSymlinkComponents(directory, allowMissingTail: false)
        } catch {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        guard manager.fileExists(atPath: directory.path),
              try !isSymbolicLink(directory)
        else { throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage }
        if manager.fileExists(atPath: url.path), try isSymbolicLink(url) {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        let temporary = directory.appendingPathComponent(".freeze-\(UUID().uuidString).tmp")
        let data: Data
        do { data = try encoder().encode(value) }
        catch { throw ScreenHistoryCoastFreezeReceiptError.corruptedReceipt }
        guard manager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else { throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage }
        var wroteCompleteTemporary = false
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            // The payload is durable in the temporary from here on.
            wroteCompleteTemporary = true
            if manager.fileExists(atPath: url.path) {
                _ = try manager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: url)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // A partial write has nothing to inspect, so remove it: a failed
            // receipt must not leave `.freeze-*.tmp` debris behind. A complete
            // temporary that could not be published is kept for inspection.
            if !wroteCompleteTemporary {
                try? manager.removeItem(at: temporary)
            }
            throw error
        }
    }

    static func isSymbolicLink(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func hash<T: Encodable>(_ value: T) -> String {
        let data = (try? encoder().encode(value)) ?? Data()
        return hex(SHA256.hash(data: data))
    }

    static func hmac<T: Encodable>(_ value: T, key: SymmetricKey) -> String {
        let data = (try? encoder().encode(value)) ?? Data()
        return hex(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static let integrityKeyService = "ai.quick-launch.screen-history.coast-freeze"

    static func loadOrCreateIntegrityKey(
        receiptDirectoryURL: URL,
        fallbackFileURL: URL,
        keychain: any KeychainStoring = SystemKeychainStore()
    ) throws -> SymmetricKey {
        let account = hex(SHA256.hash(data: Data(
            receiptDirectoryURL.standardizedFileURL.path.utf8
        )))
        func isLockedOut(_ status: OSStatus) -> Bool {
            status == errSecAuthFailed || status == errSecInteractionNotAllowed
        }
        func existingKey() throws -> SymmetricKey? {
            let data: Data?
            do {
                data = try keychain.read(service: integrityKeyService, account: account)
            } catch {
                if isLockedOut(error.status) {
                    return try loadOrCreateOwnerOnlyIntegrityKey(at: fallbackFileURL)
                }
                throw ScreenHistoryCoastFreezeReceiptError.integrityKeyUnavailable(error.status)
            }
            guard let data else { return nil }
            guard data.count == 32 else {
                throw ScreenHistoryCoastFreezeReceiptError.integrityKeyUnavailable(errSecSuccess)
            }
            return SymmetricKey(data: data)
        }
        if let key = try existingKey() { return key }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ScreenHistoryCoastFreezeReceiptError.integrityKeyUnavailable(errSecInternalError)
        }
        let data = Data(bytes)
        do {
            try keychain.add(
                data,
                service: integrityKeyService,
                account: account,
                options: KeychainItemOptions(
                    accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
                )
            )
        } catch {
            if error.status == errSecDuplicateItem, let key = try existingKey() { return key }
            if isLockedOut(error.status) {
                return try loadOrCreateOwnerOnlyIntegrityKey(at: fallbackFileURL, candidate: data)
            }
            throw ScreenHistoryCoastFreezeReceiptError.integrityKeyUnavailable(error.status)
        }
        return SymmetricKey(data: data)
    }

    /// FileVault and owner-only permissions are the local fallback when an
    /// ad-hoc development build cannot write to macOS Keychain. The receipt
    /// remains authenticated and no source content enters this file.
    static func loadOrCreateOwnerOnlyIntegrityKey(
        at url: URL,
        candidate: Data? = nil
    ) throws -> SymmetricKey {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try validateNoSymlinkComponents(directory, allowMissingTail: false)
        } catch {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        guard manager.fileExists(atPath: directory.path),
              try !isSymbolicLink(directory)
        else { throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage }

        func readExisting() throws -> SymmetricKey? {
            guard manager.fileExists(atPath: url.path) else { return nil }
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
            }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o077 == 0,
                  metadata.st_size == 32
            else { throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage }
            var bytes = [UInt8](repeating: 0, count: 32)
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeMutableBytes { buffer in
                    read(
                        descriptor,
                        buffer.baseAddress?.advanced(by: offset),
                        buffer.count - offset
                    )
                }
                guard count > 0 else {
                    throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
                }
                offset += count
            }
            return SymmetricKey(data: Data(bytes))
        }
        if let key = try readExisting() { return key }

        let data: Data
        if let candidate, candidate.count == 32 {
            data = candidate
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw ScreenHistoryCoastFreezeReceiptError.integrityKeyUnavailable(errSecInternalError)
            }
            data = Data(bytes)
        }
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        if descriptor < 0 {
            if errno == EEXIST, let key = try readExisting() { return key }
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        defer { close(descriptor) }
        var offset = 0
        try data.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let written = write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
                guard written > 0 else {
                    throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage
        }
        return SymmetricKey(data: data)
    }

    static func append(_ value: String, to hasher: inout SHA256) {
        let bytes = Data(value.utf8)
        var count = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &count) { hasher.update(data: Data($0)) }
        hasher.update(data: bytes)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func defaultReceiptDirectoryURL() -> URL {
        AppPaths.directory("Screen History Coast Freeze")
    }

    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}
