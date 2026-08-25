import CryptoKit
import Darwin
import Foundation
import SQLite3
import Testing
@testable import QuickLaunch

@Suite("Screen History Coast freeze receipt", .serialized)
struct ScreenHistoryCoastFreezeReceiptServiceTests {
    @Test("content-free primary manifest records database structure, populations, dates, and file families")
    func primaryManifest() async throws {
        let fixture = try CoastFreezeFixture()
        let service = try fixture.service()
        let before = try fixture.sourceSnapshot()

        let progress = try await service.makePrimaryReceipt(maximumNewFiles: nil)
        let receipt = try #require(progress.receipt)

        #expect(progress.isComplete)
        #expect(progress.processedFiles == progress.totalFiles)
        #expect(receipt.approvalState == .awaitingRollbackHold)
        #expect(receipt.primary.database.relativePath == "rem.db")
        let expectedDatabaseHash = try fixture.sha256(fixture.databaseURL)
        #expect(receipt.primary.database.sha256 == expectedDatabaseHash)
        #expect(receipt.primary.database.schema.userVersion == 7)
        #expect(receipt.primary.database.schema.applicationID == 42)
        #expect(receipt.primary.database.schema.schemaSHA256.count == 64)
        #expect(receipt.primary.database.schema.tableCount >= 5)
        #expect(receipt.primary.database.schema.indexCount == 1)
        #expect(receipt.primary.database.schema.triggerCount == 1)
        #expect(receipt.primary.database.schema.viewCount == 1)
        #expect(receipt.primary.database.counts.frames == 2)
        #expect(receipt.primary.database.counts.videos == 1)
        #expect(receipt.primary.database.counts.segments == 1)
        #expect(receipt.primary.database.counts.ocrBoxes == 2)
        #expect(receipt.primary.database.counts.accessibilitySnapshots == 1)
        #expect(receipt.primary.database.counts.applications == 2)
        #expect(receipt.primary.database.counts.domains == 1)
        #expect(receipt.primary.database.earliestFrameAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(receipt.primary.database.latestFrameAt == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(receipt.primary.manifestSHA256.count == 64)
        #expect(receipt.receiptHMACSHA256.count == 64)
        #expect(receipt.primary.runtimeExclusions == ScreenHistoryCoastRuntimeExclusion.allCases)

        let files = receipt.primary.files
        #expect(files.map(\.relativePath) == files.map(\.relativePath).sorted())
        #expect(files.allSatisfy { !$0.relativePath.hasPrefix("/") && !$0.relativePath.contains("..") })
        #expect(!files.contains { $0.relativePath == "cli.sock" || $0.relativePath == "rem.db-shm" })
        #expect(files.first(where: { $0.relativePath == "frames/fresh.heic" })?.family == .frames)
        #expect(files.first(where: { $0.relativePath == "videos/block.mp4" })?.family == .videos)
        #expect(files.first(where: { $0.relativePath == "icons/site.png" })?.family == .icons)
        #expect(files.first(where: { $0.relativePath == "tfidf_cache.json" })?.family == .support)
        #expect(receipt.primary.families.first(where: { $0.family == .frames })?.fileCount == 1)
        #expect(receipt.primary.families.first(where: { $0.family == .videos })?.fileCount == 1)
        #expect(receipt.primary.families.first(where: { $0.family == .icons })?.fileCount == 1)
        #expect(receipt.primary.families.first(where: { $0.family == .support })?.fileCount == 1)

        let persisted = try String(contentsOf: service.receiptURL, encoding: .utf8)
        for forbidden in [
            fixture.root.path,
            "Confidential merger title",
            "https://secret.example/private",
            "unpublished product codename",
            "private OCR phrase",
            "Secret App One",
            "secret.example",
        ] {
            #expect(!persisted.contains(forbidden))
        }
        #expect(try fixture.permissions(service.receiptDirectoryURL) == 0o700)
        #expect(try fixture.permissions(service.receiptURL) == 0o600)
        #expect(try fixture.permissions(service.primaryCheckpointURL) == 0o600)
        #expect(try fixture.sourceSnapshot() == before)

        let repeated = try await service.makePrimaryReceipt(maximumNewFiles: 0)
        #expect(repeated.receipt?.receiptHMACSHA256 == receipt.receiptHMACSHA256)
    }

    @Test("bounded checkpoints resume without re-hashing completed source files")
    func resumableScan() async throws {
        let fixture = try CoastFreezeFixture(largeMedia: true)
        var service = try fixture.service()

        let first = try await service.makePrimaryReceipt(maximumNewFiles: 2)
        #expect(!first.isComplete)
        #expect(first.processedFiles == 2)
        #expect(first.totalFiles == 5)
        #expect(first.receipt == nil)

        service = try fixture.service()
        let second = try await service.makePrimaryReceipt(maximumNewFiles: 2)
        #expect(!second.isComplete)
        #expect(second.processedFiles == 4)

        service = try fixture.service()
        let final = try await service.makePrimaryReceipt(maximumNewFiles: 1)
        let receipt = try #require(final.receipt)
        #expect(final.isComplete)
        #expect(final.processedFiles == 5)
        let expectedVideoHash = try fixture.sha256(fixture.videoURL)
        #expect(receipt.primary.files.first(where: {
            $0.relativePath == "videos/block.mp4"
        })?.sha256 == expectedVideoHash)
        #expect(ScreenHistoryCoastFreezeReceiptService.streamingChunkByteCount == 1_048_576)

        let checkpointText = try String(contentsOf: service.primaryCheckpointURL, encoding: .utf8)
        #expect(!checkpointText.contains(fixture.root.path))
        #expect(!checkpointText.contains("private OCR phrase"))
    }

    @Test("rollback hold precedes the independent check and retirement approval stays explicit")
    func secondCheckHoldAndApproval() async throws {
        let fixture = try CoastFreezeFixture()
        let clock = MutableFreezeClock(Date(timeIntervalSince1970: 2_000_000_000))
        let service = try fixture.service(clock: { clock.now() }, rollbackHoldDays: 30)
        let primary = try #require(
            try await service.makePrimaryReceipt(maximumNewFiles: nil).receipt
        )

        var missingHold: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try await service.performSecondCheck(maximumNewFiles: nil)
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            missingHold = error
        }
        #expect(missingHold == .rollbackHoldRequired)

        var writableError: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try await service.beginRollbackHold(
                expectedReceiptHMACSHA256: primary.receiptHMACSHA256
            )
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            writableError = error
        }
        #expect(writableError == .sourceIsNotReadOnly)
        try fixture.makeSourceReadOnly()
        let holding = try await service.beginRollbackHold(
            expectedReceiptHMACSHA256: primary.receiptHMACSHA256
        )
        #expect(holding.rollbackHoldStartedAt == clock.now())
        #expect(holding.rollbackHoldUntil == clock.now().addingTimeInterval(30 * 86_400))
        #expect(holding.approvalState == .awaitingSecondCheck)

        var activeHold: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try await service.performSecondCheck(maximumNewFiles: nil)
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            activeHold = error
        }
        #expect(activeHold == .rollbackHoldActive)

        clock.advance(days: 31)
        let checked = try #require(
            try await service.performSecondCheck(maximumNewFiles: nil).receipt
        )
        #expect(checked.secondCheckMatched)
        #expect(checked.secondCheckManifestSHA256 == primary.primary.manifestSHA256)
        #expect(checked.rollbackHoldStartedAt == holding.rollbackHoldStartedAt)
        #expect(checked.rollbackHoldUntil == holding.rollbackHoldUntil)
        #expect(checked.approvalState == .notApproved)

        let ready = try await service.recordRetirementApproval(
            expectedReceiptHMACSHA256: checked.receiptHMACSHA256,
            approved: true
        )
        #expect(ready.approvalState == .approvedForRetirement)
        #expect(ready.approvalRecordedAt == clock.now())

        var staleError: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try await service.recordRetirementApproval(
                expectedReceiptHMACSHA256: checked.receiptHMACSHA256,
                approved: false
            )
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            staleError = error
        }
        #expect(staleError == .staleReceipt)

        let revoked = try await service.recordRetirementApproval(
            expectedReceiptHMACSHA256: ready.receiptHMACSHA256,
            approved: false
        )
        #expect(revoked.approvalState == .revoked)
    }

    @Test("a changed Coast source fails the second comparison and blocks approval")
    func mismatchBlocksApproval() async throws {
        let fixture = try CoastFreezeFixture()
        let clock = MutableFreezeClock(Date(timeIntervalSince1970: 2_000_000_000))
        let service = try fixture.service(clock: { clock.now() }, rollbackHoldDays: 14)
        let primary = try #require(
            try await service.makePrimaryReceipt(maximumNewFiles: nil).receipt
        )
        try fixture.makeSourceReadOnly()
        _ = try await service.beginRollbackHold(
            expectedReceiptHMACSHA256: primary.receiptHMACSHA256
        )
        clock.advance(days: 15)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.videoURL.path
        )
        try Data("changed-video-same-source".utf8).write(to: fixture.videoURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: fixture.videoURL.path
        )

        let checked = try #require(
            try await service.performSecondCheck(maximumNewFiles: nil).receipt
        )
        #expect(!checked.secondCheckMatched)
        #expect(checked.rollbackHoldStartedAt != nil)
        #expect(checked.rollbackHoldUntil != nil)
        #expect(checked.approvalState == .awaitingSecondCheck)

        var received: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try await service.recordRetirementApproval(
                expectedReceiptHMACSHA256: checked.receiptHMACSHA256,
                approved: true
            )
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            received = error
        }
        #expect(received == .secondCheckMismatch)
    }

    @Test("receipt edits are detected before state is returned")
    func tamperEvidence() async throws {
        let fixture = try CoastFreezeFixture()
        var service = try fixture.service()
        _ = try await service.makePrimaryReceipt(maximumNewFiles: nil)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: service.receiptURL)) as? [String: Any]
        )
        let payload = try #require(object["payload"] as? [String: Any])
        let forgedPlainHash = SHA256.hash(data: try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )).map { String(format: "%02x", $0) }.joined()
        object["receiptHMACSHA256"] = forgedPlainHash
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: service.receiptURL, options: .atomic)
        service = try fixture.serviceWithoutInitValidation()

        var received: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try await service.currentReceipt()
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            received = error
        }
        #expect(received == .corruptedReceipt)
    }

    @Test("a symlinked source root, escaping child, or receipt location fails closed")
    func symlinkSafety() async throws {
        let fixture = try CoastFreezeFixture()
        let rootLink = fixture.directory.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: fixture.root)
        var rootError: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try ScreenHistoryCoastFreezeReceiptService(
                coastRootURL: rootLink,
                receiptDirectoryURL: fixture.directory.appendingPathComponent("root-link-receipt")
            )
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            rootError = error
        }
        #expect(rootError == .unsafeSource)

        let outside = fixture.directory.appendingPathComponent("outside.mp4")
        try Data("outside".utf8).write(to: outside)
        let escape = fixture.root.appendingPathComponent("videos/escape.mp4")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        let service = try fixture.service()
        var childError: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try await service.makePrimaryReceipt(maximumNewFiles: nil)
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            childError = error
        }
        #expect(childError == .unsafeSource)

        let realReceipt = fixture.directory.appendingPathComponent("real-receipt", isDirectory: true)
        try FileManager.default.createDirectory(at: realReceipt, withIntermediateDirectories: true)
        let receiptLink = fixture.directory.appendingPathComponent("receipt-link")
        try FileManager.default.createSymbolicLink(at: receiptLink, withDestinationURL: realReceipt)
        var receiptError: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try ScreenHistoryCoastFreezeReceiptService(
                coastRootURL: fixture.root,
                receiptDirectoryURL: receiptLink
            )
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            receiptError = error
        }
        #expect(receiptError == .unsafeReceiptStorage)
    }

    @Test("an active Coast process blocks every source scan")
    func activeProcessFailsClosed() async throws {
        let fixture = try CoastFreezeFixture()
        let service = try fixture.service(processIsRunning: { true })

        var received: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try await service.makePrimaryReceipt(maximumNewFiles: nil)
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            received = error
        }
        #expect(received == .sourceIsActive)
    }

    @Test("approval performs a fresh check and a later Coast restart revokes cached approval")
    func approvalIsBoundToFreshSourceProof() async throws {
        let fixture = try CoastFreezeFixture()
        let clock = MutableFreezeClock(Date(timeIntervalSince1970: 2_000_000_000))
        let running = MutableFreezeFlag(false)
        let service = try fixture.service(
            clock: { clock.now() },
            rollbackHoldDays: 14,
            processIsRunning: { running.value() }
        )
        let primary = try #require(
            try await service.makePrimaryReceipt(maximumNewFiles: nil).receipt
        )
        try fixture.makeSourceReadOnly()
        _ = try await service.beginRollbackHold(
            expectedReceiptHMACSHA256: primary.receiptHMACSHA256
        )
        clock.advance(days: 15)
        let checked = try #require(
            try await service.performSecondCheck(maximumNewFiles: nil).receipt
        )
        #expect(checked.secondCheckMatched)

        running.set(true)
        var activeError: ScreenHistoryCoastFreezeReceiptError?
        do {
            _ = try await service.recordRetirementApproval(
                expectedReceiptHMACSHA256: checked.receiptHMACSHA256,
                approved: true
            )
        } catch let error as ScreenHistoryCoastFreezeReceiptError {
            activeError = error
        }
        #expect(activeError == .sourceIsActive)
        #expect(try await service.currentReceipt()?.approvalState == .notApproved)

        running.set(false)
        let approved = try await service.recordRetirementApproval(
            expectedReceiptHMACSHA256: checked.receiptHMACSHA256,
            approved: true
        )
        #expect(approved.approvalState == .approvedForRetirement)

        running.set(true)
        let invalidated = try #require(try await service.currentReceipt())
        #expect(invalidated.approvalState == .revoked)
        #expect(invalidated.receiptHMACSHA256 != approved.receiptHMACSHA256)
    }

    @Test("owner-only integrity fallback is stable and fails closed on weak permissions")
    func ownerOnlyIntegrityFallback() throws {
        let fixture = try CoastFreezeFixture()
        let directory = fixture.directory.appendingPathComponent("fallback-key", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent(".integrity-key")

        let first = try ScreenHistoryCoastFreezeReceiptService
            .loadOrCreateOwnerOnlyIntegrityKeyForTesting(at: url)
        let second = try ScreenHistoryCoastFreezeReceiptService
            .loadOrCreateOwnerOnlyIntegrityKeyForTesting(at: url)
        let firstData = first.withUnsafeBytes {
            Data(bytes: $0.baseAddress!, count: $0.count)
        }
        let secondData = second.withUnsafeBytes {
            Data(bytes: $0.baseAddress!, count: $0.count)
        }
        #expect(firstData.count == 32)
        #expect(firstData == secondData)
        #expect(try fixture.permissions(url) == 0o600)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
        #expect(throws: ScreenHistoryCoastFreezeReceiptError.unsafeReceiptStorage) {
            _ = try ScreenHistoryCoastFreezeReceiptService
                .loadOrCreateOwnerOnlyIntegrityKeyForTesting(at: url)
        }
    }

    @Test("synthetic workspaces remove themselves after their fixture is released")
    func fixtureCleanup() throws {
        var fixture: CoastFreezeFixture? = try CoastFreezeFixture()
        let directory = try #require(fixture?.directory)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        _ = try fixture?.service()

        fixture = nil

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

private final class MutableFreezeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(days: Int) {
        lock.withLock { value = value.addingTimeInterval(TimeInterval(days * 86_400)) }
    }
}

private final class MutableFreezeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ stored: Bool) { self.stored = stored }

    func value() -> Bool { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}

private final class CoastFreezeFixture {
    private static let integrityKey = Data(repeating: 0x42, count: 32)

    let directory: URL
    let root: URL
    let receipts: URL
    let databaseURL: URL
    let videoURL: URL

    init(largeMedia: Bool = false) throws {
        directory = try Self.makeTemporaryDirectory()
        root = directory.appendingPathComponent("coast", isDirectory: true)
        receipts = directory.appendingPathComponent("receipts", isDirectory: true)
        databaseURL = root.appendingPathComponent("rem.db")
        videoURL = root.appendingPathComponent("videos/block.mp4")
        for name in ["frames", "videos", "icons"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Self.makeDatabase(databaseURL)
        try Data("fresh-frame".utf8).write(to: root.appendingPathComponent("frames/fresh.heic"))
        let video = largeMedia
            ? Data(repeating: 0xA7, count: ScreenHistoryCoastFreezeReceiptService.streamingChunkByteCount * 3 + 17)
            : Data("video-block".utf8)
        try video.write(to: videoURL)
        try Data("site-icon".utf8).write(to: root.appendingPathComponent("icons/site.png"))
        try Data("cache-support".utf8).write(to: root.appendingPathComponent("tfidf_cache.json"))
        try Data("runtime-shared-memory".utf8).write(to: root.appendingPathComponent("rem.db-shm"))
        try Self.makeUnixSocket(root.appendingPathComponent("cli.sock"))
    }

    deinit {
        Self.makeWritableForCleanup(directory)
        try? FileManager.default.removeItem(at: directory)
    }

    func service(
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 2_000_000_000) },
        rollbackHoldDays: Int = 30,
        processIsRunning: @escaping @Sendable () -> Bool = { false }
    ) throws -> ScreenHistoryCoastFreezeReceiptService {
        try ScreenHistoryCoastFreezeReceiptService(
            coastRootURL: root,
            receiptDirectoryURL: receipts,
            rollbackHoldDays: rollbackHoldDays,
            clock: clock,
            coastProcessIsRunning: processIsRunning,
            integrityKeyData: Self.integrityKey
        )
    }

    /// The normal initializer validates immediately. This helper preserves the
    /// same path but delays the expected corruption check to the test call by
    /// first moving the bad bytes aside and restoring them after construction.
    func serviceWithoutInitValidation() throws -> ScreenHistoryCoastFreezeReceiptService {
        let bad = try Data(contentsOf: receipts.appendingPathComponent("coast-freeze-receipt.json"))
        let validURL = receipts.appendingPathComponent("coast-freeze-receipt.json")
        try FileManager.default.moveItem(
            at: validURL,
            to: receipts.appendingPathComponent("bad-receipt-hold")
        )
        let service = try ScreenHistoryCoastFreezeReceiptService(
            coastRootURL: root,
            receiptDirectoryURL: receipts,
            coastProcessIsRunning: { false },
            integrityKeyData: Self.integrityKey
        )
        try bad.write(to: validURL, options: .atomic)
        return service
    }

    func sourceSnapshot() throws -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        )
        for case let url as URL in enumerator {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result[relative] = [
                Int64(metadata.st_size),
                Int64(metadata.st_mtimespec.tv_sec),
                Int64(metadata.st_mtimespec.tv_nsec),
            ]
        }
        return result
    }

    func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int) & 0o777
    }

    func makeSourceReadOnly() throws {
        let manager = FileManager.default
        let enumerator = try #require(
            manager.enumerator(at: root, includingPropertiesForKeys: nil)
        )
        var directories: [URL] = []
        for case let url as URL in enumerator {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { continue }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                directories.append(url)
            } else if url.lastPathComponent != "cli.sock"
                        && url.lastPathComponent != "rem.db-shm" {
                try manager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            }
        }
        for directory in directories.reversed() {
            try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        }
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    }

    func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func makeDatabase(_ url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        let sql = """
            PRAGMA user_version = 7;
            PRAGMA application_id = 42;
            CREATE TABLE video(id INTEGER PRIMARY KEY, path TEXT, num_frames INTEGER, size_bytes INTEGER);
            CREATE TABLE segment(id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE frame(
                id INTEGER PRIMARY KEY, timestamp INTEGER NOT NULL, video INTEGER,
                image_path TEXT, title TEXT, segment INTEGER
            );
            CREATE TABLE ocr(id INTEGER PRIMARY KEY, frame INTEGER, secret_text TEXT);
            CREATE TABLE ax_snapshot(frame_id INTEGER PRIMARY KEY, root_hash BLOB);
            CREATE TABLE application(id INTEGER PRIMARY KEY, bundle_id TEXT, display_name TEXT);
            CREATE TABLE domain(id INTEGER PRIMARY KEY, normalized_domain TEXT);
            CREATE INDEX idx_frame_timestamp ON frame(timestamp);
            CREATE TRIGGER frame_audit AFTER INSERT ON frame BEGIN SELECT 1; END;
            CREATE VIEW frame_count_view AS SELECT COUNT(*) AS count FROM frame;
            INSERT INTO video VALUES(1, 'videos/block.mp4', 2, 11);
            INSERT INTO segment VALUES(1, 'https://secret.example/private');
            INSERT INTO frame VALUES(1, 1700000000000, 1, NULL, 'Confidential merger title', 1);
            INSERT INTO frame VALUES(2, 1700000100000, NULL, 'frames/fresh.heic', 'unpublished product codename', 1);
            INSERT INTO ocr VALUES(1, 1, 'private OCR phrase');
            INSERT INTO ocr VALUES(2, 2, 'private OCR phrase two');
            INSERT INTO ax_snapshot VALUES(1, X'0102');
            INSERT INTO application VALUES(1, 'com.secret.one', 'Secret App One');
            INSERT INTO application VALUES(2, 'com.secret.two', 'Secret App Two');
            INSERT INTO domain VALUES(1, 'secret.example');
            """
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(error)
            throw NSError(domain: "CoastFreezeFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        var template = Array("/private/tmp/quick-launch-coast-freeze.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw CocoaError(.fileWriteUnknown) }
        return URL(fileURLWithPath: String(cString: template), isDirectory: true)
    }

    private static func makeUnixSocket(_ url: URL) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8) + [0]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: path)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func makeWritableForCleanup(_ directory: URL) {
        let manager = FileManager.default
        if let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            var directories: [URL] = []
            for case let url as URL in enumerator {
                var metadata = stat()
                guard lstat(url.path, &metadata) == 0 else { continue }
                let kind = metadata.st_mode & S_IFMT
                if kind == S_IFLNK {
                    continue
                } else if kind == S_IFDIR {
                    directories.append(url)
                } else {
                    try? manager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: url.path
                    )
                }
            }
            for url in directories.reversed() {
                try? manager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: url.path
                )
            }
        }
        try? manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }
}
