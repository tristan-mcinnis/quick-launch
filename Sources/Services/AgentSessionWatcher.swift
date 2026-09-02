import Foundation

/// Watches AgentSessions folders for the JSON files agent hooks write, so the
/// Mac stays awake while Claude Code or Codex is working. No polling: one
/// file-system event source per folder, plus a stale sweep at 12 hours.
@MainActor
final class AgentSessionWatcher {
    private(set) var sessions: [AgentSession] = []
    var onChange: (() -> Void)?

    private let folders: [URL]
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private var sweepTask: Task<Void, Never>?

    /// Quick Launch's own folder first, then Tuna Companion's, so existing
    /// hooks keep working until they are re-pointed.
    static func defaultFolders(fileManager: FileManager = .default) -> [URL] {
        let support = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return [
            support.appendingPathComponent("Quick Launch/AgentSessions", isDirectory: true),
            support.appendingPathComponent("Tuna Companion/AgentSessions", isDirectory: true),
        ]
    }

    init(folders: [URL]) {
        self.folders = folders
    }

    deinit {
        for source in sources { source.cancel() }
    }

    func start() {
        AppLog.attempt("Create \(folders[0].lastPathComponent)") {
            try FileManager.default.createDirectory(at: folders[0], withIntermediateDirectories: true)
        }
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            descriptors.append(descriptor)
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.reload() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
        reload()
    }

    func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
        descriptors.removeAll()
        sweepTask?.cancel()
    }

    /// Re-read every folder, drop stale files, schedule the next sweep.
    func reload(now: Date = Date()) {
        var found: [AgentSession] = []
        for folder in folders {
            guard let urls = AppLog.attempt("List \(folder.lastPathComponent)", {
                try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            }) else { continue }
            for url in urls where url.pathExtension == "json" {
                guard let session = AppLog.attempt("Read agent session \(url.lastPathComponent)", {
                    try Self.decoder.decode(AgentSession.self, from: try Data(contentsOf: url))
                }) else { continue }
                if now.timeIntervalSince(session.updatedAt) >= CaffeinatePolicy.staleInterval {
                    AppLog.attempt("Remove agent session \(url.lastPathComponent)") {
                        try FileManager.default.removeItem(at: url)
                    }
                    continue
                }
                found.append(session)
            }
        }
        let changed = found != sessions
        sessions = found
        scheduleSweep(now: now)
        if changed { onChange?() }
    }

    /// Decaffeinate clears every session file; the next agent turn writes a new one.
    func clearAll() {
        for folder in folders {
            guard let urls = AppLog.attempt("List \(folder.lastPathComponent)", {
                try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            }) else { continue }
            for url in urls where url.pathExtension == "json" {
                AppLog.attempt("Remove agent session \(url.lastPathComponent)") {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        reload()
    }

    private func scheduleSweep(now: Date) {
        sweepTask?.cancel()
        guard let earliest = sessions.map({ $0.updatedAt.addingTimeInterval(CaffeinatePolicy.staleInterval) }).min() else { return }
        let delay = max(1, earliest.timeIntervalSince(now))
        sweepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date \(raw)")
        }
        return decoder
    }()

    /// File name for a session, safe for untrusted ids: `claude-<base64url>.json`.
    static func fileName(provider: String, sessionID: String) -> String {
        let encoded = Data(sessionID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "\(provider)-\(encoded).json"
    }
}
