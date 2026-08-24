import Foundation
import SQLite3
import CryptoKit

actor CoastLegacyReader: CoastLegacyReading {
    nonisolated static let maximumImportRows = 500
    nonisolated static let maximumOCRCharacters = 20_000

    nonisolated let databaseURL: URL
    nonisolated let contentRootURL: URL

    private enum BoundValue {
        case text(String)
        case number(Double)
    }

    static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/inc.attention.rem/rem.db")
    }

    init(databaseURL: URL = CoastLegacyReader.defaultDatabaseURL(), contentRootURL: URL? = nil) {
        self.databaseURL = databaseURL
        self.contentRootURL = contentRootURL ?? databaseURL.deletingLastPathComponent()
    }

    func isAvailable() -> Bool {
        do {
            return try openIfUsable() != nil
        } catch {
            return false
        }
    }

    func search(_ query: ScreenHistorySearchQuery) throws -> [ScreenHistoryFrame] {
        guard let database = try openIfUsable() else { return [] }
        return try queryFrames(
            database: database,
            match: SQLiteScreenHistoryStore.literalFTSQuery(query.text),
            query: query,
            afterFrameID: nil,
            ascending: false
        )
    }

    func page(offset: Int, limit: Int) throws -> [ScreenHistoryFrame] {
        guard let database = try openIfUsable() else { return [] }
        return try queryFrames(
            database: database,
            match: nil,
            query: ScreenHistorySearchQuery(limit: min(max(1, limit), 200), offset: max(0, offset)),
            afterFrameID: nil,
            ascending: false
        )
    }

    func moments(from: Date, through: Date, limit: Int) throws -> [ScreenHistoryFrame] {
        guard let database = try openIfUsable() else { return [] }
        return try queryFrames(
            database: database,
            match: nil,
            query: ScreenHistorySearchQuery(from: from, through: through, limit: min(max(1, limit), 200)),
            afterFrameID: nil,
            ascending: true
        )
    }

    func importRows(afterFrameID: Int64?, limit: Int) throws -> [ScreenHistoryFrameInput] {
        guard let database = try openIfUsable() else { return [] }
        let boundedLimit = min(max(1, limit), Self.maximumImportRows)
        let rows = try queryFrames(
            database: database,
            match: nil,
            query: ScreenHistorySearchQuery(limit: boundedLimit),
            afterFrameID: afterFrameID,
            ascending: true
        )
        return try rows.map { row in
            ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: String(row.id),
                capturedAt: row.capturedAt,
                application: row.application,
                bundleIdentifier: row.bundleIdentifier,
                domain: row.domain,
                windowTitle: row.windowTitle,
                ocrText: String(row.ocrText.prefix(Self.maximumOCRCharacters)),
                imageLocator: row.imageLocator,
                mediaLocator: row.mediaLocator,
                mediaFrameIndex: row.mediaFrameIndex,
                mediaFrameCount: row.mediaFrameCount,
                displayGeometry: row.displayGeometry,
                ocrBoxes: try queryOCRBoxes(database: database, frameID: row.id),
                byteCount: row.byteCount,
                sequenceIdentifier: row.sequenceIdentifier,
                sequenceOrdinal: row.sequenceOrdinal,
                contentHash: row.contentHash
            )
        }
    }

    /// Couples the bounded import rows to content-free legacy family
    /// identities. Raw relation IDs and hashed raw media locators preserve
    /// source cardinality even when a locator is unsafe to resolve.
    func migrationSourceBatch(
        afterFrameID: Int64?,
        limit: Int
    ) throws -> ScreenHistoryMigrationSourceBatch {
        let rows = try importRows(afterFrameID: afterFrameID, limit: limit)
        guard let database = try openIfUsable() else {
            return ScreenHistoryMigrationSourceBatch(
                rows: rows,
                supportedFamilies: [.frame],
                memberships: rows.map {
                    ScreenHistoryMigrationFamilyMembership(
                        sourceIdentifier: $0.sourceIdentifier,
                        ocrIdentifier: nil,
                        applicationIdentifier: nil,
                        domainIdentifier: nil,
                        sequenceIdentifier: nil,
                        mediaIdentifiers: []
                    )
                }
            )
        }
        let boundedLimit = min(max(1, limit), Self.maximumImportRows)
        let statement = try database.prepare("""
            SELECT f.id,
                   CASE WHEN EXISTS (
                       SELECT 1 FROM ocr_fts WHERE rowid = f.id
                   ) THEN 'ocr:' || f.id ELSE NULL END,
                   CASE WHEN s.application IS NULL THEN NULL
                        ELSE 'application:' || s.application END,
                   CASE WHEN s.domain IS NULL THEN NULL
                        ELSE 'domain:' || s.domain END,
                   CASE WHEN f.segment IS NULL THEN NULL
                        ELSE 'sequence:' || f.segment END,
                   f.image_path, f.video
            FROM frame f
            LEFT JOIN segment s ON s.id = f.segment
            WHERE (? IS NULL OR f.id > ?)
            ORDER BY f.id ASC
            LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(afterFrameID, to: statement, at: 1)
        try SQLiteValue.bind(afterFrameID, to: statement, at: 2)
        try SQLiteValue.bind(Int64(boundedLimit), to: statement, at: 3)
        var memberships: [ScreenHistoryMigrationFamilyMembership] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
            let sourceIdentifier = String(sqlite3_column_int64(statement, 0))
            var media: Set<String> = []
            if let rawImage = SQLiteValue.text(statement, 5), !rawImage.isEmpty {
                media.insert("image:\(Self.sha256(rawImage))")
            }
            if sqlite3_column_type(statement, 6) != SQLITE_NULL {
                media.insert("video:\(sqlite3_column_int64(statement, 6))")
            }
            memberships.append(ScreenHistoryMigrationFamilyMembership(
                sourceIdentifier: sourceIdentifier,
                ocrIdentifier: SQLiteValue.text(statement, 1),
                applicationIdentifier: SQLiteValue.text(statement, 2),
                domainIdentifier: SQLiteValue.text(statement, 3),
                sequenceIdentifier: SQLiteValue.text(statement, 4),
                mediaIdentifiers: media
            ))
        }
        return ScreenHistoryMigrationSourceBatch(
            rows: rows,
            supportedFamilies: Set(ScreenHistoryMigrationFamily.allCases),
            memberships: memberships
        )
    }

    func ocrBoxes(sourceIdentifier: String) async throws -> [ScreenHistoryOCRBox] {
        guard let frameID = Int64(sourceIdentifier), frameID > 0,
              let database = try openIfUsable() else { return [] }
        return try queryOCRBoxes(database: database, frameID: frameID)
    }

    private func openIfUsable() throws -> LocalSQLiteConnection? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let database = try LocalSQLiteConnection(url: databaseURL, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        try database.execute("PRAGMA query_only = ON;")
        let statement = try database.prepare("""
            SELECT count(*) FROM sqlite_master
            WHERE type IN ('table', 'view') AND name IN ('frame', 'ocr_fts');
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_int(statement, 0) == 2
        else { return nil }
        return database
    }

    private func queryFrames(
        database: LocalSQLiteConnection,
        match: String?,
        query: ScreenHistorySearchQuery,
        afterFrameID: Int64?,
        ascending: Bool
    ) throws -> [ScreenHistoryFrame] {
        var conditions: [String] = []
        var values: [BoundValue] = []
        if let match {
            conditions.append("ocr_fts MATCH ?")
            values.append(.text(match))
        }
        if let afterFrameID {
            conditions.append("f.id > ?")
            values.append(.number(Double(afterFrameID)))
        }
        if let from = query.from {
            conditions.append("f.timestamp >= ?")
            values.append(.number(Self.legacyTimestamp(from)))
        }
        if let through = query.through {
            conditions.append("f.timestamp <= ?")
            values.append(.number(Self.legacyTimestamp(through)))
        }
        if let application = Self.clean(query.application) {
            conditions.append("COALESCE(a.display_name, f.foreground) = ? COLLATE NOCASE")
            values.append(.text(application))
        }
        if let domain = Self.clean(query.domain) {
            conditions.append("d.normalized_domain = ? COLLATE NOCASE")
            values.append(.text(domain))
        }

        let ftsJoin = match == nil ? "LEFT JOIN ocr_fts ON ocr_fts.rowid = f.id" : "JOIN ocr_fts ON ocr_fts.rowid = f.id"
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let direction = ascending ? "ASC" : "DESC"
        let statement = try database.prepare("""
            SELECT f.id, f.timestamp,
                   COALESCE(a.display_name, f.foreground), a.bundle_id,
                   d.normalized_domain, f.title,
                   substr(COALESCE(ocr_fts.foreground, '') || COALESCE(ocr_fts.background, ''), 1, 20000),
                   f.image_path, v.path, f.video_index,
                   CASE WHEN f.image_path IS NOT NULL THEN 0 ELSE COALESCE(v.size_bytes / MAX(v.num_frames, 1), 0) END,
                   CASE WHEN f.segment IS NULL THEN NULL ELSE 'coast-segment-' || f.segment END,
                   CASE WHEN f.segment IS NULL THEN NULL ELSE (
                       SELECT COUNT(*) - 1 FROM frame prior
                       WHERE prior.segment = f.segment
                         AND (prior.timestamp < f.timestamp
                              OR (prior.timestamp = f.timestamp AND prior.id <= f.id))
                   ) END,
                   v.num_frames,
                   f.capture_display_x, f.capture_display_y,
                   f.capture_display_width, f.capture_display_height
            FROM frame f
            \(ftsJoin)
            LEFT JOIN segment s ON s.id = f.segment
            LEFT JOIN application a ON a.id = s.application
            LEFT JOIN domain d ON d.id = s.domain
            LEFT JOIN video v ON v.id = f.video
            \(whereClause)
            ORDER BY f.id \(direction)
            LIMIT ? OFFSET ?;
            """)
        defer { sqlite3_finalize(statement) }
        for (position, value) in values.enumerated() {
            switch value {
            case .text(let text): try SQLiteValue.bind(text, to: statement, at: Int32(position + 1))
            case .number(let number): try SQLiteValue.bind(number, to: statement, at: Int32(position + 1))
            }
        }
        let limitIndex = Int32(values.count + 1)
        try SQLiteValue.bind(Int64(min(max(1, query.limit), Self.maximumImportRows)), to: statement, at: limitIndex)
        try SQLiteValue.bind(Int64(max(0, query.offset)), to: statement, at: limitIndex + 1)

        var rows: [ScreenHistoryFrame] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
            let rawTimestamp = sqlite3_column_double(statement, 1)
            let rowID = sqlite3_column_int64(statement, 0)
            let sourceIdentifier = String(rowID)
            let capturedAt = Date(timeIntervalSince1970: Self.seconds(rawTimestamp))
            let application = SQLiteValue.text(statement, 2)
            let bundleIdentifier = SQLiteValue.text(statement, 3)
            let domain = SQLiteValue.text(statement, 4)
            let windowTitle = SQLiteValue.text(statement, 5)
            let ocrText = SQLiteValue.text(statement, 6) ?? ""
            let imageLocator = resolve(SQLiteValue.text(statement, 7))
            let mediaLocator = resolve(SQLiteValue.text(statement, 8))
            let mediaFrameIndex = sqlite3_column_type(statement, 9) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(statement, 9))
            let byteCount = max(0, sqlite3_column_int64(statement, 10))
            let sequenceIdentifier = SQLiteValue.text(statement, 11)
            let sequenceOrdinal = sqlite3_column_type(statement, 12) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(statement, 12))
            let mediaFrameCount = sqlite3_column_type(statement, 13) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(statement, 13))
            let displayGeometry: ScreenHistoryDisplayGeometry?
            if (14...17).allSatisfy({ sqlite3_column_type(statement, Int32($0)) != SQLITE_NULL }) {
                displayGeometry = ScreenHistoryDisplayGeometry(
                    x: sqlite3_column_double(statement, 14),
                    y: sqlite3_column_double(statement, 15),
                    width: sqlite3_column_double(statement, 16),
                    height: sqlite3_column_double(statement, 17)
                )
            } else {
                displayGeometry = nil
            }
            let input = ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: sourceIdentifier,
                capturedAt: capturedAt,
                application: application,
                bundleIdentifier: bundleIdentifier,
                domain: domain,
                windowTitle: windowTitle,
                ocrText: ocrText,
                imageLocator: imageLocator,
                mediaLocator: mediaLocator,
                mediaFrameIndex: mediaFrameIndex,
                mediaFrameCount: mediaFrameCount,
                displayGeometry: displayGeometry,
                byteCount: byteCount,
                sequenceIdentifier: sequenceIdentifier,
                sequenceOrdinal: sequenceOrdinal
            )
            rows.append(ScreenHistoryFrame(
                id: rowID,
                source: .coast,
                sourceIdentifier: sourceIdentifier,
                capturedAt: capturedAt,
                application: application,
                bundleIdentifier: bundleIdentifier,
                domain: domain,
                windowTitle: windowTitle,
                ocrText: ocrText,
                imageLocator: imageLocator,
                mediaLocator: mediaLocator,
                mediaFrameIndex: mediaFrameIndex,
                mediaFrameCount: mediaFrameCount,
                displayGeometry: displayGeometry,
                byteCount: byteCount,
                sequenceIdentifier: sequenceIdentifier,
                sequenceOrdinal: sequenceOrdinal,
                contentHash: input.contentHash
            ))
        }
    }

    private func resolve(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let root = contentRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = (path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : contentRootURL.appendingPathComponent(path))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path != root.path,
              candidate.path.hasPrefix(root.path + "/")
        else { return nil }
        return candidate.path
    }

    private func queryOCRBoxes(
        database: LocalSQLiteConnection,
        frameID: Int64
    ) throws -> [ScreenHistoryOCRBox] {
        let available = try database.prepare("""
            SELECT 1 FROM sqlite_master WHERE type='table' AND name='ocr' LIMIT 1;
            """)
        defer { sqlite3_finalize(available) }
        guard sqlite3_step(available) == SQLITE_ROW else { return [] }
        let statement = try database.prepare("""
            SELECT o.x, o.y, o.width, o.height,
                   substr(COALESCE(f.foreground, '') || COALESCE(f.background, ''),
                          o.text_offset + 1, o.text_length)
            FROM ocr o JOIN frame f ON f.id = o.frame
            WHERE o.frame = ?
            ORDER BY o.text_offset ASC, o.id ASC
            LIMIT 1000;
            """)
        defer { sqlite3_finalize(statement) }
        try SQLiteValue.bind(frameID, to: statement, at: 1)
        var boxes: [ScreenHistoryOCRBox] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return boxes }
            guard result == SQLITE_ROW else { throw LocalSQLiteError.step(database.message()) }
            let text = String((SQLiteValue.text(statement, 4) ?? "").prefix(200))
            guard !text.isEmpty else { continue }
            boxes.append(ScreenHistoryOCRBox(
                ordinal: boxes.count,
                text: text,
                x: sqlite3_column_double(statement, 0),
                y: sqlite3_column_double(statement, 1),
                width: sqlite3_column_double(statement, 2),
                height: sqlite3_column_double(statement, 3)
            ))
        }
    }

    private nonisolated static func seconds(_ legacyTimestamp: Double) -> Double {
        legacyTimestamp > 10_000_000_000 ? legacyTimestamp / 1_000 : legacyTimestamp
    }

    private nonisolated static func legacyTimestamp(_ date: Date) -> Double {
        // Coast installations use millisecond epochs. Synthetic and older
        // exports with second epochs remain readable during row conversion.
        date.timeIntervalSince1970 * 1_000
    }

    private nonisolated static func clean(_ value: String?) -> String? {
        guard let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines), !clean.isEmpty else { return nil }
        return String(clean.prefix(500))
    }

    private nonisolated static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
