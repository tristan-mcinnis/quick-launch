import Foundation
import SQLite3
import Testing
@testable import QuickLaunch

@Suite("Coast legacy reader")
struct CoastLegacyReaderTests {
    @Test func missingAndEmptyDatabasesReturnNoRows() async throws {
        let missing = CoastLegacyReader(databaseURL: URL(fileURLWithPath: "/tmp/quick-launch-missing-\(UUID().uuidString).db"))
        #expect(await missing.isAvailable() == false)
        #expect(try await missing.page(offset: 0, limit: 20).isEmpty)

        let fixture = try LegacyFixture(createSchema: false)
        let empty = CoastLegacyReader(databaseURL: fixture.databaseURL)
        #expect(await empty.isAvailable() == false)
        #expect(try await empty.importRows(afterFrameID: nil, limit: 20).isEmpty)
    }

    @Test func syntheticCoastSchemaSupportsSearchPagingAndBoundedImport() async throws {
        let fixture = try LegacyFixture(createSchema: true)
        try fixture.insertSyntheticRows()
        let reader = CoastLegacyReader(databaseURL: fixture.databaseURL, contentRootURL: fixture.directory)

        #expect(await reader.isAvailable())
        let matches = try await reader.search(ScreenHistorySearchQuery(
            text: "project alpha",
            application: "Synthetic Browser",
            domain: "example.test"
        ))
        #expect(matches.map(\.id) == [2, 1])
        #expect(matches.first?.imageLocator == fixture.directory.appendingPathComponent("frames/two.heic").path)
        #expect(matches.first?.domain == "example.test")

        let page = try await reader.page(offset: 1, limit: 1)
        #expect(page.map(\.id) == [1])

        let imported = try await reader.importRows(afterFrameID: 1, limit: 10_000)
        #expect(imported.count == 1)
        #expect(imported.first?.source == .coast)
        #expect(imported.first?.sourceIdentifier == "2")
        #expect((imported.first?.ocrText.count ?? .max) <= CoastLegacyReader.maximumOCRCharacters)
        #expect(imported.first?.sequenceIdentifier == "coast-segment-1")
        #expect(imported.first?.sequenceOrdinal == 1)
        #expect(imported.first?.contentHash.count == 64)

        let familyBatch = try await reader.migrationSourceBatch(afterFrameID: nil, limit: 20)
        #expect(familyBatch.rows.count == 2)
        #expect(familyBatch.supportedFamilies == Set(ScreenHistoryMigrationFamily.allCases))
        #expect(familyBatch.memberships.count == 2)
        #expect(Set(familyBatch.memberships.compactMap(\.ocrIdentifier)).count == 2)
        #expect(Set(familyBatch.memberships.compactMap(\.applicationIdentifier)).count == 1)
        #expect(Set(familyBatch.memberships.compactMap(\.domainIdentifier)).count == 1)
        #expect(Set(familyBatch.memberships.compactMap(\.sequenceIdentifier)).count == 1)
        #expect(Set(familyBatch.memberships.flatMap(\.mediaIdentifiers)).count == 2)
    }

    @Test func legacyFiltersAndSearchValuesCannotInjectSQL() async throws {
        let fixture = try LegacyFixture(createSchema: true)
        try fixture.insertSyntheticRows()
        let reader = CoastLegacyReader(databaseURL: fixture.databaseURL)

        let matches = try await reader.search(ScreenHistorySearchQuery(
            text: "' OR 1=1 --",
            application: "Synthetic Browser' OR 1=1 --"
        ))
        #expect(matches.isEmpty)
        #expect(try await reader.page(offset: 0, limit: 10).count == 2)
    }

    @Test func mediaLocatorsCannotEscapeTheCoastContentRoot() async throws {
        let fixture = try LegacyFixture(createSchema: true)
        try fixture.insertEscapingRow()
        let reader = CoastLegacyReader(
            databaseURL: fixture.databaseURL,
            contentRootURL: fixture.directory
        )

        let row = try #require(
            try await reader.search(ScreenHistorySearchQuery(text: "escape probe")).first
        )
        #expect(row.imageLocator == nil)
        #expect(row.mediaLocator == nil)
    }

    @Test func coastOCRBoxesPreserveTextGeometryAndDisplayCoordinates() async throws {
        let fixture = try LegacyFixture(createSchema: true)
        try fixture.insertSyntheticRows()
        let reader = CoastLegacyReader(
            databaseURL: fixture.databaseURL,
            contentRootURL: fixture.directory
        )

        let boxes = try await reader.ocrBoxes(sourceIdentifier: "1")
        #expect(boxes == [
            ScreenHistoryOCRBox(
                ordinal: 0,
                text: "project",
                x: -1_555.2,
                y: 111.6,
                width: 345.6,
                height: 55.8
            ),
            ScreenHistoryOCRBox(
                ordinal: 1,
                text: "alpha",
                x: -1_209.6,
                y: 334.8,
                width: 518.4,
                height: 78.12
            ),
        ])
    }
}

private final class LegacyFixture {
    let directory: URL
    let databaseURL: URL
    private var database: OpaquePointer?

    init(createSchema: Bool) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-coast-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("rem.db")
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw LocalSQLiteError.open("synthetic fixture")
        }
        if createSchema {
            try execute("""
                CREATE TABLE application(id INTEGER PRIMARY KEY, bundle_id TEXT, display_name TEXT);
                CREATE TABLE domain(id INTEGER PRIMARY KEY, normalized_domain TEXT);
                CREATE TABLE video(id INTEGER PRIMARY KEY, path TEXT, num_frames INTEGER, size_bytes INTEGER);
                CREATE TABLE segment(id INTEGER PRIMARY KEY, application INTEGER, domain INTEGER);
                CREATE TABLE frame(
                    id INTEGER PRIMARY KEY, timestamp INTEGER, video INTEGER, video_index INTEGER,
                    image_path TEXT, foreground TEXT, background TEXT, title TEXT, segment INTEGER,
                    capture_display_x REAL, capture_display_y REAL,
                    capture_display_width REAL, capture_display_height REAL
                );
                CREATE VIRTUAL TABLE ocr_fts USING fts5(
                    foreground, background, title, content='frame', content_rowid='id'
                );
                CREATE TABLE ocr(
                    id INTEGER PRIMARY KEY, frame INTEGER, text_offset INTEGER,
                    text_length INTEGER, x REAL, y REAL, width REAL, height REAL
                );
                CREATE TRIGGER frame_ai AFTER INSERT ON frame BEGIN
                    INSERT INTO ocr_fts(rowid, foreground, background, title)
                    VALUES (new.id, new.foreground, new.background, new.title);
                END;
                """)
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
        try? FileManager.default.removeItem(at: directory)
    }

    func insertSyntheticRows() throws {
        try execute("""
            INSERT INTO application VALUES (1, 'test.synthetic.browser', 'Synthetic Browser');
            INSERT INTO domain VALUES (1, 'example.test');
            INSERT INTO video VALUES (1, 'videos/one.mp4', 10, 1000);
            INSERT INTO segment VALUES (1, 1, 1);
            INSERT INTO frame VALUES (
                1, 1700000000000, 1, 4, NULL,
                'project alpha', 'first synthetic screen', 'Alpha One', 1,
                0, 0, 1728, 1117
            );
            INSERT INTO frame VALUES (
                2, 1700000002000, NULL, NULL, 'frames/two.heic',
                'project alpha', 'second synthetic screen', 'Alpha Two', 1,
                1728, 0, 1728, 1117
            );
            INSERT INTO ocr VALUES (1, 1, 0, 7, -1555.2, 111.6, 345.6, 55.8);
            INSERT INTO ocr VALUES (2, 1, 8, 5, -1209.6, 334.8, 518.4, 78.12);
            """)
    }

    func insertEscapingRow() throws {
        try execute("""
            INSERT INTO application VALUES (1, 'test.synthetic.editor', 'Synthetic Editor');
            INSERT INTO segment VALUES (1, 1, NULL);
            INSERT INTO video VALUES (1, '../../outside.mp4', 1, 100);
            INSERT INTO frame VALUES (
                1, 1700000000000, 1, 0, '/etc/passwd',
                'escape probe', '', 'Escape Probe', 1,
                0, 0, 1728, 1117
            );
            """)
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "synthetic fixture"
            sqlite3_free(error)
            throw LocalSQLiteError.execute(message)
        }
    }
}
