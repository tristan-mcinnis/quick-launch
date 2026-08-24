import Foundation
import SQLite3
import Testing
@testable import QuickLaunch

@Suite("Screen History migration", .serialized)
struct ScreenHistoryMigrationServiceTests {
    private let migrationNow = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("Coast preview classifies every row without owned writes")
    func previewIsReadOnlyAndExclusionAware() async throws {
        let fixture = try MigrationWorkspace()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let policy = policy()
        let service = ScreenHistoryMigrationService(
            reader: SyntheticMigrationReader(frames: frames()),
            store: store,
            policy: policy,
            clock: { migrationNow }
        )

        let preview = try await service.preview(batchSize: 3)

        #expect(preview.source == 17)
        #expect(preview.imported == 12)
        #expect(preview.excluded == 4)
        #expect(preview.invalid == 1)
        #expect(preview.reconciles)
        #expect(preview.policyFingerprint == policy.fingerprint)
        #expect(!preview.sourceFingerprint.isEmpty)
        #expect(try await store.count() == 0)
        #expect(try await store.migrationLedgerCount(source: .coast, status: nil) == 0)
    }

    @Test("Policy fingerprint is normalized, complete, and drift-sensitive")
    func policyFingerprintIsStableAndDriftSensitive() {
        let first = ScreenHistoryMigrationPolicy(
            excludedBundleIdentifiers: [" COM.EXAMPLE.PRIVATE ", "com.example.second"],
            excludedDomains: ["Private.Example"]
        )
        let reordered = ScreenHistoryMigrationPolicy(
            excludedBundleIdentifiers: ["com.example.second", "com.example.private"],
            excludedDomains: ["private.example"]
        )
        let changed = ScreenHistoryMigrationPolicy(
            excludedBundleIdentifiers: ["com.example.second", "com.example.private"],
            excludedDomains: ["private.example", "new-private.example"]
        )

        #expect(first.fingerprint == reordered.fingerprint)
        #expect(first.fingerprint != changed.fingerprint)
    }

    @Test("Preview proves separate content-free equations for every supported family")
    func previewReconcilesEverySupportedFamily() async throws {
        let fixture = try MigrationWorkspace()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let sharedApplication = "test.synthetic.shared"
        let rows = [
            ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: "1",
                capturedAt: migrationNow.addingTimeInterval(-30),
                application: "Shared",
                bundleIdentifier: sharedApplication,
                domain: "public.example",
                ocrText: "eligible",
                imageLocator: "/synthetic/shared.heic",
                sequenceIdentifier: "sequence-imported"
            ),
            ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: "2",
                capturedAt: migrationNow.addingTimeInterval(-20),
                application: "Shared",
                bundleIdentifier: sharedApplication,
                domain: "private.example",
                ocrText: "excluded",
                imageLocator: "/synthetic/excluded.heic",
                sequenceIdentifier: "sequence-excluded"
            ),
            ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: "3",
                capturedAt: migrationNow.addingTimeInterval(30),
                application: "Invalid",
                bundleIdentifier: "test.synthetic.invalid",
                domain: "invalid.example",
                ocrText: "invalid",
                mediaLocator: "/synthetic/invalid.mp4",
                sequenceIdentifier: "sequence-invalid"
            ),
        ]
        let preview = try await ScreenHistoryMigrationService(
            reader: SyntheticMigrationReader(frames: rows),
            store: store,
            policy: ScreenHistoryMigrationPolicy(excludedDomains: ["private.example"]),
            clock: { migrationNow }
        ).preview(batchSize: 2)

        #expect(preview.reconciles)
        #expect(preview.reconciliation.frame == equation(3, 1, 1, 1))
        #expect(preview.reconciliation.ocr == equation(3, 1, 1, 1))
        #expect(preview.reconciliation.application == equation(2, 1, 0, 1))
        #expect(preview.reconciliation.domain == equation(3, 1, 1, 1))
        #expect(preview.reconciliation.sequence == equation(3, 1, 1, 1))
        #expect(preview.reconciliation.media == equation(3, 1, 1, 1))
        #expect(try await store.count() == 0)
    }

    @Test("Coast importer rejects policy drift before any owned write")
    func importerRejectsPolicyDriftBeforeWrite() async throws {
        let fixture = try MigrationWorkspace()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let originalPolicy = ScreenHistoryMigrationPolicy(excludedDomains: ["private.example"])
        let importer = ScreenHistoryCoastImportService(
            reader: SyntheticMigrationReader(frames: frames()),
            store: store,
            legacyContentRootURL: fixture.directory,
            ownedMediaDirectoryURL: fixture.directory.appendingPathComponent("owned-media")
        )
        let preview = try await importer.previewMetadata(policy: originalPolicy)
        let changedPolicy = ScreenHistoryMigrationPolicy(
            excludedDomains: ["private.example", "changed.example"]
        )

        await #expect(throws: ScreenHistoryCoastImportError.stalePreview) {
            try await importer.importMetadata(preview: preview, policy: changedPolicy)
        }
        #expect(try await store.count() == 0)
        #expect(try await store.migrationLedgerCount(source: .coast, status: nil) == 0)
    }

    @Test("Coast importer rejects source drift before any owned write")
    func importerRejectsSourceDriftBeforeWrite() async throws {
        let fixture = try MigrationWorkspace()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let first = ScreenHistoryFrameInput(
            source: .coast,
            sourceIdentifier: "1",
            capturedAt: Date().addingTimeInterval(-100),
            application: "Synthetic Editor",
            bundleIdentifier: "test.synthetic.editor",
            ocrText: "first synthetic row"
        )
        let reader = MutableSyntheticMigrationReader(frames: [first])
        let importer = ScreenHistoryCoastImportService(
            reader: reader,
            store: store,
            legacyContentRootURL: fixture.directory,
            ownedMediaDirectoryURL: fixture.directory.appendingPathComponent("owned-media")
        )
        let policy = ScreenHistoryMigrationPolicy.safeDefault
        let preview = try await importer.previewMetadata(policy: policy)
        await reader.append(ScreenHistoryFrameInput(
            source: .coast,
            sourceIdentifier: "2",
            capturedAt: Date().addingTimeInterval(-50),
            application: "Synthetic Editor",
            bundleIdentifier: "test.synthetic.editor",
            ocrText: "source changed after review"
        ))

        await #expect(throws: ScreenHistoryCoastImportError.sourceChanged) {
            try await importer.importMetadata(preview: preview, policy: policy)
        }
        #expect(try await store.count() == 0)
        #expect(try await store.migrationLedgerCount(source: .coast, status: nil) == 0)
    }

    @Test("SH-M01 reconciles every source row without protected writes")
    func reconcileCountsAndExclusions() async throws {
        let fixture = try MigrationWorkspace()
        let reader = SyntheticMigrationReader(frames: frames())
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let service = ScreenHistoryMigrationService(
            reader: reader,
            store: store,
            policy: policy(),
            clock: { migrationNow }
        )

        let result = try await service.migrate()

        #expect(result.source == 17)
        #expect(result.imported == 12)
        #expect(result.excluded == 4)
        #expect(result.invalid == 1)
        #expect(result.reconciles)
        #expect(result.ownedRowDelta == 12)
        #expect(result.mappingCount == 12)
        #expect(result.ledgerCount == 17)
        #expect(try await store.count() == 12)
        #expect(try await store.search(ScreenHistorySearchQuery(text: "protected synthetic phrase")).isEmpty)
        #expect(try await store.search(ScreenHistorySearchQuery(text: "future synthetic phrase")).isEmpty)
    }

    @Test("SH-M02 repeated import changes no owned row or hash")
    func repeatedImportIsIdempotent() async throws {
        let fixture = try MigrationWorkspace()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let service = ScreenHistoryMigrationService(
            reader: SyntheticMigrationReader(frames: frames()),
            store: store,
            policy: policy(),
            clock: { migrationNow }
        )

        _ = try await service.migrate()
        let repeated = try await service.migrate()

        #expect(repeated.source == 17)
        #expect(repeated.ownedRowDelta == 0)
        #expect(repeated.hashDelta == 0)
        #expect(repeated.mappingCount == 12)
        #expect(repeated.ledgerCount == 17)
        #expect(try await store.count() == 12)
    }

    @Test("Migration applies the same protected title and domain rules as search")
    func migrationUsesSearchPrivacyBoundary() async throws {
        let fixture = try MigrationWorkspace()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let frames = [
            ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: "3001",
                capturedAt: migrationNow.addingTimeInterval(-10),
                application: "Synthetic Editor",
                bundleIdentifier: "test.synthetic.editor",
                windowTitle: "Billing checkout credit card",
                ocrText: "must stay excluded"
            ),
            ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: "3002",
                capturedAt: migrationNow.addingTimeInterval(-5),
                application: "Synthetic Editor",
                bundleIdentifier: "test.synthetic.editor",
                domain: "login.example.test",
                windowTitle: "Ordinary title",
                ocrText: "must also stay excluded"
            ),
        ]

        let result = try await ScreenHistoryMigrationService(
            reader: SyntheticMigrationReader(frames: frames),
            store: store,
            clock: { migrationNow }
        ).migrate()

        #expect(result.source == 2)
        #expect(result.imported == 0)
        #expect(result.excluded == 2)
        #expect(try await store.count() == 0)
    }

    @Test("SH-M03 resume after legacy-1007 converges with a clean import")
    func resumedImportConverges() async throws {
        let cleanFixture = try MigrationWorkspace()
        let cleanStore = try SQLiteScreenHistoryStore(databaseURL: cleanFixture.databaseURL)
        let cleanService = ScreenHistoryMigrationService(
            reader: SyntheticMigrationReader(frames: frames()),
            store: cleanStore,
            policy: policy(),
            clock: { migrationNow }
        )
        _ = try await cleanService.migrate()

        let resumedFixture = try MigrationWorkspace()
        let resumedStore = try SQLiteScreenHistoryStore(databaseURL: resumedFixture.databaseURL)
        let resumedService = ScreenHistoryMigrationService(
            reader: SyntheticMigrationReader(frames: frames()),
            store: resumedStore,
            policy: policy(),
            clock: { migrationNow }
        )
        let first = try await resumedService.migrate(maximumSourceRows: 7)
        #expect(first.lastLegacyFrameID == 1007)
        let second = try await resumedService.migrate(afterLegacyFrameID: 1007)
        #expect(second.source == 10)

        let clean = try await snapshot(cleanStore)
        let resumed = try await snapshot(resumedStore)
        #expect(resumed == clean)
        #expect(resumed.count == 12)
    }

    @Test("Selected frames retrieve one chronological owned sequence")
    func sequenceRetrievalUsesStoredIdentityAndOrdinal() async throws {
        let fixture = try MigrationWorkspace()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let inputs = [
            eligible(1002, ordinal: 2, timestamp: migrationNow.addingTimeInterval(-20)),
            eligible(1001, ordinal: 1, timestamp: migrationNow.addingTimeInterval(-30)),
            eligible(1003, ordinal: 3, timestamp: migrationNow.addingTimeInterval(-10)),
            ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: "1004",
                capturedAt: migrationNow.addingTimeInterval(-25),
                application: "Synthetic Editor",
                bundleIdentifier: "test.synthetic.editor",
                ocrText: "adjacent but separate",
                sequenceIdentifier: "coast-segment-other",
                sequenceOrdinal: 1
            ),
        ]
        _ = try await store.record(inputs)
        let anchor = try #require(
            try await store.search(ScreenHistorySearchQuery(text: "eligible 1002")).first
        )

        let sequence = try await store.sequence(containingFrameID: anchor.id, limit: 20)

        #expect(sequence.map(\.sourceIdentifier) == ["1001", "1002", "1003"])
        #expect(sequence.map(\.sequenceOrdinal) == [1, 2, 3])
    }

    @Test("A version-one owned database migrates in place")
    func versionOneSchemaMigratesSafely() async throws {
        let fixture = try MigrationWorkspace()
        do {
            let database = try LocalSQLiteConnection(
                url: fixture.databaseURL,
                flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                createParent: true
            )
            try database.execute("""
                CREATE TABLE screen_history_frame (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source TEXT NOT NULL,
                    source_identifier TEXT NOT NULL,
                    captured_at REAL NOT NULL,
                    application TEXT,
                    bundle_identifier TEXT,
                    domain TEXT,
                    window_title TEXT,
                    ocr_text TEXT NOT NULL DEFAULT '',
                    image_locator TEXT,
                    media_locator TEXT,
                    media_frame_index INTEGER,
                    byte_count INTEGER NOT NULL DEFAULT 0 CHECK(byte_count >= 0),
                    UNIQUE(source, source_identifier)
                );
                INSERT INTO screen_history_frame(
                    source, source_identifier, captured_at, bundle_identifier, ocr_text
                ) VALUES ('owned', 'v1-row', 100, 'test.synthetic.editor', 'synthetic v1 content');
                PRAGMA user_version = 1;
                """)
        }

        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let rows = try await store.search(ScreenHistorySearchQuery())

        #expect(SQLiteScreenHistoryStore.schemaVersion == 7)
        #expect(rows.count == 1)
        #expect(rows.first?.contentHash.count == 64)
        #expect(rows.first?.sequenceIdentifier == nil)
    }

    @Test("reclassification removes owned media but never touches Coast source media")
    func reclassificationRemovesOnlyOwnedMedia() async throws {
        let fixture = try MigrationWorkspace()
        let ownedRoot = fixture.directory.appendingPathComponent("owned", isDirectory: true)
        let coastRoot = fixture.directory.appendingPathComponent("coast", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: coastRoot, withIntermediateDirectories: true)
        let ownedImage = ownedRoot.appendingPathComponent("copied.heic")
        let coastVideo = coastRoot.appendingPathComponent("source.mp4")
        try Data("owned-copy".utf8).write(to: ownedImage)
        try Data("coast-source".utf8).write(to: coastVideo)
        let frame = migrationMediaFrame(
            id: 2001,
            application: "Synthetic Sensitive",
            image: ownedImage.path,
            media: coastVideo.path
        )
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot]
        )
        _ = try await ScreenHistoryMigrationService(
            reader: SyntheticMigrationReader(frames: [frame]),
            store: store,
            clock: { migrationNow }
        ).migrate()

        let excluded = try await ScreenHistoryMigrationService(
            reader: SyntheticMigrationReader(frames: [frame]),
            store: store,
            policy: ScreenHistoryMigrationPolicy(excludedApplications: ["synthetic sensitive"]),
            clock: { migrationNow }
        ).migrate()

        #expect(excluded.ownedRowDelta == -1)
        #expect(excluded.mappingCount == 0)
        #expect(try await store.search(ScreenHistorySearchQuery(text: "reclassification proof")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ownedImage.path))
        #expect(FileManager.default.fileExists(atPath: coastVideo.path))
        #expect(try Data(contentsOf: coastVideo) == Data("coast-source".utf8))
    }

    @Test("reclassification preserves an owned file shared by a retained row")
    func reclassificationPreservesSharedOwnedMedia() async throws {
        let fixture = try MigrationWorkspace()
        let ownedRoot = fixture.directory.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
        let shared = ownedRoot.appendingPathComponent("shared.mp4")
        try Data("shared-owned-copy".utf8).write(to: shared)
        let excludedFrame = migrationMediaFrame(
            id: 2101,
            application: "Synthetic Sensitive",
            media: shared.path
        )
        let retainedFrame = migrationMediaFrame(
            id: 2102,
            application: "Synthetic Retained",
            media: shared.path
        )
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot]
        )
        let reader = SyntheticMigrationReader(frames: [excludedFrame, retainedFrame])
        _ = try await ScreenHistoryMigrationService(
            reader: reader,
            store: store,
            clock: { migrationNow }
        ).migrate()

        let result = try await ScreenHistoryMigrationService(
            reader: reader,
            store: store,
            policy: ScreenHistoryMigrationPolicy(excludedApplications: ["synthetic sensitive"]),
            clock: { migrationNow }
        ).migrate()

        #expect(result.ownedRowDelta == -1)
        #expect(try await store.count() == 1)
        #expect(try await store.search(ScreenHistorySearchQuery()).first?.sourceIdentifier == "2102")
        #expect(FileManager.default.fileExists(atPath: shared.path))
    }

    @Test("a failed reclassification deletion keeps searchable metadata and retries")
    func reclassificationDeletionFailureRetries() async throws {
        let fixture = try MigrationWorkspace()
        let ownedRoot = fixture.directory.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
        let ownedImage = ownedRoot.appendingPathComponent("retry.heic")
        try Data("retry-owned-copy".utf8).write(to: ownedImage)
        let frame = migrationMediaFrame(
            id: 2201,
            application: "Synthetic Sensitive",
            image: ownedImage.path
        )
        let removal = MigrationRemovalGate(shouldFail: true)
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot],
            removeMediaFile: removal.remove
        )
        _ = try await store.applyMigration(frame, status: .imported, migratedAt: migrationNow)

        var failed = false
        do {
            _ = try await store.applyMigration(frame, status: .excluded, migratedAt: migrationNow)
        } catch {
            failed = true
        }
        #expect(failed)
        #expect(FileManager.default.fileExists(atPath: ownedImage.path))
        #expect(try await store.search(ScreenHistorySearchQuery(text: "reclassification proof")).count == 1)
        #expect(try await store.migrationLedgerCount(source: .coast, status: .imported) == 1)

        removal.shouldFail = false
        let resumed = try await store.applyMigration(frame, status: .excluded, migratedAt: migrationNow)
        #expect(resumed.ownedRowDelta == -1)
        #expect(!FileManager.default.fileExists(atPath: ownedImage.path))
        #expect(try await store.count() == 0)
        #expect(try await store.migrationLedgerCount(source: .coast, status: .excluded) == 1)
    }

    @Test("an interruption after reclassification file removal converges on retry")
    func reclassificationCrashAfterRemovalRetries() async throws {
        let fixture = try MigrationWorkspace()
        let ownedRoot = fixture.directory.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedRoot, withIntermediateDirectories: true)
        let ownedImage = ownedRoot.appendingPathComponent("crash.heic")
        try Data("crash-owned-copy".utf8).write(to: ownedImage)
        let frame = migrationMediaFrame(
            id: 2301,
            application: "Synthetic Sensitive",
            image: ownedImage.path
        )
        let crash = MigrationOneShotCrash()
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [ownedRoot],
            afterMediaRemoval: crash.afterRemoval
        )
        _ = try await store.applyMigration(frame, status: .imported, migratedAt: migrationNow)

        var interrupted = false
        do {
            _ = try await store.applyMigration(frame, status: .excluded, migratedAt: migrationNow)
        } catch {
            interrupted = true
        }
        #expect(interrupted)
        #expect(!FileManager.default.fileExists(atPath: ownedImage.path))
        #expect(try await store.search(ScreenHistorySearchQuery(text: "reclassification proof")).count == 1)

        let resumed = try await store.applyMigration(frame, status: .excluded, migratedAt: migrationNow)
        #expect(resumed.ownedRowDelta == -1)
        #expect(try await store.count() == 0)
        #expect(try await store.migrationLedgerCount(source: .coast, status: .excluded) == 1)
    }

    private func frames() -> [ScreenHistoryFrameInput] {
        var result = (1001...1012).map { id in
            eligible(
                Int64(id),
                ordinal: id - 1000,
                timestamp: migrationNow.addingTimeInterval(TimeInterval(id - 1100))
            )
        }
        result.append(contentsOf: [
            protected(1013, bundle: "com.1password.1password", title: "Synthetic vault"),
            protected(1014, bundle: "test.synthetic.browser", title: "Synthetic finance", domain: "bank.example"),
            protected(1015, bundle: "test.synthetic.browser", title: "Private Browsing"),
            protected(1016, bundle: "unknown.bundle", title: "Unknown window"),
            ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: "1017",
                capturedAt: migrationNow.addingTimeInterval(60),
                application: "Synthetic Notes",
                bundleIdentifier: "test.synthetic.notes",
                windowTitle: "Future row",
                ocrText: "future synthetic phrase",
                sequenceIdentifier: "coast-segment-future",
                sequenceOrdinal: 1
            ),
        ])
        return result
    }

    private func eligible(_ id: Int64, ordinal: Int, timestamp: Date) -> ScreenHistoryFrameInput {
        ScreenHistoryFrameInput(
            source: .coast,
            sourceIdentifier: String(id),
            capturedAt: timestamp,
            application: "Synthetic Editor",
            bundleIdentifier: "test.synthetic.editor",
            windowTitle: "Synthetic eligible row \(id)",
            ocrText: "eligible \(id)",
            mediaLocator: "/synthetic/media.mp4",
            mediaFrameIndex: ordinal,
            byteCount: 1,
            sequenceIdentifier: "coast-segment-main",
            sequenceOrdinal: ordinal
        )
    }

    private func protected(
        _ id: Int64,
        bundle: String,
        title: String,
        domain: String? = nil
    ) -> ScreenHistoryFrameInput {
        ScreenHistoryFrameInput(
            source: .coast,
            sourceIdentifier: String(id),
            capturedAt: migrationNow.addingTimeInterval(-10),
            application: "Synthetic Application",
            bundleIdentifier: bundle,
            domain: domain,
            windowTitle: title,
            ocrText: "protected synthetic phrase",
            imageLocator: "/synthetic/protected.heic",
            byteCount: 1,
            sequenceIdentifier: "coast-segment-protected",
            sequenceOrdinal: Int(id - 1012)
        )
    }

    private func policy() -> ScreenHistoryMigrationPolicy {
        ScreenHistoryMigrationPolicy(financeDomains: ["bank.example"])
    }

    private func migrationMediaFrame(
        id: Int64,
        application: String,
        image: String? = nil,
        media: String? = nil
    ) -> ScreenHistoryFrameInput {
        ScreenHistoryFrameInput(
            source: .coast,
            sourceIdentifier: String(id),
            capturedAt: migrationNow.addingTimeInterval(-100),
            application: application,
            bundleIdentifier: "test.synthetic.migration",
            windowTitle: "Synthetic reclassification",
            ocrText: "reclassification proof (id)",
            imageLocator: image,
            mediaLocator: media,
            mediaFrameIndex: media == nil ? nil : 1,
            byteCount: 16,
            sequenceIdentifier: "reclassification-sequence",
            sequenceOrdinal: Int(id)
        )
    }

    private func snapshot(_ store: SQLiteScreenHistoryStore) async throws -> [String] {
        try await store.search(ScreenHistorySearchQuery(limit: 200))
            .map { "\($0.sourceIdentifier):\($0.contentHash)" }
            .sorted()
    }

    private func equation(
        _ source: Int,
        _ imported: Int,
        _ excluded: Int,
        _ invalid: Int
    ) -> ScreenHistoryMigrationFamilyEquation {
        ScreenHistoryMigrationFamilyEquation(
            source: source,
            imported: imported,
            excluded: excluded,
            invalid: invalid
        )
    }
}

private actor SyntheticMigrationReader: CoastLegacyReading {
    private let frames: [ScreenHistoryFrameInput]

    init(frames: [ScreenHistoryFrameInput]) {
        self.frames = frames.sorted { (Int64($0.sourceIdentifier) ?? 0) < (Int64($1.sourceIdentifier) ?? 0) }
    }

    func isAvailable() -> Bool { true }
    func search(_ query: ScreenHistorySearchQuery) -> [ScreenHistoryFrame] { [] }
    func page(offset: Int, limit: Int) -> [ScreenHistoryFrame] { [] }
    func moments(from: Date, through: Date, limit: Int) -> [ScreenHistoryFrame] { [] }

    func importRows(afterFrameID: Int64?, limit: Int) -> [ScreenHistoryFrameInput] {
        frames.filter { frame in
            guard let id = Int64(frame.sourceIdentifier) else { return true }
            return afterFrameID.map { id > $0 } ?? true
        }.prefix(max(0, limit)).map { $0 }
    }
}

private actor MutableSyntheticMigrationReader: CoastLegacyReading {
    private var frames: [ScreenHistoryFrameInput]

    init(frames: [ScreenHistoryFrameInput]) {
        self.frames = frames
    }

    func append(_ frame: ScreenHistoryFrameInput) {
        frames.append(frame)
    }

    func isAvailable() -> Bool { true }
    func search(_ query: ScreenHistorySearchQuery) -> [ScreenHistoryFrame] { [] }
    func page(offset: Int, limit: Int) -> [ScreenHistoryFrame] { [] }
    func moments(from: Date, through: Date, limit: Int) -> [ScreenHistoryFrame] { [] }

    func importRows(afterFrameID: Int64?, limit: Int) -> [ScreenHistoryFrameInput] {
        frames
            .sorted { (Int64($0.sourceIdentifier) ?? 0) < (Int64($1.sourceIdentifier) ?? 0) }
            .filter { frame in
                guard let id = Int64(frame.sourceIdentifier) else { return true }
                return afterFrameID.map { id > $0 } ?? true
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}

private final class MigrationWorkspace: @unchecked Sendable {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-screen-history-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("screen-history.sqlite3")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class MigrationRemovalGate: @unchecked Sendable {
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

private final class MigrationOneShotCrash: @unchecked Sendable {
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
