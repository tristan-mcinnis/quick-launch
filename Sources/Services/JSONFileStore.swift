import Foundation

/// One JSON file on disk holding one `Codable` value.
///
/// - Writes are atomic (temp file + rename) and owner-only (`0600`).
/// - Writes run on a private serial queue so the main thread never blocks
///   on disk; `flush()` waits for them (tests, shutdown).
/// - An optional schema-version envelope `{"schemaVersion": n, "payload": …}`
///   wraps the value when `schemaVersion` is set. Reads accept both the
///   envelope and a bare value, so files written before the envelope was
///   introduced keep loading.
/// - I/O errors are logged with the file name; a file that does not exist
///   yet is not an error.
/// - `@unchecked`: every stored property is a `let`; the encoder and decoder
///   are only used on `queue`, which serialises all disk work.
final class JSONFileStore<Value: Codable & Sendable>: @unchecked Sendable {
    struct Envelope: Codable {
        var schemaVersion: Int
        var payload: Value
    }

    enum LoadError: Error {
        /// The file carries a schema version newer than this build understands.
        case unsupportedSchemaVersion(Int)
    }

    let fileURL: URL
    let schemaVersion: Int?
    let permissions: Int

    private let queue: DispatchQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - fileURL: Where the value lives.
    ///   - schemaVersion: `nil` writes the bare value (legacy-compatible
    ///     format). A number writes the envelope.
    ///   - permissions: POSIX mode applied after every write.
    ///   - queue: Serial queue for background writes. Stores that share a
    ///     file must share a queue so writes stay ordered.
    init(
        fileURL: URL,
        schemaVersion: Int? = nil,
        permissions: Int = 0o600,
        queue: DispatchQueue? = nil,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.fileURL = fileURL
        self.schemaVersion = schemaVersion
        self.permissions = permissions
        self.queue = queue ?? DispatchQueue(
            label: "com.tristanmcinnis.quick-launch.json-store.\(fileURL.lastPathComponent)",
            qos: .utility
        )
        self.encoder = encoder
        self.decoder = decoder
    }

    private var fileName: String { fileURL.lastPathComponent }

    // MARK: Reading

    /// The stored value, or `nil` when the file is missing or unreadable.
    /// Problems other than a missing file are logged.
    func load() -> Value? {
        do {
            return try loadOrThrow()
        } catch {
            if !AppLog.isMissingFile(error) {
                AppLog.persistence.error("Could not load \(self.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    /// Like `load()` but surfaces the error. A missing file is an error too.
    func loadOrThrow() throws -> Value? {
        let data = try Data(contentsOf: fileURL)
        return try Self.decode(data, decoder: decoder, schemaVersion: schemaVersion)
    }

    /// Decodes the envelope when present, otherwise the bare value.
    static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder(), schemaVersion: Int?) throws -> Value {
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            if let schemaVersion, envelope.schemaVersion > schemaVersion {
                throw LoadError.unsupportedSchemaVersion(envelope.schemaVersion)
            }
            return envelope.payload
        }
        return try decoder.decode(Value.self, from: data)
    }

    /// True when a file is on disk, whatever it holds.
    var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    // MARK: Writing

    /// Queues a write. Returns immediately.
    func save(_ value: Value) {
        queue.async { [self] in
            do {
                try writeNow(value)
            } catch {
                AppLog.persistence.error("Could not save \(self.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Writes on the calling thread and reports failure.
    func saveNow(_ value: Value) throws {
        try queue.sync { try writeNow(value) }
    }

    private func writeNow(_ value: Value) throws {
        let data: Data
        if let schemaVersion {
            data = try encoder.encode(Envelope(schemaVersion: schemaVersion, payload: value))
        } else {
            data = try encoder.encode(value)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: fileURL.path
        )
    }

    /// Queues removal of the file. Missing files are fine.
    func delete() {
        queue.async { [self] in
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                if !AppLog.isMissingFile(error) {
                    AppLog.persistence.error("Could not delete \(self.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Removes the file on the store's own queue, synchronously. A caller that
    /// runs this from a shared queue keeps its ordering against the writes it
    /// already handed that queue.
    func deleteNow() {
        queue.sync { [self] in
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                if !AppLog.isMissingFile(error) {
                    AppLog.persistence.error("Could not delete \(self.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Blocks until every queued write or delete has finished.
    func flush() {
        queue.sync {}
    }
}
