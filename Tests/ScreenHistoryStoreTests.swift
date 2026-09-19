import Foundation
import SQLite3
import Testing
@testable import QuickLaunch

@Suite("Screen history store")
struct ScreenHistoryStoreTests {
    @Test func fullTextSearchAndFiltersStayLocalAndDeterministic() async throws {
        let fixture = try Fixture()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        _ = try await store.record([
            frame("1", at: 100, app: "Browser", domain: "example.com", text: "alpha launch notes", bytes: 10),
            frame("2", at: 200, app: "Editor", domain: nil, text: "alpha code review", bytes: 20),
            frame("3", at: 300, app: "Browser", domain: "other.test", text: "unrelated", bytes: 30),
        ])

        let textMatches = try await store.search(ScreenHistorySearchQuery(text: "alpha"))
        #expect(textMatches.map(\.sourceIdentifier) == ["2", "1"])

        let filtered = try await store.search(ScreenHistorySearchQuery(
            text: "alpha",
            from: Date(timeIntervalSince1970: 50),
            through: Date(timeIntervalSince1970: 150),
            application: "browser",
            domain: "EXAMPLE.COM"
        ))
        #expect(filtered.map(\.sourceIdentifier) == ["1"])
    }

    @Test func userTextCannotChangeTheSQLOrFTSQueryShape() async throws {
        let fixture = try Fixture()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        _ = try await store.record(frame("safe", at: 100, app: "Editor", text: "ordinary content"))

        let matches = try await store.search(ScreenHistorySearchQuery(text: "' OR 1=1; DROP TABLE screen_history_frame; --"))
        #expect(matches.isEmpty)
        #expect(try await store.count() == 1)
        #expect(try await store.search(ScreenHistorySearchQuery(text: "ordinary")).count == 1)
    }

    @Test func stableSourceIdentityMakesImportsIdempotent() async throws {
        let fixture = try Fixture()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        _ = try await store.record(frame("same", at: 100, app: "First", text: "old"))
        _ = try await store.record(frame("same", at: 200, app: "Second", text: "new"))

        #expect(try await store.count() == 1)
        let result = try await store.search(ScreenHistorySearchQuery(text: "new"))
        #expect(result.first?.application == "Second")
        #expect(result.first?.capturedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func retentionDeletesOwnedFilesBeforeRowsAndFTSContent() async throws {
        let fixture = try Fixture()
        let ownedRoot = fixture.directory.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
        let expiredFile = ownedRoot.appendingPathComponent("old.heic")
        try Data("old".utf8).write(to: expiredFile)
        let middleFile = ownedRoot.appendingPathComponent("middle.heic")
        try Data("mid".utf8).write(to: middleFile)
        let newFile = ownedRoot.appendingPathComponent("new.heic")
        try Data("new".utf8).write(to: newFile)
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot]
        )
        let day = 86_400.0
        _ = try await store.record([
            frame("expired", at: day, text: "expired searchable words", image: expiredFile.path, bytes: 40),
            frame("middle", at: 9 * day, text: "middle", image: middleFile.path, bytes: 40),
            frame("new", at: 10 * day, text: "new", image: newFile.path, bytes: 40),
        ])

        let result = try await store.prune(
            policy: ScreenHistoryRetentionPolicy(retentionDays: 5, storageCapBytes: 40),
            now: Date(timeIntervalSince1970: 11 * day)
        )

        #expect(result.rowsPlanned == 2)
        #expect(result.rowsRemoved == 2)
        #expect(result.bytesRemoved == 80)
        #expect(result.filesRemoved == 2)
        #expect(result.retryRequired == false)
        #expect(!FileManager.default.fileExists(atPath: expiredFile.path))
        #expect(try await store.count() == 1)
        #expect(try await store.search(ScreenHistorySearchQuery()).first?.sourceIdentifier == "new")
        #expect(try await store.search(ScreenHistorySearchQuery(text: "expired")).isEmpty)
    }

    @Test func storageCapIgnoresUnremovableCoastMediaAndKeepsOwnedCaptures() async throws {
        let fixture = try Fixture()
        let ownedRoot = try fixture.ownedDirectory()
        let ownedFile = ownedRoot.appendingPathComponent("capture.heic")
        try Data("capture".utf8).write(to: ownedFile)
        let coastRoot = fixture.directory.appendingPathComponent("coast", isDirectory: true)
        try FileManager.default.createDirectory(at: coastRoot, withIntermediateDirectories: true)
        let coastFile = coastRoot.appendingPathComponent("source.mp4")
        try Data(repeating: 0x41, count: 400).write(to: coastFile)
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot]
        )
        _ = try await store.record([
            ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: "coast-source",
                capturedAt: Date(timeIntervalSince1970: 100),
                ocrText: "coast media stays external",
                mediaLocator: coastFile.path,
                byteCount: 400
            ),
            frame("owned", at: 200, text: "owned capture survives", image: ownedFile.path, bytes: 100),
        ])

        // The Coast bytes are not removable here, so they must not spend the
        // one owned capture that is.
        let result = try await store.prune(
            policy: ScreenHistoryRetentionPolicy(storageCapBytes: 200),
            now: Date(timeIntervalSince1970: 300)
        )
        #expect(result.rowsPlanned == 0)
        #expect(result.rowsRemoved == 0)
        #expect(FileManager.default.fileExists(atPath: ownedFile.path))
        #expect(FileManager.default.fileExists(atPath: coastFile.path))
        #expect(try await store.search(ScreenHistorySearchQuery(text: "owned")).count == 1)

        let preview = try await store.previewPrune(
            policy: ScreenHistoryRetentionPolicy(storageCapBytes: 200),
            now: Date(timeIntervalSince1970: 300)
        )
        #expect(preview.rowsPlanned == 0)
        #expect(preview.retainedBytes == 100)
    }

    @Test func sharedOwnedMediaStaysUntilTheLastReferenceIsQueued() async throws {
        let fixture = try Fixture()
        let ownedRoot = try fixture.ownedDirectory()
        let sharedFile = ownedRoot.appendingPathComponent("shared.mp4")
        try Data("shared".utf8).write(to: sharedFile)
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot]
        )
        let day = 86_400.0
        _ = try await store.record([
            frame("old", at: day, text: "queued old", media: sharedFile.path, bytes: 6),
            frame("current", at: 10 * day, text: "current shared", media: sharedFile.path, bytes: 6),
        ])

        let result = try await store.prune(
            policy: ScreenHistoryRetentionPolicy(retentionDays: 5),
            now: Date(timeIntervalSince1970: 11 * day)
        )

        #expect(result.rowsRemoved == 1)
        #expect(result.filesRemoved == 0)
        #expect(result.filesRetainedShared == 1)
        #expect(FileManager.default.fileExists(atPath: sharedFile.path))
        #expect(try await store.search(ScreenHistorySearchQuery(text: "queued")).isEmpty)
        #expect(try await store.search(ScreenHistorySearchQuery(text: "current")).count == 1)
    }

    @Test func fileDeletionFailureKeepsOCRAndDurableQueueForRetry() async throws {
        let fixture = try Fixture()
        let ownedRoot = try fixture.ownedDirectory()
        let mediaFile = ownedRoot.appendingPathComponent("retry.heic")
        try Data("retry".utf8).write(to: mediaFile)
        let removal = RemovalGate(shouldFail: true)
        var store: SQLiteScreenHistoryStore? = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot],
            removeMediaFile: removal.remove
        )
        _ = try await store?.record(frame(
            "retry",
            at: 100,
            text: "retryable OCR remains",
            image: mediaFile.path,
            bytes: 5
        ))

        let failed = try await store?.prune(
            policy: ScreenHistoryRetentionPolicy(retentionDays: 1),
            now: Date(timeIntervalSince1970: 200_000)
        )
        #expect(failed?.retryRequired == true)
        #expect(failed?.pendingRows == 1)
        #expect(failed?.pendingLocators == 1)
        #expect(try await store?.search(ScreenHistorySearchQuery(text: "retryable")).count == 1)
        #expect(FileManager.default.fileExists(atPath: mediaFile.path))

        // Reopen the database to prove the queue, not actor memory, owns the retry.
        store = nil
        removal.shouldFail = false
        let resumedStore = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot],
            removeMediaFile: removal.remove
        )
        let resumed = try await resumedStore.prune(
            policy: ScreenHistoryRetentionPolicy(retentionDays: 1),
            now: Date(timeIntervalSince1970: 200_000)
        )
        #expect(resumed.resumedQueue == true)
        #expect(resumed.rowsRemoved == 1)
        #expect(resumed.retryRequired == false)
        #expect(!FileManager.default.fileExists(atPath: mediaFile.path))
        #expect(try await resumedStore.search(ScreenHistorySearchQuery(text: "retryable")).isEmpty)
    }

    @Test func crashAfterFileRemovalConvergesWhenMissingFileIsRetried() async throws {
        let fixture = try Fixture()
        let ownedRoot = try fixture.ownedDirectory()
        let mediaFile = ownedRoot.appendingPathComponent("crash.heic")
        try Data("crash".utf8).write(to: mediaFile)
        let crash = OneShotCrash()
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot],
            afterMediaRemoval: crash.afterRemoval
        )
        _ = try await store.record(frame(
            "crash",
            at: 100,
            text: "survives simulated crash",
            image: mediaFile.path,
            bytes: 5
        ))

        let interrupted = try await store.prune(
            policy: ScreenHistoryRetentionPolicy(retentionDays: 1),
            now: Date(timeIntervalSince1970: 200_000)
        )
        #expect(interrupted.retryRequired == true)
        #expect(interrupted.filesRemoved == 1)
        #expect(!FileManager.default.fileExists(atPath: mediaFile.path))
        #expect(try await store.search(ScreenHistorySearchQuery(text: "simulated")).count == 1)

        let converged = try await store.prune(
            policy: ScreenHistoryRetentionPolicy(retentionDays: 1),
            now: Date(timeIntervalSince1970: 200_000)
        )
        #expect(converged.resumedQueue == true)
        #expect(converged.filesAbsent == 1)
        #expect(converged.rowsRemoved == 1)
        #expect(converged.retryRequired == false)
        #expect(try await store.search(ScreenHistorySearchQuery(text: "simulated")).isEmpty)
    }

    @Test func missingOwnedFileAndCoastSourceBothConvergeWithoutUnsafeDeletion() async throws {
        let fixture = try Fixture()
        let ownedRoot = try fixture.ownedDirectory()
        let missing = ownedRoot.appendingPathComponent("already-gone.heic")
        let coastRoot = fixture.directory.appendingPathComponent("coast", isDirectory: true)
        try FileManager.default.createDirectory(at: coastRoot, withIntermediateDirectories: true)
        let coastFile = coastRoot.appendingPathComponent("source.mp4")
        try Data("coast-source".utf8).write(to: coastFile)
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot]
        )
        _ = try await store.record([
            frame("missing", at: 100, text: "missing owned", image: missing.path, bytes: 4),
            ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: "coast-source",
                capturedAt: Date(timeIntervalSince1970: 100),
                ocrText: "coast remains external",
                mediaLocator: coastFile.path,
                byteCount: 12
            ),
        ])

        let result = try await store.prune(
            policy: ScreenHistoryRetentionPolicy(retentionDays: 1),
            now: Date(timeIntervalSince1970: 200_000)
        )
        #expect(result.rowsRemoved == 2)
        #expect(result.filesAbsent == 1)
        #expect(result.filesRetainedUnowned == 1)
        #expect(result.retryRequired == false)
        #expect(FileManager.default.fileExists(atPath: coastFile.path))
        #expect(try await store.count() == 0)
    }

    @Test func ownedSymlinkIsNeverFollowedAndKeepsMetadataRetryable() async throws {
        let fixture = try Fixture()
        let ownedRoot = try fixture.ownedDirectory()
        let outside = fixture.directory.appendingPathComponent("outside.heic")
        try Data("outside".utf8).write(to: outside)
        let link = ownedRoot.appendingPathComponent("link.heic")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot]
        )
        _ = try await store.record(frame(
            "symlink",
            at: 100,
            text: "symlink OCR stays",
            image: link.path,
            bytes: 7
        ))

        let result = try await store.prune(
            policy: ScreenHistoryRetentionPolicy(retentionDays: 1),
            now: Date(timeIntervalSince1970: 200_000)
        )
        #expect(result.retryRequired == true)
        #expect(result.pendingRows == 1)
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try await store.search(ScreenHistorySearchQuery(text: "symlink")).count == 1)
    }

    @Test func captureSinkPersistsBoundedOwnedFrame() async throws {
        let fixture = try Fixture()
        let mediaDirectory = fixture.directory.appendingPathComponent("frames")
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            mediaDirectoryURL: mediaDirectory
        )
        let captured = CapturedScreenFrame(
            capturedAt: Date(timeIntervalSince1970: 500),
            bundleIdentifier: "test.synthetic.editor",
            applicationName: "Synthetic Editor",
            windowTitle: "Synthetic Window",
            pixelWidth: 20,
            pixelHeight: 10,
            imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            recognizedText: "bounded local words",
            fingerprint: 42
        )!

        try await store.receive(captured)

        let rows = try await store.search(ScreenHistorySearchQuery(text: "bounded"))
        #expect(rows.count == 1)
        #expect(rows.first?.source == .owned)
        #expect(rows.first?.byteCount == 4)
        #expect(rows.first?.imageLocator.map(FileManager.default.fileExists(atPath:)) == true)
        let imagePath = try #require(rows.first?.imageLocator)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: imagePath)[.posixPermissions] as? Int
        )
        #expect(permissions == 0o600)
    }

    @Test func databaseAndExistingWALSidecarsAreOwnerOnly() async throws {
        let fixture = try Fixture()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        _ = try await store.record(frame(
            "permissions",
            at: 500,
            text: "filesystem permission proof",
            bytes: 10
        ))

        let databaseFiles = [
            fixture.databaseURL,
            URL(fileURLWithPath: fixture.databaseURL.path + "-wal"),
            URL(fileURLWithPath: fixture.databaseURL.path + "-shm"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        #expect(databaseFiles.contains(fixture.databaseURL))
        for url in databaseFiles {
            let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                as? NSNumber
            #expect(try #require(value).intValue == 0o600)
        }
    }

    @Test func normalizedStructureAndDisplayMetadataStayDriftFree() async throws {
        let fixture = try Fixture()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let display = ScreenHistoryDisplayGeometry(x: 0, y: 0, width: 1728, height: 1117)
        _ = try await store.record(ScreenHistoryFrameInput(
            source: .coast,
            sourceIdentifier: "structured",
            capturedAt: Date(timeIntervalSince1970: 700),
            application: "Keynote",
            bundleIdentifier: "com.apple.keynote",
            domain: "example.test",
            windowTitle: "Structured proof",
            ocrText: "normalized OCR document",
            mediaLocator: "/synthetic/segment.mp4",
            mediaFrameIndex: 8,
            mediaFrameCount: 30,
            displayGeometry: display,
            byteCount: 10,
            sequenceIdentifier: "sequence-1",
            sequenceOrdinal: 2
        ))

        #expect(SQLiteScreenHistoryStore.schemaVersion == 7)
        #expect(try await store.normalizedStructureDriftCount() == 0)
        let row = try #require(try await store.search(ScreenHistorySearchQuery()).first)
        #expect(row.mediaFrameCount == 30)
        #expect(row.displayGeometry == display)

        let external = try LocalSQLiteConnection(
            url: fixture.databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        )
        try external.execute("UPDATE screen_history_frame SET media_ref_id = NULL;")
        #expect(try await store.normalizedStructureDriftCount() == 1)
        #expect(try await store.repairNormalizedMediaReferences() == 1)
        #expect(try await store.repairNormalizedMediaReferences() == 0)
        #expect(try await store.normalizedStructureDriftCount() == 0)

        try external.execute("UPDATE screen_history_frame SET domain_ref_id = NULL;")
        #expect(try await store.normalizedStructureDriftCount() == 1)
    }

    @Test func ocrBoxesRoundTripWithExactGeometryAndStableOrder() async throws {
        let fixture = try Fixture()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let expected = [
            ScreenHistoryOCRBox(
                ordinal: 0,
                text: "first line",
                x: -1_555.2,
                y: 111.6,
                width: 345.6,
                height: 55.8
            ),
            ScreenHistoryOCRBox(
                ordinal: 1,
                text: "second line",
                x: -1_209.6,
                y: 334.8,
                width: 518.4,
                height: 78.12
            ),
        ]
        _ = try await store.record(ScreenHistoryFrameInput(
            sourceIdentifier: "ocr-geometry",
            capturedAt: Date(timeIntervalSince1970: 800),
            application: "Synthetic Editor",
            ocrText: expected.map(\.text).joined(separator: "\n"),
            imageLocator: "/synthetic/left-display.heic",
            displayGeometry: ScreenHistoryDisplayGeometry(
                x: -1_728,
                y: 0,
                width: 1_728,
                height: 1_116
            ),
            ocrBoxes: expected,
            byteCount: 10
        ))

        let actual = try await store.ocrBoxes(
            source: .owned,
            sourceIdentifier: "ocr-geometry"
        )
        #expect(actual == expected)
    }

    private func frame(
        _ id: String,
        at timestamp: TimeInterval,
        app: String? = nil,
        domain: String? = nil,
        text: String,
        image: String? = nil,
        media: String? = nil,
        bytes: Int64 = 0
    ) -> ScreenHistoryFrameInput {
        ScreenHistoryFrameInput(
            sourceIdentifier: id,
            capturedAt: Date(timeIntervalSince1970: timestamp),
            application: app,
            domain: domain,
            ocrText: text,
            imageLocator: image,
            mediaLocator: media,
            byteCount: bytes
        )
    }
}

private final class Fixture {
    let directory: URL
    let databaseURL: URL

    init(name: String = "screen-history.sqlite3") throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-screen-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent(name)
    }

    func ownedDirectory() throws -> URL {
        let url = directory.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class RemovalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Bool

    init(shouldFail: Bool) { failing = shouldFail }

    var shouldFail: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func remove(_ url: URL) throws {
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.removeItem(at: url)
    }
}

private final class OneShotCrash: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldThrow = true

    func afterRemoval(_ url: URL) throws {
        let throwsNow = lock.withLock {
            defer { shouldThrow = false }
            return shouldThrow
        }
        if throwsNow { throw CocoaError(.fileWriteUnknown) }
    }
}
