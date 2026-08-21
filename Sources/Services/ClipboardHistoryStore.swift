import AppKit
import Foundation

@MainActor
final class ClipboardHistoryStore: ClipboardHistoryServicing {
    private struct StoredEntry: Codable {
        var id: String
        var value: String
        var capturedAt: Date
    }

    private(set) var entries: [LauncherCatalogItem] = []
    private var storedEntries: [StoredEntry] = []
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    func startMonitoring(limit: Int) {
        stopMonitoring()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.capturePasteboard(limit: limit) }
        }
        timer?.tolerance = 0.4
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func record(_ text: String, limit: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.utf8.count <= 200_000 else { return }
        let id = StableIdentifier.make(text)
        storedEntries.removeAll { $0.id == id }
        storedEntries.insert(StoredEntry(id: id, value: text, capturedAt: Date()), at: 0)
        storedEntries = Array(storedEntries.prefix(max(1, min(limit, 200))))
        rebuildPublicEntries()
        save()
    }

    func clear() {
        storedEntries.removeAll()
        entries.removeAll()
        guard fileURL.path.hasSuffix("/clipboard-history.json") else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func capturePasteboard(limit: Int) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string) else { return }
        record(text, limit: limit)
    }

    private func rebuildPublicEntries() {
        entries = storedEntries.map { entry in
            let normalized = entry.value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = normalized.count > 80
                ? String(normalized.prefix(77)) + "…"
                : normalized
            return LauncherCatalogItem(
                kind: .clipboard,
                itemID: entry.id,
                title: title,
                detail: entry.capturedAt.formatted(date: .abbreviated, time: .shortened),
                value: entry.value
            )
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([StoredEntry].self, from: data)
        else { return }
        storedEntries = decoded
        rebuildPublicEntries()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(storedEntries) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return
        }
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/apfel-quick")
            .appendingPathComponent("clipboard-history.json")
    }
}
