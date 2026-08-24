import CryptoKit
import Foundation
import Darwin

enum ScreenHistoryMediaKind: String, Hashable, Sendable {
    case image
    case video
}

enum ScreenHistoryMediaMigrationStatus: String, Sendable {
    case copied
    case missing
    case invalid
    case hashMismatch = "hash_mismatch"
    case failed
}

enum ScreenHistoryMediaMigrationError: Error, Equatable, Sendable {
    case ownedMediaRootIsSymbolicLink
}

struct ScreenHistoryMediaMigrationRow: Equatable, Sendable {
    let frameID: Int64
    let sourceIdentifier: String
    let capturedAt: Date
    let application: String?
    let imageLocator: String?
    let mediaLocator: String?
    let mediaFrameIndex: Int?
}

struct ScreenHistoryMediaReference: Equatable, Hashable, Sendable {
    let frameID: Int64
    let sourceIdentifier: String
    let kind: ScreenHistoryMediaKind
    let legacyLocator: String
    let mediaFrameIndex: Int?
}

struct ScreenHistoryMediaMigrationLedgerEntry: Equatable, Sendable {
    let sourcePathHash: String
    let destinationLocator: String?
    let byteCount: Int64
    let contentHash: String?
    let status: ScreenHistoryMediaMigrationStatus
}

struct ScreenHistoryMediaMigrationStoreChange: Equatable, Sendable {
    let updatedRowDelta: Int
    let ledgerDelta: Int
}

struct ScreenHistoryMediaMigrationFailure: Equatable, Sendable {
    let sourcePathHash: String
    let status: ScreenHistoryMediaMigrationStatus
}

struct ScreenHistoryMediaMigrationResult: Equatable, Sendable {
    let sourceRows: Int
    let uniqueLocators: Int
    let copiedFileDelta: Int
    let hashDelta: Int
    let updatedRowDelta: Int
    let ledgerDelta: Int
    let failures: [ScreenHistoryMediaMigrationFailure]
    let lastFrameID: Int64?
}

actor ScreenHistoryMediaMigrationService {
    nonisolated static let maximumBatchRows = 1_000
    nonisolated static let maximumSampleMoments = 100

    private struct FileDigest: Equatable {
        let byteCount: Int64
        let sha256: String
    }

    private let store: SQLiteScreenHistoryStore
    private let legacyContentRootURL: URL
    private let ownedMediaDirectoryURL: URL
    private let fileManager: FileManager
    private let clock: @Sendable () -> Date
    private let afterCopy: (@Sendable (URL) throws -> Void)?

    static func defaultOwnedMediaDirectoryURL() -> URL {
        SQLiteScreenHistoryStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("Screen History Legacy Media", isDirectory: true)
    }

    init(
        store: SQLiteScreenHistoryStore,
        legacyContentRootURL: URL,
        ownedMediaDirectoryURL: URL = ScreenHistoryMediaMigrationService.defaultOwnedMediaDirectoryURL(),
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Date = Date.init,
        afterCopy: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.store = store
        self.legacyContentRootURL = legacyContentRootURL
        self.ownedMediaDirectoryURL = ownedMediaDirectoryURL
        self.fileManager = fileManager
        self.clock = clock
        self.afterCopy = afterCopy
    }

    /// Copies imported Coast media into storage owned by Quick Launch. Source
    /// files remain untouched. A cursor can resume a stopped row scan.
    func migrate(
        afterFrameID: Int64? = nil,
        maximumSourceRows: Int? = nil,
        batchSize: Int = 500
    ) async throws -> ScreenHistoryMediaMigrationResult {
        let boundedBatchSize = min(max(1, batchSize), Self.maximumBatchRows)
        let boundedMaximum = maximumSourceRows.map { max(0, $0) }
        var cursor = afterFrameID
        var sourceRows = 0
        var uniqueLocators = Set<String>()
        var copiedFileDelta = 0
        var hashDelta = 0
        var updatedRowDelta = 0
        var ledgerDelta = 0
        var failuresByPath: [String: ScreenHistoryMediaMigrationFailure] = [:]

        try prepareOwnedDirectory()

        while boundedMaximum.map({ sourceRows < $0 }) ?? true {
            let remaining = boundedMaximum.map { $0 - sourceRows } ?? boundedBatchSize
            let requestCount = min(boundedBatchSize, remaining)
            if requestCount <= 0 { break }
            let rows = try await store.legacyMediaMigrationRows(afterFrameID: cursor, limit: requestCount)
            if rows.isEmpty { break }
            sourceRows += rows.count
            cursor = rows.last?.frameID

            var grouped: [String: [ScreenHistoryMediaReference]] = [:]
            for row in rows {
                for reference in references(for: row) {
                    guard !isContained(reference.legacyLocator, by: ownedMediaDirectoryURL) else { continue }
                    grouped[reference.legacyLocator, default: []].append(reference)
                }
            }

            for locator in grouped.keys.sorted() {
                guard let references = grouped[locator] else { continue }
                uniqueLocators.insert(locator)
                let outcome = try await migrate(locator: locator, references: references)
                copiedFileDelta += outcome.copiedFileDelta
                hashDelta += outcome.hashDelta
                updatedRowDelta += outcome.updatedRowDelta
                ledgerDelta += outcome.ledgerDelta
                if let failure = outcome.failure {
                    failuresByPath[failure.sourcePathHash] = failure
                }
            }
            if rows.count < requestCount { break }
        }

        return ScreenHistoryMediaMigrationResult(
            sourceRows: sourceRows,
            uniqueLocators: uniqueLocators.count,
            copiedFileDelta: copiedFileDelta,
            hashDelta: hashDelta,
            updatedRowDelta: updatedRowDelta,
            ledgerDelta: ledgerDelta,
            failures: failuresByPath.values.sorted { $0.sourcePathHash < $1.sourcePathHash },
            lastFrameID: cursor
        )
    }

    /// Returns a deterministic, time-spread sample for a later human preview
    /// check. It reads metadata only and never opens personal media.
    func migratedMomentSample(limit: Int = maximumSampleMoments) async throws -> [ScreenHistoryFrame] {
        try await store.migratedMediaMomentSample(limit: min(max(1, limit), Self.maximumSampleMoments))
    }

    private struct LocatorOutcome {
        let copiedFileDelta: Int
        let hashDelta: Int
        let updatedRowDelta: Int
        let ledgerDelta: Int
        let failure: ScreenHistoryMediaMigrationFailure?
    }

    private func migrate(
        locator: String,
        references: [ScreenHistoryMediaReference]
    ) async throws -> LocatorOutcome {
        let unresolvedPathHash = Self.sha256(Data(locator.utf8))
        guard let sourceURL = resolvedSourceURL(locator) else {
            let change = try await store.recordMediaMigrationOutcome(
                sourcePathHash: unresolvedPathHash,
                destinationLocator: nil,
                byteCount: 0,
                contentHash: nil,
                status: .invalid,
                migratedAt: clock()
            )
            return LocatorOutcome(
                copiedFileDelta: 0,
                hashDelta: 0,
                updatedRowDelta: 0,
                ledgerDelta: change,
                failure: ScreenHistoryMediaMigrationFailure(sourcePathHash: unresolvedPathHash, status: .invalid)
            )
        }

        let sourcePathHash = Self.sha256(Data(sourceURL.path.utf8))
        if let ledger = try await store.mediaMigrationLedgerEntry(sourcePathHash: sourcePathHash),
           ledger.status == .copied,
           let destination = ledger.destinationLocator,
           let expectedHash = ledger.contentHash {
            // A copied ledger is not enough proof. Re-hash the frozen Coast
            // source on every fast-path use and require it to still match the
            // immutable hash that originally produced the owned copy.
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                return LocatorOutcome(
                    copiedFileDelta: 0,
                    hashDelta: 0,
                    updatedRowDelta: 0,
                    ledgerDelta: 0,
                    failure: ScreenHistoryMediaMigrationFailure(
                        sourcePathHash: sourcePathHash,
                        status: .missing
                    )
                )
            }
            guard isRegularFile(sourceURL) else {
                return LocatorOutcome(
                    copiedFileDelta: 0,
                    hashDelta: 0,
                    updatedRowDelta: 0,
                    ledgerDelta: 0,
                    failure: ScreenHistoryMediaMigrationFailure(
                        sourcePathHash: sourcePathHash,
                        status: .invalid
                    )
                )
            }
            let sourceDigest: FileDigest
            do {
                sourceDigest = try digest(sourceURL)
            } catch {
                return LocatorOutcome(
                    copiedFileDelta: 0,
                    hashDelta: 0,
                    updatedRowDelta: 0,
                    ledgerDelta: 0,
                    failure: ScreenHistoryMediaMigrationFailure(
                        sourcePathHash: sourcePathHash,
                        status: .failed
                    )
                )
            }
            guard sourceDigest.byteCount == ledger.byteCount,
                  sourceDigest.sha256 == expectedHash
            else {
                // Keep the last proven copied ledger intact. This makes a
                // changed Coast source fail on every retry instead of silently
                // replacing the owned copy with new bytes.
                return LocatorOutcome(
                    copiedFileDelta: 0,
                    hashDelta: 1,
                    updatedRowDelta: 0,
                    ledgerDelta: 0,
                    failure: ScreenHistoryMediaMigrationFailure(
                        sourcePathHash: sourcePathHash,
                        status: .hashMismatch
                    )
                )
            }
            let destinationURL = URL(fileURLWithPath: destination)
            guard isContained(destination, by: ownedMediaDirectoryURL),
                  !isSymbolicLink(destinationURL),
                  isRegularFile(destinationURL)
            else {
                let change = try await store.recordMediaMigrationOutcome(
                    sourcePathHash: sourcePathHash,
                    destinationLocator: destination,
                    byteCount: ledger.byteCount,
                    contentHash: expectedHash,
                    status: .invalid,
                    migratedAt: clock()
                )
                return LocatorOutcome(
                    copiedFileDelta: 0,
                    hashDelta: 1,
                    updatedRowDelta: 0,
                    ledgerDelta: change,
                    failure: ScreenHistoryMediaMigrationFailure(
                        sourcePathHash: sourcePathHash,
                        status: .invalid
                    )
                )
            }

            let destinationDigest: FileDigest
            do {
                destinationDigest = try digest(destinationURL)
            } catch {
                let change = try await store.recordMediaMigrationOutcome(
                    sourcePathHash: sourcePathHash,
                    destinationLocator: destination,
                    byteCount: ledger.byteCount,
                    contentHash: expectedHash,
                    status: .failed,
                    migratedAt: clock()
                )
                return LocatorOutcome(
                    copiedFileDelta: 0,
                    hashDelta: 1,
                    updatedRowDelta: 0,
                    ledgerDelta: change,
                    failure: ScreenHistoryMediaMigrationFailure(
                        sourcePathHash: sourcePathHash,
                        status: .failed
                    )
                )
            }
            guard destinationDigest.byteCount == ledger.byteCount,
                  destinationDigest.sha256 == expectedHash
            else {
                let change = try await store.recordMediaMigrationOutcome(
                    sourcePathHash: sourcePathHash,
                    destinationLocator: destination,
                    byteCount: destinationDigest.byteCount,
                    contentHash: destinationDigest.sha256,
                    status: .hashMismatch,
                    migratedAt: clock()
                )
                return LocatorOutcome(
                    copiedFileDelta: 0,
                    hashDelta: 2,
                    updatedRowDelta: 0,
                    ledgerDelta: change,
                    failure: ScreenHistoryMediaMigrationFailure(
                        sourcePathHash: sourcePathHash,
                        status: .hashMismatch
                    )
                )
            }

            var rowDelta = 0
            var localLedgerDelta = 0
            for reference in references {
                let change = try await store.updateImportedMediaLocator(
                    reference,
                    destinationLocator: destination,
                    byteCount: destinationDigest.byteCount,
                    contentHash: destinationDigest.sha256,
                    sourcePathHash: sourcePathHash,
                    migratedAt: clock()
                )
                rowDelta += change.updatedRowDelta
                localLedgerDelta += change.ledgerDelta
            }
            return LocatorOutcome(
                copiedFileDelta: 0,
                hashDelta: 2,
                updatedRowDelta: rowDelta,
                ledgerDelta: localLedgerDelta,
                failure: nil
            )
        }

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            let change = try await store.recordMediaMigrationOutcome(
                sourcePathHash: sourcePathHash,
                destinationLocator: nil,
                byteCount: 0,
                contentHash: nil,
                status: .missing,
                migratedAt: clock()
            )
            return LocatorOutcome(
                copiedFileDelta: 0,
                hashDelta: 0,
                updatedRowDelta: 0,
                ledgerDelta: change,
                failure: ScreenHistoryMediaMigrationFailure(sourcePathHash: sourcePathHash, status: .missing)
            )
        }

        guard isRegularFile(sourceURL) else {
            let change = try await store.recordMediaMigrationOutcome(
                sourcePathHash: sourcePathHash,
                destinationLocator: nil,
                byteCount: 0,
                contentHash: nil,
                status: .invalid,
                migratedAt: clock()
            )
            return LocatorOutcome(
                copiedFileDelta: 0,
                hashDelta: 0,
                updatedRowDelta: 0,
                ledgerDelta: change,
                failure: ScreenHistoryMediaMigrationFailure(sourcePathHash: sourcePathHash, status: .invalid)
            )
        }

        var hashDelta = 0
        let sourceDigest: FileDigest
        do {
            sourceDigest = try digest(sourceURL)
            hashDelta += 1
        } catch {
            let change = try await store.recordMediaMigrationOutcome(
                sourcePathHash: sourcePathHash,
                destinationLocator: nil,
                byteCount: 0,
                contentHash: nil,
                status: .failed,
                migratedAt: clock()
            )
            return LocatorOutcome(
                copiedFileDelta: 0,
                hashDelta: hashDelta,
                updatedRowDelta: 0,
                ledgerDelta: change,
                failure: ScreenHistoryMediaMigrationFailure(sourcePathHash: sourcePathHash, status: .failed)
            )
        }

        let destinationURL = destinationURL(for: sourceURL, sourcePathHash: sourcePathHash)
        let temporaryURL = ownedMediaDirectoryURL
            .appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: false)
        var copiedFileDelta = 0
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                guard !isSymbolicLink(destinationURL),
                      isContained(destinationURL.path, by: ownedMediaDirectoryURL)
                else {
                    let change = try await store.recordMediaMigrationOutcome(
                        sourcePathHash: sourcePathHash,
                        destinationLocator: destinationURL.path,
                        byteCount: sourceDigest.byteCount,
                        contentHash: sourceDigest.sha256,
                        status: .invalid,
                        migratedAt: clock()
                    )
                    return LocatorOutcome(
                        copiedFileDelta: 0,
                        hashDelta: hashDelta,
                        updatedRowDelta: 0,
                        ledgerDelta: change,
                        failure: ScreenHistoryMediaMigrationFailure(
                            sourcePathHash: sourcePathHash,
                            status: .invalid
                        )
                    )
                }
                let existingDigest = try digest(destinationURL)
                hashDelta += 1
                if existingDigest == sourceDigest {
                    return try await finishVerifiedCopy(
                        references: references,
                        destinationURL: destinationURL,
                        sourcePathHash: sourcePathHash,
                        digest: sourceDigest,
                        copiedFileDelta: 0,
                        hashDelta: hashDelta
                    )
                }
            }

            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            copiedFileDelta = 1
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            try afterCopy?(temporaryURL)
            let copiedDigest = try digest(temporaryURL)
            hashDelta += 1
            guard copiedDigest == sourceDigest else {
                try? fileManager.removeItem(at: temporaryURL)
                let change = try await store.recordMediaMigrationOutcome(
                    sourcePathHash: sourcePathHash,
                    destinationLocator: destinationURL.path,
                    byteCount: copiedDigest.byteCount,
                    contentHash: copiedDigest.sha256,
                    status: .hashMismatch,
                    migratedAt: clock()
                )
                return LocatorOutcome(
                    copiedFileDelta: copiedFileDelta,
                    hashDelta: hashDelta,
                    updatedRowDelta: 0,
                    ledgerDelta: change,
                    failure: ScreenHistoryMediaMigrationFailure(sourcePathHash: sourcePathHash, status: .hashMismatch)
                )
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
            return try await finishVerifiedCopy(
                references: references,
                destinationURL: destinationURL,
                sourcePathHash: sourcePathHash,
                digest: sourceDigest,
                copiedFileDelta: copiedFileDelta,
                hashDelta: hashDelta
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            let change = try await store.recordMediaMigrationOutcome(
                sourcePathHash: sourcePathHash,
                destinationLocator: destinationURL.path,
                byteCount: sourceDigest.byteCount,
                contentHash: sourceDigest.sha256,
                status: .failed,
                migratedAt: clock()
            )
            return LocatorOutcome(
                copiedFileDelta: copiedFileDelta,
                hashDelta: hashDelta,
                updatedRowDelta: 0,
                ledgerDelta: change,
                failure: ScreenHistoryMediaMigrationFailure(sourcePathHash: sourcePathHash, status: .failed)
            )
        }
    }

    private func finishVerifiedCopy(
        references: [ScreenHistoryMediaReference],
        destinationURL: URL,
        sourcePathHash: String,
        digest: FileDigest,
        copiedFileDelta: Int,
        hashDelta: Int
    ) async throws -> LocatorOutcome {
        var rowDelta = 0
        var ledgerDelta = 0
        for reference in references {
            let change = try await store.updateImportedMediaLocator(
                reference,
                destinationLocator: destinationURL.path,
                byteCount: digest.byteCount,
                contentHash: digest.sha256,
                sourcePathHash: sourcePathHash,
                migratedAt: clock()
            )
            rowDelta += change.updatedRowDelta
            ledgerDelta += change.ledgerDelta
        }
        return LocatorOutcome(
            copiedFileDelta: copiedFileDelta,
            hashDelta: hashDelta,
            updatedRowDelta: rowDelta,
            ledgerDelta: ledgerDelta,
            failure: nil
        )
    }

    private func references(for row: ScreenHistoryMediaMigrationRow) -> [ScreenHistoryMediaReference] {
        var result: [ScreenHistoryMediaReference] = []
        if let imageLocator = row.imageLocator, !imageLocator.isEmpty {
            result.append(ScreenHistoryMediaReference(
                frameID: row.frameID,
                sourceIdentifier: row.sourceIdentifier,
                kind: .image,
                legacyLocator: imageLocator,
                mediaFrameIndex: nil
            ))
        }
        if let mediaLocator = row.mediaLocator, !mediaLocator.isEmpty {
            result.append(ScreenHistoryMediaReference(
                frameID: row.frameID,
                sourceIdentifier: row.sourceIdentifier,
                kind: .video,
                legacyLocator: mediaLocator,
                mediaFrameIndex: row.mediaFrameIndex
            ))
        }
        return result
    }

    private func prepareOwnedDirectory() throws {
        if fileManager.fileExists(atPath: ownedMediaDirectoryURL.path),
           isSymbolicLink(ownedMediaDirectoryURL) {
            throw ScreenHistoryMediaMigrationError.ownedMediaRootIsSymbolicLink
        }
        try fileManager.createDirectory(at: ownedMediaDirectoryURL, withIntermediateDirectories: true)
        guard !isSymbolicLink(ownedMediaDirectoryURL) else {
            throw ScreenHistoryMediaMigrationError.ownedMediaRootIsSymbolicLink
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ownedMediaDirectoryURL.path)
    }

    private func resolvedSourceURL(_ locator: String) -> URL? {
        guard locator.hasPrefix("/") else { return nil }
        let root = legacyContentRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let source = URL(fileURLWithPath: locator).standardizedFileURL.resolvingSymlinksInPath()
        guard source.path != root.path, isContained(source.path, by: root) else { return nil }
        return source
    }

    private func isContained(_ path: String, by rootURL: URL) -> Bool {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return candidate.hasPrefix(root + "/")
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeRegular
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        guard result == 0 else { return false }
        return (information.st_mode & S_IFMT) == S_IFLNK
    }

    private func destinationURL(for sourceURL: URL, sourcePathHash: String) -> URL {
        let rawExtension = sourceURL.pathExtension.lowercased()
        let safeExtension = !rawExtension.isEmpty && rawExtension.count <= 12
            && rawExtension.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            ? rawExtension : "bin"
        return ownedMediaDirectoryURL.appendingPathComponent("\(sourcePathHash).\(safeExtension)")
    }

    private func digest(_ url: URL) throws -> FileDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
            byteCount += Int64(data.count)
        }
        return FileDigest(
            byteCount: byteCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
