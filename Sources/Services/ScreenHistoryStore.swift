import Foundation
import SQLite3
import Darwin
import CryptoKit

actor SQLiteScreenHistoryStore: ScreenHistoryStoring, ScreenHistoryFrameSink, ScreenHistoryRetirementSampling {
    nonisolated static let schemaVersion: Int32 = 7
    nonisolated static let maximumOCRBytes = 200_000

    private let database: LocalSQLiteConnection
    private let databaseURL: URL
    private let mediaDirectoryURL: URL
    private let ownedMediaRootURLs: [URL]
    private let removeMediaFile: @Sendable (URL) throws -> Void
    private let afterMediaRemoval: (@Sendable (URL) throws -> Void)?

    static func defaultDatabaseURL() -> URL {
        AppPaths.file("screen-history.sqlite3")
    }

    static func defaultMediaDirectoryURL() -> URL {
        defaultDatabaseURL().deletingLastPathComponent().appendingPathComponent("Screen History Frames")
    }

    init(
        databaseURL: URL = SQLiteScreenHistoryStore.defaultDatabaseURL(),
        mediaDirectoryURL: URL? = nil,
        ownedMediaRootURLs: [URL]? = nil,
        removeMediaFile: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        afterMediaRemoval: (@Sendable (URL) throws -> Void)? = nil
    ) throws {
        self.databaseURL = databaseURL
        self.mediaDirectoryURL = mediaDirectoryURL
            ?? databaseURL.deletingLastPathComponent().appendingPathComponent("Screen History Frames")
        self.ownedMediaRootURLs = ownedMediaRootURLs ?? [
            self.mediaDirectoryURL,
            ScreenHistoryMediaMigrationService.defaultOwnedMediaDirectoryURL(),
        ]
        self.removeMediaFile = removeMediaFile
        self.afterMediaRemoval = afterMediaRemoval
        try Self.preparePrivateDatabasePath(databaseURL)
        database = try LocalSQLiteConnection(
            url: databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            createParent: true
        )
        try database.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            PRAGMA secure_delete = ON;
            CREATE TABLE IF NOT EXISTS screen_history_frame (
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
                media_frame_count INTEGER,
                capture_display_x REAL,
                capture_display_y REAL,
                capture_display_width REAL,
                capture_display_height REAL,
                application_ref_id INTEGER,
                domain_ref_id INTEGER,
                sequence_ref_id INTEGER,
                media_ref_id INTEGER,
                byte_count INTEGER NOT NULL DEFAULT 0 CHECK(byte_count >= 0),
                sequence_identifier TEXT,
                sequence_ordinal INTEGER CHECK(sequence_ordinal IS NULL OR sequence_ordinal >= 0),
                content_hash TEXT NOT NULL DEFAULT '',
                UNIQUE(source, source_identifier)
            );
            CREATE INDEX IF NOT EXISTS screen_history_frame_captured_at
                ON screen_history_frame(captured_at DESC);
            CREATE INDEX IF NOT EXISTS screen_history_frame_application
                ON screen_history_frame(application COLLATE NOCASE);
            CREATE INDEX IF NOT EXISTS screen_history_frame_domain
                ON screen_history_frame(domain COLLATE NOCASE);
            CREATE VIRTUAL TABLE IF NOT EXISTS screen_history_fts USING fts5(
                application,
                domain,
                window_title,
                ocr_text,
                content='screen_history_frame',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS screen_history_frame_ai AFTER INSERT ON screen_history_frame BEGIN
                INSERT INTO screen_history_fts(rowid, application, domain, window_title, ocr_text)
                VALUES (new.id, new.application, new.domain, new.window_title, new.ocr_text);
            END;
            CREATE TRIGGER IF NOT EXISTS screen_history_frame_ad AFTER DELETE ON screen_history_frame BEGIN
                INSERT INTO screen_history_fts(screen_history_fts, rowid, application, domain, window_title, ocr_text)
                VALUES ('delete', old.id, old.application, old.domain, old.window_title, old.ocr_text);
            END;
            CREATE TRIGGER IF NOT EXISTS screen_history_frame_au
            AFTER UPDATE OF application, domain, window_title, ocr_text ON screen_history_frame BEGIN
                INSERT INTO screen_history_fts(screen_history_fts, rowid, application, domain, window_title, ocr_text)
                VALUES ('delete', old.id, old.application, old.domain, old.window_title, old.ocr_text);
                INSERT INTO screen_history_fts(rowid, application, domain, window_title, ocr_text)
                VALUES (new.id, new.application, new.domain, new.window_title, new.ocr_text);
            END;
            """)
        try migrateSchemaToVersion2()
        try migrateSchemaToVersion3()
        try migrateSchemaToVersion4()
        try migrateSchemaToVersion5()
        try migrateSchemaToVersion6()
        try migrateSchemaToVersion7()
        try restrictDatabaseFilePermissions()
    }

    private nonisolated static func preparePrivateDatabasePath(_ databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        if !FileManager.default.fileExists(atPath: databaseURL.path) {
            guard FileManager.default.createFile(
                atPath: databaseURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw LocalSQLiteError.open("could not create the private database file")
            }
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: databaseURL.path
        )
    }

    /// Persists only a bounded, capture-produced JPEG and its searchable
    /// metadata. A failed write never creates a database row.
    func receive(_ frame: CapturedScreenFrame) async throws {
        let milliseconds = Int64(frame.capturedAt.timeIntervalSince1970 * 1_000)
        let sourceIdentifier = "\(milliseconds)-\(String(frame.fingerprint, radix: 16))"
        let imageURL = mediaDirectoryURL.appendingPathComponent("\(sourceIdentifier).jpg")
        do {
            try FileManager.default.createDirectory(at: mediaDirectoryURL, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: mediaDirectoryURL.path
            )
            // macOS does not implement Data's iOS file-protection option.
            // Write atomically, then restrict the owned capture to this user.
            try frame.imageData.write(to: imageURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: imageURL.path
            )
            _ = try record(ScreenHistoryFrameInput(
                sourceIdentifier: sourceIdentifier,
                capturedAt: frame.capturedAt,
                application: frame.applicationName,
                bundleIdentifier: frame.bundleIdentifier,
                windowTitle: frame.windowTitle,
                ocrText: frame.recognizedText,
                imageLocator: imageURL.path,
                ocrBoxes: frame.recognizedBoxes,
                byteCount: Int64(frame.imageData.count)
            ))
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }
    }

    func record(_ frame: ScreenHistoryFrameInput) throws -> Int64 {
        guard !frame.sourceIdentifier.isEmpty else {
            throw LocalSQLiteError.bind("source identifier is empty")
        }
        let statement = try database.prepare("""
            INSERT INTO screen_history_frame(
                source, source_identifier, captured_at, application, bundle_identifier,
                domain, window_title, ocr_text, image_locator, media_locator,
                media_frame_index, media_frame_count, capture_display_x,
                capture_display_y, capture_display_width, capture_display_height,
                byte_count, sequence_identifier, sequence_ordinal, content_hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source, source_identifier) DO UPDATE SET
                captured_at=excluded.captured_at,
                application=excluded.application,
                bundle_identifier=excluded.bundle_identifier,
                domain=excluded.domain,
                window_title=excluded.window_title,
                ocr_text=excluded.ocr_text,
                image_locator=excluded.image_locator,
                media_locator=excluded.media_locator,
                media_frame_index=excluded.media_frame_index,
                media_frame_count=excluded.media_frame_count,
                capture_display_x=excluded.capture_display_x,
                capture_display_y=excluded.capture_display_y,
                capture_display_width=excluded.capture_display_width,
                capture_display_height=excluded.capture_display_height,
                byte_count=excluded.byte_count,
                sequence_identifier=excluded.sequence_identifier,
                sequence_ordinal=excluded.sequence_ordinal,
                content_hash=excluded.content_hash
            RETURNING id;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(frame, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LocalSQLiteError.step(database.message())
        }
        let frameID = sqlite3_column_int64(statement, 0)
        try syncNormalizedStructure(frameID: frameID, frame: frame)
        return frameID
    }

    func record(_ frames: [ScreenHistoryFrameInput]) throws -> Int {
        guard !frames.isEmpty else { return 0 }
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for frame in frames { _ = try record(frame) }
            try database.execute("COMMIT;")
            return frames.count
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    func search(_ query: ScreenHistorySearchQuery) throws -> [ScreenHistoryFrame] {
        let match = Self.literalFTSQuery(query.text)
        var conditions: [String] = []
        var binds: [(OpaquePointer, Int32) throws -> Void] = []

        if let match {
            conditions.append("screen_history_fts MATCH ?")
            binds.append { try SQLiteValue.bind(match, to: $0, at: $1) }
        }
        if let from = query.from?.timeIntervalSince1970 {
            conditions.append("f.captured_at >= ?")
            binds.append { try SQLiteValue.bind(from, to: $0, at: $1) }
        }
        if let through = query.through?.timeIntervalSince1970 {
            conditions.append("f.captured_at <= ?")
            binds.append { try SQLiteValue.bind(through, to: $0, at: $1) }
        }
        if let application = Self.cleanFilter(query.application) {
            conditions.append("f.application = ? COLLATE NOCASE")
            binds.append { try SQLiteValue.bind(application, to: $0, at: $1) }
        }
        if let domain = Self.cleanFilter(query.domain) {
            conditions.append("f.domain = ? COLLATE NOCASE")
            binds.append { try SQLiteValue.bind(domain, to: $0, at: $1) }
        }

        let fromClause = match == nil
            ? "screen_history_frame f"
            : "screen_history_fts JOIN screen_history_frame f ON f.id = screen_history_fts.rowid"
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let statement = try database.prepare("""
            SELECT f.id, f.source, f.source_identifier, f.captured_at,
                   f.application, f.bundle_identifier, f.domain, f.window_title,
                   substr(f.ocr_text, 1, 20000), f.image_locator, f.media_locator,
                   f.media_frame_index, f.media_frame_count,
                   f.capture_display_x, f.capture_display_y,
                   f.capture_display_width, f.capture_display_height,
                   f.byte_count, f.sequence_identifier, f.sequence_ordinal, f.content_hash
            FROM \(fromClause)
            \(whereClause)
            ORDER BY f.captured_at DESC, f.id DESC
            LIMIT ? OFFSET ?;
            """)
        defer { sqlite3_finalize(statement) }
        for (position, binder) in binds.enumerated() {
            try binder(statement, Int32(position + 1))
        }
        let limitIndex = Int32(binds.count + 1)
        try SQLiteValue.bind(Int64(min(max(1, query.limit), 200)), to: statement, at: limitIndex)
        try SQLiteValue.bind(Int64(max(0, query.offset)), to: statement, at: limitIndex + 1)
        return try readFrames(statement)
    }

    func sequence(containingFrameID frameID: Int64, limit: Int = 200) throws -> [ScreenHistoryFrame] {
        let anchor = try database.prepare("""
            SELECT sequence_identifier
            FROM screen_history_frame
            WHERE id = ?;
            """)
        defer { sqlite3_finalize(anchor) }
        try SQLiteValue.bind(frameID, to: anchor, at: 1)
        guard sqlite3_step(anchor) == SQLITE_ROW,
              let sequenceIdentifier = SQLiteValue.text(anchor, 0),
              !sequenceIdentifier.isEmpty
        else { return [] }

        let statement = try database.prepare("""
            SELECT id, source, source_identifier, captured_at,
                   application, bundle_identifier, domain, window_title,
                   substr(ocr_text, 1, 20000), image_locator, media_locator,
                   media_frame_index, media_frame_count, capture_display_x,
                   capture_display_y, capture_display_width, capture_display_height,
                   byte_count, sequence_identifier, sequence_ordinal, content_hash
            FROM screen_history_frame
            WHERE sequence_identifier = ?
            ORDER BY sequence_ordinal ASC, captured_at ASC, id ASC
            LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(sequenceIdentifier, to: statement, at: 1)
        try SQLiteValue.bind(Int64(min(max(1, limit), 500)), to: statement, at: 2)
        return try readFrames(statement)
    }

    func count() throws -> Int {
        let statement = try database.prepare("SELECT count(*) FROM screen_history_frame;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func ocrBoxes(
        source: ScreenHistorySource,
        sourceIdentifier: String
    ) async throws -> [ScreenHistoryOCRBox] {
        let statement = try database.prepare("""
            SELECT b.ordinal, b.text, b.x, b.y, b.width, b.height
            FROM screen_history_frame f
            JOIN screen_history_ocr_box b ON b.frame_id = f.id
            WHERE f.source = ? AND f.source_identifier = ?
            ORDER BY b.ordinal ASC
            LIMIT 1000;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(source.rawValue, to: statement, at: 1)
        try SQLiteValue.bind(sourceIdentifier, to: statement, at: 2)
        var boxes: [ScreenHistoryOCRBox] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return boxes }
            guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
            boxes.append(ScreenHistoryOCRBox(
                ordinal: Int(sqlite3_column_int64(statement, 0)),
                text: SQLiteValue.text(statement, 1) ?? "",
                x: sqlite3_column_double(statement, 2),
                y: sqlite3_column_double(statement, 3),
                width: sqlite3_column_double(statement, 4),
                height: sqlite3_column_double(statement, 5)
            ))
        }
    }

    func applyMigration(
        _ frame: ScreenHistoryFrameInput,
        status: ScreenHistoryMigrationStatus,
        migratedAt: Date
    ) throws -> ScreenHistoryMigrationStoreChange {
        guard frame.source == .coast else {
            throw LocalSQLiteError.bind("migration source must be Coast")
        }
        let existingLedger = try migrationLedgerEntry(
            source: frame.source,
            sourceIdentifier: frame.sourceIdentifier
        )
        var existingOwnedID: Int64?
        if let ledgerOwnedID = existingLedger?.ownedFrameID {
            existingOwnedID = ledgerOwnedID
        } else {
            existingOwnedID = try ownedFrameID(
                source: frame.source,
                sourceIdentifier: frame.sourceIdentifier
            )
        }
        let hashDelta = existingLedger?.contentHash == frame.contentHash ? 0 : 1

        if status == .imported,
           existingLedger?.status == .imported,
           existingLedger?.contentHash == frame.contentHash,
           existingOwnedID != nil {
            return ScreenHistoryMigrationStoreChange(ownedRowDelta: 0, hashDelta: 0)
        }

        // Reclassification is a destructive metadata change. Use the same
        // durable file-first queue as retention so an owned copy is removed
        // before its OCR/FTS row. A failed removal leaves both the row and the
        // queue available for a later retry. Unowned Coast paths are retained.
        let removedOwnedRow: Bool
        if status != .imported, let frameID = existingOwnedID {
            try removeFrameForMigrationReclassification(frameID, now: migratedAt)
            existingOwnedID = nil
            removedOwnedRow = true
        } else {
            removedOwnedRow = false
        }

        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            var ownedFrameID = existingOwnedID
            var ownedRowDelta = removedOwnedRow ? -1 : 0
            if status == .imported {
                ownedFrameID = try record(frame)
                if existingOwnedID == nil { ownedRowDelta = 1 }
            }

            let ledger = try database.prepare("""
                INSERT INTO screen_history_migration_ledger(
                    source, source_identifier, owned_frame_id, content_hash,
                    status, migrated_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, source_identifier) DO UPDATE SET
                    owned_frame_id=excluded.owned_frame_id,
                    content_hash=excluded.content_hash,
                    status=excluded.status,
                    migrated_at=excluded.migrated_at;
                """)
            defer { sqlite3_finalize(ledger) }
            try SQLiteValue.bind(frame.source.rawValue, to: ledger, at: 1)
            try SQLiteValue.bind(frame.sourceIdentifier, to: ledger, at: 2)
            try SQLiteValue.bind(ownedFrameID, to: ledger, at: 3)
            try SQLiteValue.bind(frame.contentHash, to: ledger, at: 4)
            try SQLiteValue.bind(status.rawValue, to: ledger, at: 5)
            try SQLiteValue.bind(migratedAt.timeIntervalSince1970, to: ledger, at: 6)
            guard sqlite3_step(ledger) == SQLITE_DONE else {
                throw LocalSQLiteError.step(database.message())
            }
            if status != .imported {
                let exclusion = try database.prepare("""
                    INSERT INTO screen_history_exclusion_event(
                        source, source_identifier, reason_code, occurred_at
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(source, source_identifier, reason_code) DO UPDATE SET
                        occurred_at=excluded.occurred_at;
                    """)
                defer { sqlite3_finalize(exclusion) }
                try SQLiteValue.bind(frame.source.rawValue, to: exclusion, at: 1)
                try SQLiteValue.bind(frame.sourceIdentifier, to: exclusion, at: 2)
                try SQLiteValue.bind("migration_\(status.rawValue)", to: exclusion, at: 3)
                try SQLiteValue.bind(migratedAt.timeIntervalSince1970, to: exclusion, at: 4)
                guard sqlite3_step(exclusion) == SQLITE_DONE else {
                    throw LocalSQLiteError.step(database.message())
                }
            }
            try database.execute("COMMIT;")
            return ScreenHistoryMigrationStoreChange(
                ownedRowDelta: ownedRowDelta,
                hashDelta: hashDelta
            )
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    func migrationLedgerCount(
        source: ScreenHistorySource,
        status: ScreenHistoryMigrationStatus?
    ) throws -> Int {
        let sql = status == nil
            ? "SELECT count(*) FROM screen_history_migration_ledger WHERE source = ?;"
            : "SELECT count(*) FROM screen_history_migration_ledger WHERE source = ? AND status = ?;"
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(source.rawValue, to: statement, at: 1)
        if let status { try SQLiteValue.bind(status.rawValue, to: statement, at: 2) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LocalSQLiteError.step(database.message())
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func legacyMediaMigrationRows(
        afterFrameID: Int64?,
        limit: Int
    ) throws -> [ScreenHistoryMediaMigrationRow] {
        let statement = try database.prepare("""
            SELECT f.id, f.source_identifier, f.captured_at, f.application,
                   f.image_locator, f.media_locator, f.media_frame_index
            FROM screen_history_frame f
            JOIN screen_history_migration_ledger m
              ON m.owned_frame_id = f.id
             AND m.source = f.source
             AND m.source_identifier = f.source_identifier
             AND m.status = 'imported'
            WHERE f.source = 'coast'
              AND (? IS NULL OR f.id > ?)
              AND (f.image_locator IS NOT NULL OR f.media_locator IS NOT NULL)
            ORDER BY f.id ASC
            LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(afterFrameID, to: statement, at: 1)
        try SQLiteValue.bind(afterFrameID, to: statement, at: 2)
        try SQLiteValue.bind(Int64(min(max(1, limit), 1_000)), to: statement, at: 3)
        var rows: [ScreenHistoryMediaMigrationRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
            rows.append(ScreenHistoryMediaMigrationRow(
                frameID: sqlite3_column_int64(statement, 0),
                sourceIdentifier: SQLiteValue.text(statement, 1) ?? "",
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                application: SQLiteValue.text(statement, 3),
                imageLocator: SQLiteValue.text(statement, 4),
                mediaLocator: SQLiteValue.text(statement, 5),
                mediaFrameIndex: sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 6))
            ))
        }
    }

    func mediaMigrationLedgerEntry(
        sourcePathHash: String
    ) throws -> ScreenHistoryMediaMigrationLedgerEntry? {
        let statement = try database.prepare("""
            SELECT source_path_hash, destination_locator, byte_count,
                   content_hash, status
            FROM screen_history_media_migration_ledger
            WHERE source_path_hash = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(sourcePathHash, to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW,
              let storedPathHash = SQLiteValue.text(statement, 0),
              let statusText = SQLiteValue.text(statement, 4),
              let status = ScreenHistoryMediaMigrationStatus(rawValue: statusText)
        else { throw LocalSQLiteError.step(database.message()) }
        return ScreenHistoryMediaMigrationLedgerEntry(
            sourcePathHash: storedPathHash,
            destinationLocator: SQLiteValue.text(statement, 1),
            byteCount: sqlite3_column_int64(statement, 2),
            contentHash: SQLiteValue.text(statement, 3),
            status: status
        )
    }

    @discardableResult
    func recordMediaMigrationOutcome(
        sourcePathHash: String,
        destinationLocator: String?,
        byteCount: Int64,
        contentHash: String?,
        status: ScreenHistoryMediaMigrationStatus,
        migratedAt: Date
    ) throws -> Int {
        guard sourcePathHash.count == 64, byteCount >= 0 else {
            throw LocalSQLiteError.bind("invalid media migration outcome")
        }
        let current = try mediaMigrationLedgerEntry(sourcePathHash: sourcePathHash)
        let next = ScreenHistoryMediaMigrationLedgerEntry(
            sourcePathHash: sourcePathHash,
            destinationLocator: destinationLocator,
            byteCount: byteCount,
            contentHash: contentHash,
            status: status
        )
        if current == next { return 0 }
        let statement = try database.prepare("""
            INSERT INTO screen_history_media_migration_ledger(
                source_path_hash, destination_locator, byte_count,
                content_hash, status, migrated_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_path_hash) DO UPDATE SET
                destination_locator=excluded.destination_locator,
                byte_count=excluded.byte_count,
                content_hash=excluded.content_hash,
                status=excluded.status,
                migrated_at=excluded.migrated_at;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(sourcePathHash, to: statement, at: 1)
        try SQLiteValue.bind(destinationLocator, to: statement, at: 2)
        try SQLiteValue.bind(byteCount, to: statement, at: 3)
        try SQLiteValue.bind(contentHash, to: statement, at: 4)
        try SQLiteValue.bind(status.rawValue, to: statement, at: 5)
        try SQLiteValue.bind(migratedAt.timeIntervalSince1970, to: statement, at: 6)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LocalSQLiteError.step(database.message())
        }
        return 1
    }

    /// Rewrites only the named locator on the exact Coast row already accepted
    /// by the metadata migration gate. The caller supplies a verified copy.
    func updateImportedMediaLocator(
        _ reference: ScreenHistoryMediaReference,
        destinationLocator: String,
        byteCount: Int64,
        contentHash: String,
        sourcePathHash: String,
        migratedAt: Date
    ) throws -> ScreenHistoryMediaMigrationStoreChange {
        guard destinationLocator.hasPrefix("/"), byteCount >= 0,
              contentHash.count == 64, sourcePathHash.count == 64
        else { throw LocalSQLiteError.bind("invalid verified media copy") }

        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let ledgerDelta = try recordMediaMigrationOutcome(
                sourcePathHash: sourcePathHash,
                destinationLocator: destinationLocator,
                byteCount: byteCount,
                contentHash: contentHash,
                status: .copied,
                migratedAt: migratedAt
            )
            let locatorColumn = reference.kind == .image ? "image_locator" : "media_locator"
            let frameIndexCondition: String
            if reference.kind == .video {
                frameIndexCondition = reference.mediaFrameIndex == nil
                    ? "AND media_frame_index IS NULL"
                    : "AND media_frame_index = ?"
            } else {
                frameIndexCondition = ""
            }
            let wasAlreadyMigrated = try importedMediaLocatorMatches(
                reference,
                locator: destinationLocator
            )
            let media = try database.prepare("""
                INSERT INTO screen_history_media(
                    locator, kind, frame_count, first_seen_at, last_seen_at
                )
                SELECT ?, ?, media_frame_count, captured_at, captured_at
                FROM screen_history_frame
                WHERE id = ? AND source = 'coast' AND source_identifier = ?
                  AND (\(locatorColumn) = ? OR \(locatorColumn) = ?)
                  \(frameIndexCondition)
                LIMIT 1
                ON CONFLICT(locator) DO UPDATE SET
                    frame_count=COALESCE(excluded.frame_count, frame_count),
                    first_seen_at=min(first_seen_at, excluded.first_seen_at),
                    last_seen_at=max(last_seen_at, excluded.last_seen_at)
                RETURNING id;
                """)
            defer { sqlite3_finalize(media) }
            try SQLiteValue.bind(destinationLocator, to: media, at: 1)
            try SQLiteValue.bind(reference.kind.rawValue, to: media, at: 2)
            try SQLiteValue.bind(reference.frameID, to: media, at: 3)
            try SQLiteValue.bind(reference.sourceIdentifier, to: media, at: 4)
            try SQLiteValue.bind(reference.legacyLocator, to: media, at: 5)
            try SQLiteValue.bind(destinationLocator, to: media, at: 6)
            if reference.kind == .video, let frameIndex = reference.mediaFrameIndex {
                try SQLiteValue.bind(Int64(frameIndex), to: media, at: 7)
            }
            guard sqlite3_step(media) == SQLITE_ROW else {
                throw LocalSQLiteError.step("imported media row no longer matches its verified source locator")
            }
            let mediaReferenceID = sqlite3_column_int64(media, 0)
            guard sqlite3_step(media) == SQLITE_DONE else {
                throw LocalSQLiteError.step(database.message())
            }
            let statement = try database.prepare("""
                UPDATE screen_history_frame
                SET \(locatorColumn) = ?, media_ref_id = ?
                WHERE id = ? AND source = 'coast' AND source_identifier = ?
                  AND (\(locatorColumn) = ? OR \(locatorColumn) = ?)
                  \(frameIndexCondition)
                  AND EXISTS (
                      SELECT 1 FROM screen_history_migration_ledger m
                      WHERE m.owned_frame_id = screen_history_frame.id
                        AND m.source = 'coast'
                        AND m.source_identifier = screen_history_frame.source_identifier
                        AND m.status = 'imported'
                  )
                RETURNING id;
                """)
            defer { sqlite3_finalize(statement) }
            try SQLiteValue.bind(destinationLocator, to: statement, at: 1)
            try SQLiteValue.bind(mediaReferenceID, to: statement, at: 2)
            try SQLiteValue.bind(reference.frameID, to: statement, at: 3)
            try SQLiteValue.bind(reference.sourceIdentifier, to: statement, at: 4)
            try SQLiteValue.bind(reference.legacyLocator, to: statement, at: 5)
            try SQLiteValue.bind(destinationLocator, to: statement, at: 6)
            if reference.kind == .video, let frameIndex = reference.mediaFrameIndex {
                try SQLiteValue.bind(Int64(frameIndex), to: statement, at: 7)
            }
            let result = sqlite3_step(statement)
            let updatedRowDelta: Int
            if result == SQLITE_ROW {
                updatedRowDelta = wasAlreadyMigrated ? 0 : 1
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LocalSQLiteError.step(database.message())
                }
            } else if result == SQLITE_DONE {
                throw LocalSQLiteError.step("imported media row no longer matches its verified source locator")
            } else {
                throw LocalSQLiteError.step(database.message())
            }
            try database.execute("COMMIT;")
            return ScreenHistoryMediaMigrationStoreChange(
                updatedRowDelta: updatedRowDelta,
                ledgerDelta: ledgerDelta
            )
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    /// Selects one candidate from each chronological bucket and promotes the
    /// first occurrence of each application and media kind within that bucket.
    func migratedMediaMomentSample(limit: Int = 100) throws -> [ScreenHistoryFrame] {
        let boundedLimit = min(max(1, limit), 100)
        let statement = try database.prepare("""
            WITH migrated AS (
                SELECT f.*,
                       CASE WHEN EXISTS (
                           SELECT 1 FROM screen_history_media_migration_ledger ml
                           WHERE ml.status = 'copied'
                             AND ml.destination_locator = f.image_locator
                       ) THEN 'image' ELSE 'video' END AS media_kind
                FROM screen_history_frame f
                WHERE f.source = 'coast'
                  AND EXISTS (
                      SELECT 1 FROM screen_history_media_migration_ledger ml
                      WHERE ml.status = 'copied'
                        AND (ml.destination_locator = f.image_locator
                             OR ml.destination_locator = f.media_locator)
                  )
            ), dimensioned AS (
                SELECT migrated.*,
                       row_number() OVER (
                           PARTITION BY COALESCE(application, ''), media_kind
                           ORDER BY captured_at ASC, id ASC
                       ) AS dimension_rank
                FROM migrated
            ), bucketed AS (
                SELECT dimensioned.*,
                       ntile(\(boundedLimit)) OVER (ORDER BY captured_at ASC, id ASC) AS time_bucket
                FROM dimensioned
            ), ranked AS (
                SELECT bucketed.*,
                       row_number() OVER (
                           PARTITION BY time_bucket
                           ORDER BY dimension_rank ASC, lower(COALESCE(application, '')) ASC,
                                    media_kind ASC, id ASC
                       ) AS bucket_rank
                FROM bucketed
            )
            SELECT id, source, source_identifier, captured_at,
                   application, bundle_identifier, domain, window_title,
                   substr(ocr_text, 1, 20000), image_locator, media_locator,
                   media_frame_index, media_frame_count, capture_display_x,
                   capture_display_y, capture_display_width, capture_display_height,
                   byte_count, sequence_identifier, sequence_ordinal, content_hash
            FROM ranked
            WHERE bucket_rank = 1
            ORDER BY captured_at ASC, id ASC
            LIMIT \(boundedLimit);
            """)
        defer { sqlite3_finalize(statement) }
        return try readFrames(statement)
    }

    /// Builds a deterministic retirement-review sample from the complete
    /// metadata population marked imported by the Coast migration ledger.
    /// The query never reads an image or video. Chronological buckets provide
    /// time spread, while the within-bucket rank promotes application and
    /// media-kind diversity without random state.
    func coastRetirementSample(
        limit: Int = ScreenHistoryRetirementReadiness.requiredSampleSize
    ) throws -> ScreenHistoryRetirementSamplePopulation {
        let boundedLimit = min(
            max(1, limit),
            ScreenHistoryRetirementReadiness.requiredSampleSize
        )
        let counts = try database.prepare("""
            SELECT count(*)
            FROM screen_history_migration_ledger m
            LEFT JOIN screen_history_frame f
              ON f.id = m.owned_frame_id
             AND f.source = m.source
             AND f.source_identifier = m.source_identifier
            WHERE m.source = 'coast' AND m.status = 'imported';
            """)
        defer { sqlite3_finalize(counts) }
        guard sqlite3_step(counts) == SQLITE_ROW else {
            throw LocalSQLiteError.step(database.message())
        }
        let totalImportedMoments = Int(sqlite3_column_int64(counts, 0))
        let mediaIntegrity = try coastMediaIntegrityCounts()
        let mediaIntegrityFailureMoments = mediaIntegrity.failures
        let eligibleImportedMoments = mediaIntegrity.eligible
        let normalizedStructureDrift = try normalizedStructureDriftCount()

        let statement = try database.prepare("""
            WITH eligible AS (
                SELECT f.*,
                       lower(COALESCE(NULLIF(trim(f.application), ''), '(unknown)')) AS app_key,
                       printf('%.3f:%.3f:%.3f:%.3f',
                              COALESCE(f.capture_display_x, 0),
                              COALESCE(f.capture_display_y, 0),
                              COALESCE(f.capture_display_width, 0),
                              COALESCE(f.capture_display_height, 0)) AS display_key,
                       CASE
                           WHEN NULLIF(trim(f.image_locator), '') IS NOT NULL
                            AND NULLIF(trim(f.media_locator), '') IS NOT NULL THEN 'both'
                           WHEN NULLIF(trim(f.image_locator), '') IS NOT NULL THEN 'image'
                           WHEN NULLIF(trim(f.media_locator), '') IS NOT NULL THEN 'video'
                           ELSE 'none'
                       END AS media_kind
                FROM screen_history_migration_ledger m
                JOIN screen_history_frame f
                  ON f.id = m.owned_frame_id
                 AND f.source = m.source
                 AND f.source_identifier = m.source_identifier
                WHERE m.source = 'coast'
                  AND m.status = 'imported'
                  AND length(f.content_hash) = 64
                  AND f.content_hash = m.content_hash
                  AND (f.image_locator IS NOT NULL OR f.media_locator IS NOT NULL)
                  AND EXISTS (
                      SELECT 1 FROM screen_history_media_migration_ledger ml
                      WHERE ml.status = 'copied'
                        AND ml.destination_locator = COALESCE(f.image_locator, f.media_locator)
                  )
            ), dimensioned AS (
                SELECT eligible.*,
                       row_number() OVER (
                           PARTITION BY app_key, media_kind, display_key
                           ORDER BY captured_at ASC, id ASC
                       ) AS dimension_rank
                FROM eligible
            ), bucketed AS (
                SELECT dimensioned.*,
                       ntile(\(boundedLimit)) OVER (
                           ORDER BY captured_at ASC, id ASC
                       ) AS time_bucket
                FROM dimensioned
            ), ranked AS (
                SELECT bucketed.*,
                       row_number() OVER (
                           PARTITION BY time_bucket
                           ORDER BY dimension_rank ASC, app_key ASC,
                                    media_kind ASC, display_key ASC, content_hash ASC, id ASC
                       ) AS bucket_rank
                FROM bucketed
            )
            SELECT id, source, source_identifier, captured_at,
                   application, bundle_identifier, domain, window_title,
                   substr(ocr_text, 1, 20000), image_locator, media_locator,
                   media_frame_index, media_frame_count, capture_display_x,
                   capture_display_y, capture_display_width, capture_display_height,
                   byte_count, sequence_identifier, sequence_ordinal, content_hash
            FROM ranked
            WHERE bucket_rank = 1
            ORDER BY captured_at ASC, id ASC
            LIMIT \(boundedLimit);
            """)
        defer { sqlite3_finalize(statement) }
        return ScreenHistoryRetirementSamplePopulation(
            totalImportedMoments: totalImportedMoments,
            eligibleImportedMoments: eligibleImportedMoments,
            mediaIntegrityFailureMoments: mediaIntegrityFailureMoments,
            normalizedStructureDrift: normalizedStructureDrift,
            moments: try readFrames(statement)
        )
    }

    /// Validates every media locator used by a metadata-eligible imported
    /// Coast moment. It emits one count only. Paths, hashes, and media bytes do
    /// not leave this store boundary.
    private func coastMediaIntegrityCounts() throws -> (eligible: Int, failures: Int) {
        let statement = try database.prepare("""
            SELECT f.id, f.image_locator, f.media_locator
            FROM screen_history_migration_ledger migration
            JOIN screen_history_frame f
              ON f.id = migration.owned_frame_id
             AND f.source = migration.source
             AND f.source_identifier = migration.source_identifier
            WHERE migration.source = 'coast'
              AND migration.status = 'imported'
              AND length(f.content_hash) = 64
              AND f.content_hash = migration.content_hash
            ORDER BY f.id ASC;
            """)
        defer { sqlite3_finalize(statement) }
        var validityByLocator: [String: Bool] = [:]
        var eligible = 0
        var failures = 0
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return (eligible, failures) }
            guard result == SQLITE_ROW else {
                throw LocalSQLiteError.step(database.message())
            }
            let locators = [SQLiteValue.text(statement, 1), SQLiteValue.text(statement, 2)]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            let valid = !locators.isEmpty && locators.allSatisfy { locator in
                if let cached = validityByLocator[locator] { return cached }
                let checked = AppLog.attempt("Check media locator against the migration ledger", {
                    try mediaLocatorMatchesMigrationLedger(locator)
                }) == true
                validityByLocator[locator] = checked
                return checked
            }
            if valid {
                eligible += 1
            } else {
                failures += 1
            }
        }
    }

    private func mediaLocatorMatchesMigrationLedger(_ locator: String) throws -> Bool {
        guard locator.hasPrefix("/") else { return false }
        let url = URL(fileURLWithPath: locator).standardizedFileURL
        guard ownedPruneCandidateURL(locator)?.path == url.path,
              !isSymbolicLink(url),
              isRegularPruneFile(url)
        else { return false }

        let statement = try database.prepare("""
            SELECT byte_count, content_hash
            FROM screen_history_media_migration_ledger
            WHERE destination_locator = ? AND status = 'copied'
            ORDER BY source_path_hash ASC;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(locator, to: statement, at: 1)
        var expected: (byteCount: Int64, hash: String)?
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let hash = SQLiteValue.text(statement, 1),
                  hash.count == 64
            else { return false }
            let candidate = (sqlite3_column_int64(statement, 0), hash)
            if let expected,
               expected.byteCount != candidate.0 || expected.hash != candidate.1 {
                return false
            }
            expected = candidate
        }
        guard let expected else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == expected.byteCount else {
            return false
        }
        return try Self.sha256(url: url) == expected.hash
    }

    private nonisolated static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func prune(
        policy: ScreenHistoryRetentionPolicy,
        now: Date = Date()
    ) throws -> ScreenHistoryPruneResult {
        let resumedQueue = try pruneQueueCounts().rows > 0
        var rowsPlanned = 0
        if !resumedQueue {
            rowsPlanned = try planPruneQueue(policy: policy, now: now)
        }

        var outcome = try processPruneQueue(now: now)
        // A resumed queue can reflect an older policy. Once it converges,
        // enforce the policy supplied to this call as one new durable batch.
        if resumedQueue, !outcome.retryRequired, outcome.pendingRows == 0 {
            let additionalRows = try planPruneQueue(policy: policy, now: now)
            rowsPlanned += additionalRows
            if additionalRows > 0 {
                outcome.merge(try processPruneQueue(now: now))
            }
        }

        return ScreenHistoryPruneResult(
            rowsPlanned: rowsPlanned,
            rowsRemoved: outcome.rowsRemoved,
            bytesRemoved: outcome.bytesRemoved,
            filesRemoved: outcome.filesRemoved,
            filesRetainedShared: outcome.filesRetainedShared,
            filesRetainedUnowned: outcome.filesRetainedUnowned,
            filesAbsent: outcome.filesAbsent,
            pendingRows: outcome.pendingRows,
            pendingLocators: outcome.pendingLocators,
            retryRequired: outcome.retryRequired,
            resumedQueue: resumedQueue
        )
    }

    func previewPrune(
        policy: ScreenHistoryRetentionPolicy,
        now: Date = Date()
    ) throws -> ScreenHistoryPrunePreview {
        let candidates = try retentionCandidates(policy: policy, now: now)
        let locators = Set(candidates.flatMap { row in
            [row.image, row.media].compactMap { locator -> String? in
                guard let locator, ownedPruneCandidateURL(locator) != nil else { return nil }
                return locator
            }
        })
        let bytes = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        return ScreenHistoryPrunePreview(
            policy: policy,
            rowsPlanned: candidates.count,
            bytesPlanned: bytes,
            ownedFilesPlanned: locators.count,
            earliestRemoval: candidates.map(\.capturedAt).min(),
            latestRemoval: candidates.map(\.capturedAt).max(),
            retainedBytes: max(0, try totalBytes() - bytes),
            hasPendingQueue: try pruneQueueCounts().rows > 0
        )
    }

    nonisolated static func literalFTSQuery(_ text: String) -> String? {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(24)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")
    }

    private nonisolated static func cleanFilter(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return nil }
        return String(clean.prefix(500))
    }

    private func bind(_ frame: ScreenHistoryFrameInput, to statement: OpaquePointer) throws {
        let boundedOCR = String(
            decoding: Data(frame.ocrText.utf8.prefix(Self.maximumOCRBytes)),
            as: UTF8.self
        ).trimmingCharacters(in: .controlCharacters)
        try SQLiteValue.bind(frame.source.rawValue, to: statement, at: 1)
        try SQLiteValue.bind(String(frame.sourceIdentifier.prefix(500)), to: statement, at: 2)
        try SQLiteValue.bind(frame.capturedAt.timeIntervalSince1970, to: statement, at: 3)
        try SQLiteValue.bind(Self.cleanFilter(frame.application), to: statement, at: 4)
        try SQLiteValue.bind(Self.cleanFilter(frame.bundleIdentifier), to: statement, at: 5)
        try SQLiteValue.bind(Self.cleanFilter(frame.domain), to: statement, at: 6)
        try SQLiteValue.bind(Self.cleanFilter(frame.windowTitle), to: statement, at: 7)
        try SQLiteValue.bind(boundedOCR, to: statement, at: 8)
        try SQLiteValue.bind(frame.imageLocator, to: statement, at: 9)
        try SQLiteValue.bind(frame.mediaLocator, to: statement, at: 10)
        try SQLiteValue.bind(frame.mediaFrameIndex.map(Int64.init), to: statement, at: 11)
        try SQLiteValue.bind(frame.mediaFrameCount.map(Int64.init), to: statement, at: 12)
        try SQLiteValue.bind(frame.displayGeometry?.x, to: statement, at: 13)
        try SQLiteValue.bind(frame.displayGeometry?.y, to: statement, at: 14)
        try SQLiteValue.bind(frame.displayGeometry?.width, to: statement, at: 15)
        try SQLiteValue.bind(frame.displayGeometry?.height, to: statement, at: 16)
        try SQLiteValue.bind(max(0, frame.byteCount), to: statement, at: 17)
        try SQLiteValue.bind(Self.cleanFilter(frame.sequenceIdentifier), to: statement, at: 18)
        try SQLiteValue.bind(frame.sequenceOrdinal.map(Int64.init), to: statement, at: 19)
        try SQLiteValue.bind(frame.contentHash, to: statement, at: 20)
    }

    private func readFrames(_ statement: OpaquePointer) throws -> [ScreenHistoryFrame] {
        var rows: [ScreenHistoryFrame] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
            rows.append(ScreenHistoryFrame(
                id: sqlite3_column_int64(statement, 0),
                source: ScreenHistorySource(rawValue: SQLiteValue.text(statement, 1) ?? "") ?? .owned,
                sourceIdentifier: SQLiteValue.text(statement, 2) ?? "",
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                application: SQLiteValue.text(statement, 4),
                bundleIdentifier: SQLiteValue.text(statement, 5),
                domain: SQLiteValue.text(statement, 6),
                windowTitle: SQLiteValue.text(statement, 7),
                ocrText: SQLiteValue.text(statement, 8) ?? "",
                imageLocator: SQLiteValue.text(statement, 9),
                mediaLocator: SQLiteValue.text(statement, 10),
                mediaFrameIndex: sqlite3_column_type(statement, 11) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 11)),
                mediaFrameCount: sqlite3_column_type(statement, 12) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 12)),
                displayGeometry: Self.displayGeometry(statement, startingAt: 13),
                byteCount: sqlite3_column_int64(statement, 17),
                sequenceIdentifier: SQLiteValue.text(statement, 18),
                sequenceOrdinal: sqlite3_column_type(statement, 19) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 19)),
                contentHash: SQLiteValue.text(statement, 20) ?? ""
            ))
        }
    }

    private nonisolated func migrateSchemaToVersion2() throws {
        let columns = try tableColumns("screen_history_frame")
        let needsContentHashBackfill = !columns.contains("content_hash")
        if !columns.contains("sequence_identifier") {
            try database.execute("ALTER TABLE screen_history_frame ADD COLUMN sequence_identifier TEXT;")
        }
        if !columns.contains("sequence_ordinal") {
            try database.execute("ALTER TABLE screen_history_frame ADD COLUMN sequence_ordinal INTEGER CHECK(sequence_ordinal IS NULL OR sequence_ordinal >= 0);")
        }
        if !columns.contains("content_hash") {
            try database.execute("ALTER TABLE screen_history_frame ADD COLUMN content_hash TEXT NOT NULL DEFAULT '';")
        }
        if needsContentHashBackfill {
            // A v1 update trigger mirrored every UPDATE into FTS. Updating only
            // the new hash column could therefore issue an FTS delete for a
            // legacy row whose external-content index was incomplete.
            try database.execute("""
                DROP TRIGGER IF EXISTS screen_history_frame_au;
                CREATE TRIGGER screen_history_frame_au
                AFTER UPDATE OF application, domain, window_title, ocr_text ON screen_history_frame BEGIN
                    INSERT INTO screen_history_fts(screen_history_fts, rowid, application, domain, window_title, ocr_text)
                    VALUES ('delete', old.id, old.application, old.domain, old.window_title, old.ocr_text);
                    INSERT INTO screen_history_fts(rowid, application, domain, window_title, ocr_text)
                    VALUES (new.id, new.application, new.domain, new.window_title, new.ocr_text);
                END;
                """)
        }
        try database.execute("""
            CREATE INDEX IF NOT EXISTS screen_history_frame_sequence
                ON screen_history_frame(sequence_identifier, sequence_ordinal, captured_at, id);
            CREATE TABLE IF NOT EXISTS screen_history_migration_ledger (
                source TEXT NOT NULL,
                source_identifier TEXT NOT NULL,
                owned_frame_id INTEGER REFERENCES screen_history_frame(id) ON DELETE SET NULL,
                content_hash TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('imported', 'excluded', 'invalid')),
                migrated_at REAL NOT NULL,
                PRIMARY KEY(source, source_identifier)
            );
            PRAGMA user_version = 2;
            """)
        try backfillMissingContentHashes()
        if needsContentHashBackfill {
            try database.execute("INSERT INTO screen_history_fts(screen_history_fts) VALUES('rebuild');")
        }
    }

    private nonisolated func migrateSchemaToVersion3() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS screen_history_media_migration_ledger (
                source_path_hash TEXT PRIMARY KEY,
                destination_locator TEXT,
                byte_count INTEGER NOT NULL DEFAULT 0 CHECK(byte_count >= 0),
                content_hash TEXT,
                status TEXT NOT NULL CHECK(status IN ('copied', 'missing', 'invalid', 'hash_mismatch', 'failed')),
                migrated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS screen_history_media_migration_status
                ON screen_history_media_migration_ledger(status, migrated_at);
            PRAGMA user_version = 3;
            """)
    }

    private nonisolated func migrateSchemaToVersion4() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS screen_history_prune_queue_row (
                frame_id INTEGER PRIMARY KEY
                    REFERENCES screen_history_frame(id) ON DELETE RESTRICT,
                byte_count INTEGER NOT NULL DEFAULT 0 CHECK(byte_count >= 0),
                planned_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS screen_history_prune_queue_locator (
                locator TEXT PRIMARY KEY,
                attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
                last_error TEXT,
                last_attempt_at REAL
            );
            CREATE TABLE IF NOT EXISTS screen_history_prune_queue_row_locator (
                frame_id INTEGER NOT NULL
                    REFERENCES screen_history_prune_queue_row(frame_id) ON DELETE CASCADE,
                locator TEXT NOT NULL
                    REFERENCES screen_history_prune_queue_locator(locator) ON DELETE CASCADE,
                PRIMARY KEY(frame_id, locator)
            );
            CREATE INDEX IF NOT EXISTS screen_history_prune_queue_locator_attempt
                ON screen_history_prune_queue_locator(last_attempt_at, attempts);
            PRAGMA user_version = 4;
            """)
    }

    private nonisolated func migrateSchemaToVersion5() throws {
        let columns = try tableColumns("screen_history_frame")
        if !columns.contains("media_frame_count") {
            try database.execute("ALTER TABLE screen_history_frame ADD COLUMN media_frame_count INTEGER;")
        }
        if !columns.contains("capture_display_x") {
            try database.execute("ALTER TABLE screen_history_frame ADD COLUMN capture_display_x REAL;")
        }
        if !columns.contains("capture_display_y") {
            try database.execute("ALTER TABLE screen_history_frame ADD COLUMN capture_display_y REAL;")
        }
        if !columns.contains("capture_display_width") {
            try database.execute("ALTER TABLE screen_history_frame ADD COLUMN capture_display_width REAL;")
        }
        if !columns.contains("capture_display_height") {
            try database.execute("ALTER TABLE screen_history_frame ADD COLUMN capture_display_height REAL;")
        }
        try database.execute("PRAGMA user_version = 5;")
    }

    private nonisolated func migrateSchemaToVersion6() throws {
        let columns = try tableColumns("screen_history_frame")
        for column in ["application_ref_id", "domain_ref_id", "sequence_ref_id", "media_ref_id"]
            where !columns.contains(column) {
            try database.execute("ALTER TABLE screen_history_frame ADD COLUMN \(column) INTEGER;")
        }
        try database.execute("""
            CREATE TABLE IF NOT EXISTS screen_history_application (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                identity TEXT NOT NULL UNIQUE,
                bundle_identifier TEXT,
                display_name TEXT,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS screen_history_domain (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                normalized_domain TEXT NOT NULL UNIQUE,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS screen_history_sequence (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                identifier TEXT NOT NULL UNIQUE,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS screen_history_media (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                locator TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL CHECK(kind IN ('image','video')),
                frame_count INTEGER,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS screen_history_ocr_document (
                frame_id INTEGER PRIMARY KEY REFERENCES screen_history_frame(id) ON DELETE CASCADE,
                text_hash TEXT NOT NULL,
                character_count INTEGER NOT NULL CHECK(character_count >= 0)
            );
            CREATE TABLE IF NOT EXISTS screen_history_exclusion_event (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source TEXT NOT NULL,
                source_identifier TEXT NOT NULL,
                reason_code TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                UNIQUE(source, source_identifier, reason_code)
            );
            CREATE INDEX IF NOT EXISTS screen_history_exclusion_event_time
                ON screen_history_exclusion_event(occurred_at);
            """)
        try backfillNormalizedStructure()
        try database.execute("PRAGMA user_version = 6;")
    }

    private nonisolated func migrateSchemaToVersion7() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS screen_history_ocr_box (
                frame_id INTEGER NOT NULL REFERENCES screen_history_frame(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
                text TEXT NOT NULL,
                x REAL NOT NULL,
                y REAL NOT NULL,
                width REAL NOT NULL CHECK(width >= 0),
                height REAL NOT NULL CHECK(height >= 0),
                PRIMARY KEY(frame_id, ordinal)
            );
            CREATE INDEX IF NOT EXISTS screen_history_ocr_box_frame
                ON screen_history_ocr_box(frame_id, ordinal);
            PRAGMA user_version = 7;
            """)
    }

    private nonisolated func backfillNormalizedStructure() throws {
        try database.execute("""
            INSERT OR IGNORE INTO screen_history_application(
                identity, bundle_identifier, display_name, first_seen_at, last_seen_at
            )
            SELECT CASE WHEN NULLIF(trim(bundle_identifier), '') IS NOT NULL
                        THEN lower(trim(bundle_identifier))
                        ELSE 'name:' || lower(trim(application)) END,
                   NULLIF(trim(bundle_identifier), ''), NULLIF(trim(application), ''),
                   min(captured_at), max(captured_at)
            FROM screen_history_frame
            WHERE NULLIF(trim(application), '') IS NOT NULL
               OR NULLIF(trim(bundle_identifier), '') IS NOT NULL
            GROUP BY 1;
            UPDATE screen_history_frame
            SET application_ref_id = (
                SELECT id FROM screen_history_application a
                WHERE a.identity = CASE
                    WHEN NULLIF(trim(screen_history_frame.bundle_identifier), '') IS NOT NULL
                    THEN lower(trim(screen_history_frame.bundle_identifier))
                    ELSE 'name:' || lower(trim(screen_history_frame.application)) END
            )
            WHERE NULLIF(trim(application), '') IS NOT NULL
               OR NULLIF(trim(bundle_identifier), '') IS NOT NULL;

            INSERT OR IGNORE INTO screen_history_domain(
                normalized_domain, first_seen_at, last_seen_at
            ) SELECT lower(trim(domain)), min(captured_at), max(captured_at)
              FROM screen_history_frame WHERE NULLIF(trim(domain), '') IS NOT NULL GROUP BY 1;
            UPDATE screen_history_frame SET domain_ref_id = (
                SELECT id FROM screen_history_domain d
                WHERE d.normalized_domain = lower(trim(screen_history_frame.domain))
            ) WHERE NULLIF(trim(domain), '') IS NOT NULL;

            INSERT OR IGNORE INTO screen_history_sequence(
                identifier, first_seen_at, last_seen_at
            ) SELECT trim(sequence_identifier), min(captured_at), max(captured_at)
              FROM screen_history_frame
              WHERE NULLIF(trim(sequence_identifier), '') IS NOT NULL GROUP BY 1;
            UPDATE screen_history_frame SET sequence_ref_id = (
                SELECT id FROM screen_history_sequence s
                WHERE s.identifier = trim(screen_history_frame.sequence_identifier)
            ) WHERE NULLIF(trim(sequence_identifier), '') IS NOT NULL;

            INSERT OR IGNORE INTO screen_history_media(
                locator, kind, frame_count, first_seen_at, last_seen_at
            ) SELECT image_locator, 'image', 1, min(captured_at), max(captured_at)
              FROM screen_history_frame WHERE NULLIF(trim(image_locator), '') IS NOT NULL GROUP BY 1;
            INSERT OR IGNORE INTO screen_history_media(
                locator, kind, frame_count, first_seen_at, last_seen_at
            ) SELECT media_locator, 'video', max(media_frame_count), min(captured_at), max(captured_at)
              FROM screen_history_frame WHERE NULLIF(trim(media_locator), '') IS NOT NULL GROUP BY 1;
            UPDATE screen_history_frame SET media_ref_id = (
                SELECT id FROM screen_history_media m
                WHERE m.locator = COALESCE(screen_history_frame.image_locator,
                                           screen_history_frame.media_locator)
            ) WHERE image_locator IS NOT NULL OR media_locator IS NOT NULL;

            INSERT OR REPLACE INTO screen_history_ocr_document(frame_id, text_hash, character_count)
            SELECT id, content_hash, length(ocr_text) FROM screen_history_frame;
            """)
    }

    private nonisolated func tableColumns(_ table: String) throws -> Set<String> {
        precondition(table == "screen_history_frame")
        let statement = try database.prepare("PRAGMA table_info(screen_history_frame);")
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return names }
            guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
            if let name = SQLiteValue.text(statement, 1) { names.insert(name) }
        }
    }

    private nonisolated static func displayGeometry(
        _ statement: OpaquePointer,
        startingAt index: Int32
    ) -> ScreenHistoryDisplayGeometry? {
        guard (0..<4).allSatisfy({ offset in
            sqlite3_column_type(statement, index + Int32(offset)) != SQLITE_NULL
        }) else { return nil }
        return ScreenHistoryDisplayGeometry(
            x: sqlite3_column_double(statement, index),
            y: sqlite3_column_double(statement, index + 1),
            width: sqlite3_column_double(statement, index + 2),
            height: sqlite3_column_double(statement, index + 3)
        )
    }

    private func syncNormalizedStructure(
        frameID: Int64,
        frame: ScreenHistoryFrameInput
    ) throws {
        let capturedAt = frame.capturedAt.timeIntervalSince1970
        let applicationID = try upsertApplication(frame, capturedAt: capturedAt)
        let domainID = try upsertDomain(frame.domain, capturedAt: capturedAt)
        let sequenceID = try upsertSequence(frame.sequenceIdentifier, capturedAt: capturedAt)
        let mediaID = try upsertMedia(frame, capturedAt: capturedAt)
        let update = try database.prepare("""
            UPDATE screen_history_frame
            SET application_ref_id = ?, domain_ref_id = ?, sequence_ref_id = ?, media_ref_id = ?
            WHERE id = ?;
            """)
        defer { sqlite3_finalize(update) }
        try SQLiteValue.bind(applicationID, to: update, at: 1)
        try SQLiteValue.bind(domainID, to: update, at: 2)
        try SQLiteValue.bind(sequenceID, to: update, at: 3)
        try SQLiteValue.bind(mediaID, to: update, at: 4)
        try SQLiteValue.bind(frameID, to: update, at: 5)
        guard sqlite3_step(update) == SQLITE_DONE else {
            throw LocalSQLiteError.step(database.message())
        }

        let ocr = try database.prepare("""
            INSERT INTO screen_history_ocr_document(frame_id, text_hash, character_count)
            VALUES (?, ?, ?)
            ON CONFLICT(frame_id) DO UPDATE SET
                text_hash=excluded.text_hash,
                character_count=excluded.character_count;
            """)
        defer { sqlite3_finalize(ocr) }
        try SQLiteValue.bind(frameID, to: ocr, at: 1)
        try SQLiteValue.bind(Self.sha256(Data(frame.ocrText.utf8)), to: ocr, at: 2)
        try SQLiteValue.bind(Int64(frame.ocrText.count), to: ocr, at: 3)
        guard sqlite3_step(ocr) == SQLITE_DONE else {
            throw LocalSQLiteError.step(database.message())
        }

        let clearBoxes = try database.prepare(
            "DELETE FROM screen_history_ocr_box WHERE frame_id = ?;"
        )
        defer { sqlite3_finalize(clearBoxes) }
        try SQLiteValue.bind(frameID, to: clearBoxes, at: 1)
        guard sqlite3_step(clearBoxes) == SQLITE_DONE else {
            throw LocalSQLiteError.step(database.message())
        }
        guard !frame.ocrBoxes.isEmpty else { return }
        let box = try database.prepare("""
            INSERT INTO screen_history_ocr_box(
                frame_id, ordinal, text, x, y, width, height
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(box) }
        for value in frame.ocrBoxes.prefix(1_000) {
            sqlite3_reset(box)
            sqlite3_clear_bindings(box)
            try SQLiteValue.bind(frameID, to: box, at: 1)
            try SQLiteValue.bind(Int64(value.ordinal), to: box, at: 2)
            try SQLiteValue.bind(String(value.text.prefix(200)), to: box, at: 3)
            try SQLiteValue.bind(value.x, to: box, at: 4)
            try SQLiteValue.bind(value.y, to: box, at: 5)
            try SQLiteValue.bind(max(0, value.width), to: box, at: 6)
            try SQLiteValue.bind(max(0, value.height), to: box, at: 7)
            guard sqlite3_step(box) == SQLITE_DONE else {
                throw LocalSQLiteError.step(database.message())
            }
        }
    }

    private func upsertApplication(
        _ frame: ScreenHistoryFrameInput,
        capturedAt: Double
    ) throws -> Int64? {
        let bundle = Self.cleanFilter(frame.bundleIdentifier)?.lowercased()
        let name = Self.cleanFilter(frame.application)
        guard bundle != nil || name != nil else { return nil }
        let identity = bundle ?? "name:\(name!.lowercased())"
        return try upsertIdentity(
            sql: """
                INSERT INTO screen_history_application(
                    identity, bundle_identifier, display_name, first_seen_at, last_seen_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(identity) DO UPDATE SET
                    bundle_identifier=COALESCE(excluded.bundle_identifier, bundle_identifier),
                    display_name=COALESCE(excluded.display_name, display_name),
                    first_seen_at=min(first_seen_at, excluded.first_seen_at),
                    last_seen_at=max(last_seen_at, excluded.last_seen_at)
                RETURNING id;
                """,
            strings: [identity, bundle, name],
            numbers: [capturedAt, capturedAt]
        )
    }

    private func upsertDomain(_ rawDomain: String?, capturedAt: Double) throws -> Int64? {
        guard let domain = Self.cleanFilter(rawDomain)?.lowercased() else { return nil }
        return try upsertIdentity(
            sql: """
                INSERT INTO screen_history_domain(normalized_domain, first_seen_at, last_seen_at)
                VALUES (?, ?, ?)
                ON CONFLICT(normalized_domain) DO UPDATE SET
                    first_seen_at=min(first_seen_at, excluded.first_seen_at),
                    last_seen_at=max(last_seen_at, excluded.last_seen_at)
                RETURNING id;
                """,
            strings: [domain],
            numbers: [capturedAt, capturedAt]
        )
    }

    private func upsertSequence(_ rawIdentifier: String?, capturedAt: Double) throws -> Int64? {
        guard let identifier = Self.cleanFilter(rawIdentifier) else { return nil }
        return try upsertIdentity(
            sql: """
                INSERT INTO screen_history_sequence(identifier, first_seen_at, last_seen_at)
                VALUES (?, ?, ?)
                ON CONFLICT(identifier) DO UPDATE SET
                    first_seen_at=min(first_seen_at, excluded.first_seen_at),
                    last_seen_at=max(last_seen_at, excluded.last_seen_at)
                RETURNING id;
                """,
            strings: [identifier],
            numbers: [capturedAt, capturedAt]
        )
    }

    private func upsertMedia(_ frame: ScreenHistoryFrameInput, capturedAt: Double) throws -> Int64? {
        let locator = frame.imageLocator ?? frame.mediaLocator
        guard let locator, !locator.isEmpty else { return nil }
        let kind = frame.imageLocator != nil ? "image" : "video"
        return try upsertIdentity(
            sql: """
                INSERT INTO screen_history_media(
                    locator, kind, frame_count, first_seen_at, last_seen_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(locator) DO UPDATE SET
                    frame_count=COALESCE(excluded.frame_count, frame_count),
                    first_seen_at=min(first_seen_at, excluded.first_seen_at),
                    last_seen_at=max(last_seen_at, excluded.last_seen_at)
                RETURNING id;
                """,
            strings: [locator, kind],
            integers: [frame.mediaFrameCount.map(Int64.init)],
            numbers: [capturedAt, capturedAt]
        )
    }

    private func upsertIdentity(
        sql: String,
        strings: [String?],
        integers: [Int64?] = [],
        numbers: [Double]
    ) throws -> Int64 {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        var index: Int32 = 1
        for value in strings {
            try SQLiteValue.bind(value, to: statement, at: index)
            index += 1
        }
        for value in integers {
            try SQLiteValue.bind(value, to: statement, at: index)
            index += 1
        }
        for value in numbers {
            try SQLiteValue.bind(value, to: statement, at: index)
            index += 1
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LocalSQLiteError.step(database.message())
        }
        return sqlite3_column_int64(statement, 0)
    }

    func normalizedStructureDriftCount() throws -> Int {
        let statement = try database.prepare("""
            SELECT count(*) FROM screen_history_frame f
            LEFT JOIN screen_history_application a ON a.id=f.application_ref_id
            LEFT JOIN screen_history_domain d ON d.id=f.domain_ref_id
            LEFT JOIN screen_history_sequence s ON s.id=f.sequence_ref_id
            LEFT JOIN screen_history_media m ON m.id=f.media_ref_id
            LEFT JOIN screen_history_ocr_document o ON o.frame_id=f.id
            WHERE ((f.application IS NOT NULL OR f.bundle_identifier IS NOT NULL)
                   AND (a.id IS NULL OR a.identity != CASE
                       WHEN NULLIF(trim(f.bundle_identifier), '') IS NOT NULL
                       THEN lower(trim(f.bundle_identifier))
                       ELSE 'name:' || lower(trim(f.application)) END))
               OR (f.domain IS NOT NULL AND (d.id IS NULL OR d.normalized_domain != lower(trim(f.domain))))
               OR (f.sequence_identifier IS NOT NULL AND (s.id IS NULL OR s.identifier != trim(f.sequence_identifier)))
               OR ((f.image_locator IS NOT NULL OR f.media_locator IS NOT NULL)
                   AND (m.id IS NULL OR m.locator != COALESCE(f.image_locator, f.media_locator)))
               OR o.frame_id IS NULL;
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LocalSQLiteError.step(database.message())
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Rebuilds the normalized media identity for locators that already point
    /// at owned verified copies. This is idempotent and never opens or removes
    /// a media file.
    func repairNormalizedMediaReferences() throws -> Int {
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try database.execute("""
                INSERT INTO screen_history_media(
                    locator, kind, frame_count, first_seen_at, last_seen_at
                )
                SELECT locator, kind, max(frame_count), min(captured_at), max(captured_at)
                FROM (
                    SELECT COALESCE(image_locator, media_locator) AS locator,
                           CASE WHEN image_locator IS NOT NULL THEN 'image' ELSE 'video' END AS kind,
                           media_frame_count AS frame_count,
                           captured_at
                    FROM screen_history_frame
                    WHERE image_locator IS NOT NULL OR media_locator IS NOT NULL
                ) candidates
                GROUP BY locator, kind
                ON CONFLICT(locator) DO UPDATE SET
                    kind=excluded.kind,
                    frame_count=COALESCE(excluded.frame_count, frame_count),
                    first_seen_at=min(first_seen_at, excluded.first_seen_at),
                    last_seen_at=max(last_seen_at, excluded.last_seen_at);
                """)
            try database.execute("""
                UPDATE screen_history_frame
                SET media_ref_id = (
                    SELECT id FROM screen_history_media
                    WHERE locator = COALESCE(
                        screen_history_frame.image_locator,
                        screen_history_frame.media_locator
                    )
                )
                WHERE (image_locator IS NOT NULL OR media_locator IS NOT NULL)
                  AND NOT EXISTS (
                      SELECT 1 FROM screen_history_media current
                      WHERE current.id = screen_history_frame.media_ref_id
                        AND current.locator = COALESCE(
                            screen_history_frame.image_locator,
                            screen_history_frame.media_locator
                        )
                  );
                """)
            let changes = try database.prepare("SELECT changes();")
            defer { sqlite3_finalize(changes) }
            guard sqlite3_step(changes) == SQLITE_ROW else {
                throw LocalSQLiteError.step(database.message())
            }
            let repaired = Int(sqlite3_column_int64(changes, 0))
            try database.execute("COMMIT;")
            return repaired
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SQLite creates WAL sidecars lazily. At initialization they already
    /// exist after schema setup in WAL mode; harden every present database
    /// file and rely on SQLite's database mode when it recreates a sidecar.
    private nonisolated func restrictDatabaseFilePermissions() throws {
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private nonisolated func backfillMissingContentHashes() throws {
        let select = try database.prepare("""
            SELECT id, source, source_identifier, captured_at, application,
                   bundle_identifier, domain, window_title, ocr_text,
                   image_locator, media_locator, media_frame_index, byte_count,
                   sequence_identifier, sequence_ordinal
            FROM screen_history_frame
            WHERE content_hash = '';
            """)
        defer { sqlite3_finalize(select) }
        let update = try database.prepare("UPDATE screen_history_frame SET content_hash = ? WHERE id = ?;")
        defer { sqlite3_finalize(update) }
        while true {
            let result = sqlite3_step(select)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
            let input = ScreenHistoryFrameInput(
                source: ScreenHistorySource(rawValue: SQLiteValue.text(select, 1) ?? "") ?? .owned,
                sourceIdentifier: SQLiteValue.text(select, 2) ?? "",
                capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(select, 3)),
                application: SQLiteValue.text(select, 4),
                bundleIdentifier: SQLiteValue.text(select, 5),
                domain: SQLiteValue.text(select, 6),
                windowTitle: SQLiteValue.text(select, 7),
                ocrText: SQLiteValue.text(select, 8) ?? "",
                imageLocator: SQLiteValue.text(select, 9),
                mediaLocator: SQLiteValue.text(select, 10),
                mediaFrameIndex: sqlite3_column_type(select, 11) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(select, 11)),
                byteCount: sqlite3_column_int64(select, 12),
                sequenceIdentifier: SQLiteValue.text(select, 13),
                sequenceOrdinal: sqlite3_column_type(select, 14) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(select, 14))
            )
            sqlite3_reset(update)
            sqlite3_clear_bindings(update)
            try SQLiteValue.bind(input.contentHash, to: update, at: 1)
            try SQLiteValue.bind(sqlite3_column_int64(select, 0), to: update, at: 2)
            guard sqlite3_step(update) == SQLITE_DONE else {
                throw LocalSQLiteError.step(database.message())
            }
        }
    }

    private func totalBytes() throws -> Int64 {
        let statement = try database.prepare("SELECT COALESCE(sum(byte_count), 0) FROM screen_history_frame;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
        return sqlite3_column_int64(statement, 0)
    }

    private struct PruneQueueCounts {
        let rows: Int
        let locators: Int
    }

    private struct PruneProcessingOutcome {
        var rowsRemoved = 0
        var bytesRemoved: Int64 = 0
        var filesRemoved = 0
        var filesRetainedShared = 0
        var filesRetainedUnowned = 0
        var filesAbsent = 0
        var pendingRows = 0
        var pendingLocators = 0
        var retryRequired = false

        mutating func merge(_ other: Self) {
            rowsRemoved += other.rowsRemoved
            bytesRemoved += other.bytesRemoved
            filesRemoved += other.filesRemoved
            filesRetainedShared += other.filesRetainedShared
            filesRetainedUnowned += other.filesRetainedUnowned
            filesAbsent += other.filesAbsent
            pendingRows = other.pendingRows
            pendingLocators = other.pendingLocators
            retryRequired = other.retryRequired
        }
    }

    private func pruneQueueCounts() throws -> PruneQueueCounts {
        let statement = try database.prepare("""
            SELECT
                (SELECT count(*) FROM screen_history_prune_queue_row),
                (SELECT count(*) FROM screen_history_prune_queue_locator);
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LocalSQLiteError.step(database.message())
        }
        return PruneQueueCounts(
            rows: Int(sqlite3_column_int64(statement, 0)),
            locators: Int(sqlite3_column_int64(statement, 1))
        )
    }

    /// Records the exact row IDs and locators before any filesystem change.
    /// Only one batch is active, which keeps retries bounded and deterministic.
    private func planPruneQueue(
        policy: ScreenHistoryRetentionPolicy,
        now: Date
    ) throws -> Int {
        guard try pruneQueueCounts().rows == 0 else { return 0 }
        let candidates = try retentionCandidates(policy: policy, now: now)
        guard !candidates.isEmpty else { return 0 }

        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let insertRow = try database.prepare("""
                INSERT INTO screen_history_prune_queue_row(frame_id, byte_count, planned_at)
                VALUES (?, ?, ?);
                """)
            defer { sqlite3_finalize(insertRow) }
            let insertLocator = try database.prepare("""
                INSERT OR IGNORE INTO screen_history_prune_queue_locator(locator)
                VALUES (?);
                """)
            defer { sqlite3_finalize(insertLocator) }
            let mapLocator = try database.prepare("""
                INSERT OR IGNORE INTO screen_history_prune_queue_row_locator(frame_id, locator)
                VALUES (?, ?);
                """)
            defer { sqlite3_finalize(mapLocator) }

            for row in candidates {
                sqlite3_reset(insertRow)
                sqlite3_clear_bindings(insertRow)
                try SQLiteValue.bind(row.id, to: insertRow, at: 1)
                try SQLiteValue.bind(row.bytes, to: insertRow, at: 2)
                try SQLiteValue.bind(now.timeIntervalSince1970, to: insertRow, at: 3)
                guard sqlite3_step(insertRow) == SQLITE_DONE else {
                    throw LocalSQLiteError.step(database.message())
                }

                let rowLocators: Set<String> = Set([row.image, row.media].compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                })
                for locator in rowLocators {
                    sqlite3_reset(insertLocator)
                    sqlite3_clear_bindings(insertLocator)
                    try SQLiteValue.bind(locator, to: insertLocator, at: 1)
                    guard sqlite3_step(insertLocator) == SQLITE_DONE else {
                        throw LocalSQLiteError.step(database.message())
                    }
                    sqlite3_reset(mapLocator)
                    sqlite3_clear_bindings(mapLocator)
                    try SQLiteValue.bind(row.id, to: mapLocator, at: 1)
                    try SQLiteValue.bind(locator, to: mapLocator, at: 2)
                    guard sqlite3_step(mapLocator) == SQLITE_DONE else {
                        throw LocalSQLiteError.step(database.message())
                    }
                }
            }
            try database.execute("COMMIT;")
            return candidates.count
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private typealias PruneCandidate = (
        id: Int64,
        capturedAt: Date,
        bytes: Int64,
        image: String?,
        media: String?
    )

    private func retentionCandidates(
        policy: ScreenHistoryRetentionPolicy,
        now: Date
    ) throws -> [PruneCandidate] {
        var candidates: [PruneCandidate] = []
        if let days = policy.retentionDays {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
            candidates += try pruningCandidates(where: "captured_at < ?", number: cutoff)
        }

        let selected = Set(candidates.map(\.id))
        let selectedBytes = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        if let cap = policy.storageCapBytes {
            let retainedBytes = try totalBytes() - selectedBytes
            if retainedBytes > cap {
                var bytesToRemove = retainedBytes - cap
                for row in try pruningCandidates(where: nil, number: nil) where !selected.contains(row.id) {
                    candidates.append(row)
                    bytesToRemove -= row.bytes
                    if bytesToRemove <= 0 { break }
                }
            }
        }
        return candidates
    }

    private func processPruneQueue(now: Date) throws -> PruneProcessingOutcome {
        let initialCounts = try pruneQueueCounts()
        guard initialCounts.rows > 0 else { return PruneProcessingOutcome() }
        var outcome = PruneProcessingOutcome()
        var retryRequired = false

        for locator in try queuedPruneLocators() {
            if try hasNonqueuedReference(to: locator) {
                outcome.filesRetainedShared += 1
                continue
            }
            guard let candidateURL = ownedPruneCandidateURL(locator) else {
                // Unowned paths, including Coast source media, are never
                // removed by retention. Removing our metadata is safe.
                outcome.filesRetainedUnowned += 1
                continue
            }
            if isSymbolicLink(candidateURL) {
                try recordPruneFailure(locator: locator, message: "symbolic links are not removable", now: now)
                retryRequired = true
                continue
            }
            guard FileManager.default.fileExists(atPath: candidateURL.path) else {
                outcome.filesAbsent += 1
                continue
            }
            guard isRegularPruneFile(candidateURL) else {
                try recordPruneFailure(locator: locator, message: "locator is not a regular file", now: now)
                retryRequired = true
                continue
            }
            do {
                try removeMediaFile(candidateURL)
                outcome.filesRemoved += 1
                try afterMediaRemoval?(candidateURL)
            } catch {
                try recordPruneFailure(
                    locator: locator,
                    message: String(describing: error),
                    now: now
                )
                retryRequired = true
            }
        }

        if retryRequired {
            let pending = try pruneQueueCounts()
            outcome.pendingRows = pending.rows
            outcome.pendingLocators = pending.locators
            outcome.retryRequired = true
            return outcome
        }

        let finalized = try finalizePruneQueue()
        outcome.rowsRemoved = finalized.rows
        outcome.bytesRemoved = finalized.bytes
        return outcome
    }

    /// Removes one imported frame through a durable filesystem-first queue.
    /// This is also the recovery entry point after a previous deletion error
    /// or an interruption between file removal and metadata removal.
    private func removeFrameForMigrationReclassification(
        _ frameID: Int64,
        now: Date
    ) throws {
        if try pruneQueueCounts().rows > 0 {
            let resumed = try processPruneQueue(now: now)
            guard !resumed.retryRequired else {
                throw LocalSQLiteError.step("owned media removal is pending retry")
            }
        }

        guard try frameExists(frameID) else { return }
        try planPruneQueue(frameID: frameID, now: now)
        let outcome = try processPruneQueue(now: now)
        guard !outcome.retryRequired, try !frameExists(frameID) else {
            throw LocalSQLiteError.step("owned media removal is pending retry")
        }
    }

    private func frameExists(_ frameID: Int64) throws -> Bool {
        let statement = try database.prepare("SELECT 1 FROM screen_history_frame WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(frameID, to: statement, at: 1)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw LocalSQLiteError.step(database.message())
    }

    private func planPruneQueue(frameID: Int64, now: Date) throws {
        guard try pruneQueueCounts().rows == 0 else {
            throw LocalSQLiteError.step("a media removal queue is already active")
        }
        let select = try database.prepare("""
            SELECT byte_count, image_locator, media_locator
            FROM screen_history_frame
            WHERE id = ?;
            """)
        defer { sqlite3_finalize(select) }
        try SQLiteValue.bind(frameID, to: select, at: 1)
        let result = sqlite3_step(select)
        if result == SQLITE_DONE { return }
        guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
        let byteCount = sqlite3_column_int64(select, 0)
        let locators = Set([
            SQLiteValue.text(select, 1),
            SQLiteValue.text(select, 2),
        ].compactMap { locator -> String? in
            guard let locator, !locator.isEmpty else { return nil }
            return locator
        })

        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let insertRow = try database.prepare("""
                INSERT INTO screen_history_prune_queue_row(frame_id, byte_count, planned_at)
                VALUES (?, ?, ?);
                """)
            defer { sqlite3_finalize(insertRow) }
            try SQLiteValue.bind(frameID, to: insertRow, at: 1)
            try SQLiteValue.bind(byteCount, to: insertRow, at: 2)
            try SQLiteValue.bind(now.timeIntervalSince1970, to: insertRow, at: 3)
            guard sqlite3_step(insertRow) == SQLITE_DONE else {
                throw LocalSQLiteError.step(database.message())
            }

            let insertLocator = try database.prepare("""
                INSERT OR IGNORE INTO screen_history_prune_queue_locator(locator)
                VALUES (?);
                """)
            defer { sqlite3_finalize(insertLocator) }
            let mapLocator = try database.prepare("""
                INSERT OR IGNORE INTO screen_history_prune_queue_row_locator(frame_id, locator)
                VALUES (?, ?);
                """)
            defer { sqlite3_finalize(mapLocator) }
            for locator in locators {
                sqlite3_reset(insertLocator)
                sqlite3_clear_bindings(insertLocator)
                try SQLiteValue.bind(locator, to: insertLocator, at: 1)
                guard sqlite3_step(insertLocator) == SQLITE_DONE else {
                    throw LocalSQLiteError.step(database.message())
                }
                sqlite3_reset(mapLocator)
                sqlite3_clear_bindings(mapLocator)
                try SQLiteValue.bind(frameID, to: mapLocator, at: 1)
                try SQLiteValue.bind(locator, to: mapLocator, at: 2)
                guard sqlite3_step(mapLocator) == SQLITE_DONE else {
                    throw LocalSQLiteError.step(database.message())
                }
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private func queuedPruneLocators() throws -> [String] {
        let statement = try database.prepare("""
            SELECT locator FROM screen_history_prune_queue_locator
            ORDER BY locator ASC;
            """)
        defer { sqlite3_finalize(statement) }
        var locators: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return locators }
            guard result == SQLITE_ROW, let locator = SQLiteValue.text(statement, 0) else {
                throw LocalSQLiteError.step(database.message())
            }
            locators.append(locator)
        }
    }

    private func hasNonqueuedReference(to locator: String) throws -> Bool {
        let statement = try database.prepare("""
            SELECT 1
            FROM screen_history_frame f
            WHERE (f.image_locator = ? OR f.media_locator = ?)
              AND NOT EXISTS (
                  SELECT 1 FROM screen_history_prune_queue_row q
                  WHERE q.frame_id = f.id
              )
            LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(locator, to: statement, at: 1)
        try SQLiteValue.bind(locator, to: statement, at: 2)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw LocalSQLiteError.step(database.message())
    }

    /// Returns a lexical path inside an owned root only when resolving its
    /// parent cannot escape that root. The final component is left unresolved
    /// so the caller can reject a symlink before touching it.
    private func ownedPruneCandidateURL(_ locator: String) -> URL? {
        guard locator.hasPrefix("/") else { return nil }
        let candidate = URL(fileURLWithPath: locator).standardizedFileURL
        for rootURL in ownedMediaRootURLs {
            let lexicalRoot = rootURL.standardizedFileURL
            // An explicitly configured root must be a real directory. A root
            // symlink could redirect deletion into Coast or another unowned
            // tree even when the child locator looks lexically safe.
            guard !isSymbolicLink(lexicalRoot) else { continue }
            guard candidate.path.hasPrefix(lexicalRoot.path + "/") else { continue }
            let resolvedRoot = lexicalRoot.resolvingSymlinksInPath()
            let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
            guard resolvedParent.path == resolvedRoot.path
                    || resolvedParent.path.hasPrefix(resolvedRoot.path + "/")
            else { return nil }
            return candidate
        }
        return nil
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        guard result == 0 else { return false }
        return (information.st_mode & S_IFMT) == S_IFLNK
    }

    private func isRegularPruneFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else { return false }
        return type == .typeRegular
    }

    private func recordPruneFailure(locator: String, message: String, now: Date) throws {
        let statement = try database.prepare("""
            UPDATE screen_history_prune_queue_locator
            SET attempts = attempts + 1,
                last_error = ?,
                last_attempt_at = ?
            WHERE locator = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(String(message.prefix(500)), to: statement, at: 1)
        try SQLiteValue.bind(now.timeIntervalSince1970, to: statement, at: 2)
        try SQLiteValue.bind(locator, to: statement, at: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LocalSQLiteError.step(database.message())
        }
    }

    private func finalizePruneQueue() throws -> (rows: Int, bytes: Int64) {
        let statement = try database.prepare("""
            SELECT frame_id, byte_count
            FROM screen_history_prune_queue_row
            ORDER BY frame_id ASC;
            """)
        var rows: [(id: Int64, bytes: Int64)] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                sqlite3_finalize(statement)
                throw LocalSQLiteError.step(database.message())
            }
            rows.append((sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1)))
        }
        sqlite3_finalize(statement)
        guard !rows.isEmpty else { return (0, 0) }

        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try database.execute("DELETE FROM screen_history_prune_queue_row_locator;")
            try database.execute("DELETE FROM screen_history_prune_queue_locator;")
            try database.execute("DELETE FROM screen_history_prune_queue_row;")
            let delete = try database.prepare("DELETE FROM screen_history_frame WHERE id = ?;")
            defer { sqlite3_finalize(delete) }
            for row in rows {
                sqlite3_reset(delete)
                sqlite3_clear_bindings(delete)
                try SQLiteValue.bind(row.id, to: delete, at: 1)
                guard sqlite3_step(delete) == SQLITE_DONE else {
                    throw LocalSQLiteError.step(database.message())
                }
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
        // The transaction is already durable. A busy reader must not turn a
        // completed prune into a reported failure.
        AppLog.attempt("Checkpoint screen history WAL after prune") {
            try database.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }
        return (rows.count, rows.reduce(Int64(0)) { $0 + $1.bytes })
    }

    private struct MigrationLedgerEntry {
        let ownedFrameID: Int64?
        let contentHash: String
        let status: ScreenHistoryMigrationStatus
    }

    private func migrationLedgerEntry(
        source: ScreenHistorySource,
        sourceIdentifier: String
    ) throws -> MigrationLedgerEntry? {
        let statement = try database.prepare("""
            SELECT owned_frame_id, content_hash, status
            FROM screen_history_migration_ledger
            WHERE source = ? AND source_identifier = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(source.rawValue, to: statement, at: 1)
        try SQLiteValue.bind(sourceIdentifier, to: statement, at: 2)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW,
              let contentHash = SQLiteValue.text(statement, 1),
              let statusValue = SQLiteValue.text(statement, 2),
              let status = ScreenHistoryMigrationStatus(rawValue: statusValue)
        else { throw LocalSQLiteError.step(database.message()) }
        return MigrationLedgerEntry(
            ownedFrameID: sqlite3_column_type(statement, 0) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 0),
            contentHash: contentHash,
            status: status
        )
    }

    private func ownedFrameID(
        source: ScreenHistorySource,
        sourceIdentifier: String
    ) throws -> Int64? {
        let statement = try database.prepare("""
            SELECT id FROM screen_history_frame
            WHERE source = ? AND source_identifier = ?;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(source.rawValue, to: statement, at: 1)
        try SQLiteValue.bind(sourceIdentifier, to: statement, at: 2)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
        return sqlite3_column_int64(statement, 0)
    }

    private func importedMediaLocatorMatches(
        _ reference: ScreenHistoryMediaReference,
        locator: String
    ) throws -> Bool {
        let locatorColumn = reference.kind == .image ? "image_locator" : "media_locator"
        let frameIndexCondition: String
        if reference.kind == .video {
            frameIndexCondition = reference.mediaFrameIndex == nil
                ? "AND media_frame_index IS NULL"
                : "AND media_frame_index = ?"
        } else {
            frameIndexCondition = ""
        }
        let statement = try database.prepare("""
            SELECT 1 FROM screen_history_frame f
            WHERE f.id = ? AND f.source = 'coast' AND f.source_identifier = ?
              AND f.\(locatorColumn) = ?
              \(frameIndexCondition)
              AND EXISTS (
                  SELECT 1 FROM screen_history_migration_ledger m
                  WHERE m.owned_frame_id = f.id
                    AND m.source = 'coast'
                    AND m.source_identifier = f.source_identifier
                    AND m.status = 'imported'
              );
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(reference.frameID, to: statement, at: 1)
        try SQLiteValue.bind(reference.sourceIdentifier, to: statement, at: 2)
        try SQLiteValue.bind(locator, to: statement, at: 3)
        if reference.kind == .video, let frameIndex = reference.mediaFrameIndex {
            try SQLiteValue.bind(Int64(frameIndex), to: statement, at: 4)
        }
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw LocalSQLiteError.step(database.message())
    }

    private func pruningCandidates(
        where condition: String?,
        number: Double?
    ) throws -> [PruneCandidate] {
        let statement = try database.prepare("""
            SELECT id, captured_at, byte_count, image_locator, media_locator
            FROM screen_history_frame
            \(condition.map { "WHERE \($0)" } ?? "")
            ORDER BY captured_at ASC, id ASC;
            """)
        defer { sqlite3_finalize(statement) }
        if let number { try SQLiteValue.bind(number, to: statement, at: 1) }
        var rows: [PruneCandidate] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
            rows.append((
                sqlite3_column_int64(statement, 0),
                Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                sqlite3_column_int64(statement, 2),
                SQLiteValue.text(statement, 3),
                SQLiteValue.text(statement, 4)
            ))
        }
    }
}
