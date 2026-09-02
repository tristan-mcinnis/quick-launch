import Foundation

/// Committed translations only, newest first, bounded. Local JSON, 0600.
enum TranslationHistoryStore {
    static func defaultURL() -> URL {
        AppPaths.file("translation-history.json")
    }

    /// One serial queue so appends to the same file stay ordered.
    private static let writeQueue = DispatchQueue(
        label: "com.tristanmcinnis.quick-launch.translation-history",
        qos: .utility
    )

    private static func store(for url: URL) -> JSONFileStore<[TranslationRecord]> {
        JSONFileStore(fileURL: url, queue: writeQueue)
    }

    static func load(from url: URL) -> [TranslationRecord] {
        store(for: url).load() ?? []
    }

    static func append(_ record: TranslationRecord, to url: URL, limit: Int = TranslatorModel.historyLimit) {
        let store = store(for: url)
        var records = store.load() ?? []
        records.insert(record, at: 0)
        records = Array(records.prefix(limit))
        do {
            try store.saveNow(records)
        } catch {
            AppLog.persistence.error("Could not save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
