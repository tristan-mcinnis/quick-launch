import Foundation

/// Why a conversation file could not be read or written.
public enum ConversationArchiveError: Error, Sendable, Equatable, LocalizedError {
    case invalidRoot(String)
    case invalidID(String)
    /// No file for this ID.
    case missing(id: String)
    /// A file exists but is not a valid envelope.
    case corrupt(id: String, detail: String)
    /// A file written by a newer schema than this build understands.
    case unsupportedSchema(id: String, version: Int)
    /// The root directory exists but cannot be listed.
    case rootUnreadable(path: String)
    /// A symlink sits where the archive root should be a real directory.
    case unsafeRoot(path: String)
    case writeFailed(id: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let path): "Conversation archive root is not usable: \(path)"
        case .invalidID(let id): "Not a usable conversation ID: \(id.prefix(64))"
        case .missing(let id): "No conversation \(id)"
        case .corrupt(let id, let detail): "Conversation \(id) is damaged: \(detail)"
        case .unsupportedSchema(let id, let version): "Conversation \(id) uses schema \(version)"
        case .rootUnreadable(let path): "Conversation archive root cannot be listed: \(path)"
        case .unsafeRoot(let path): "Refusing a symlinked conversation archive root: \(path)"
        case .writeFailed(let id, let detail): "Could not write conversation \(id): \(detail)"
        }
    }
}

/// The stored wrapper: a format marker, the schema version, when it was
/// saved, and the conversation.
public struct ConversationEnvelope: Codable, Sendable, Equatable {
    public static let formatName = "house-chat-conversation"

    public var format: String
    public var schemaVersion: Int
    public var savedAt: Date?
    public var conversation: ConversationRecord
    public var extra: ExtraFields

    public init(
        format: String = ConversationEnvelope.formatName,
        schemaVersion: Int = HouseChatCoding.schemaVersion,
        savedAt: Date? = nil,
        conversation: ConversationRecord,
        extra: ExtraFields = ExtraFields()
    ) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.conversation = conversation
        self.extra = extra
    }

    private static let knownKeys: Set<String> = ["format", "schemaVersion", "savedAt", "conversation"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.format = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("format")) ?? Self.formatName
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("schemaVersion")) ?? HouseChatCoding.schemaVersion
        self.savedAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("savedAt"))
        self.conversation = try c.decode(ConversationRecord.self, forKey: AnyCodingKey("conversation"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(format, forKey: AnyCodingKey("format"))
        try c.encode(schemaVersion, forKey: AnyCodingKey("schemaVersion"))
        try c.encodeIfPresent(savedAt, forKey: AnyCodingKey("savedAt"))
        try c.encode(conversation, forKey: AnyCodingKey("conversation"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

/// Every conversation, for `exportAll`.
public struct ConversationBundle: Codable, Sendable, Equatable {
    public static let formatName = "house-chat-bundle"

    public var format: String
    public var schemaVersion: Int
    public var exportedAt: Date?
    public var conversations: [ConversationRecord]

    public init(
        format: String = ConversationBundle.formatName,
        schemaVersion: Int = HouseChatCoding.schemaVersion,
        exportedAt: Date? = nil,
        conversations: [ConversationRecord]
    ) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.conversations = conversations
    }
}

/// A problem `list()` found in one file, carried instead of thrown so one
/// damaged file never hides the rest.
public enum ConversationIssue: String, Codable, Sendable, Equatable {
    case corrupt
    case unsupportedSchema
    case unreadable
}

/// What a list shows without loading every turn's text.
public struct ConversationSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String?
    public var surface: ChatSurface?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var turnCount: Int
    public var schemaVersion: Int
    public var savedAt: Date?
    public var byteCount: Int?
    /// Set when the file on disk has a problem; the other fields are then
    /// whatever could be recovered.
    public var issue: ConversationIssue?

    public init(
        id: String,
        title: String? = nil,
        surface: ChatSurface? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        turnCount: Int = 0,
        schemaVersion: Int = HouseChatCoding.schemaVersion,
        savedAt: Date? = nil,
        byteCount: Int? = nil,
        issue: ConversationIssue? = nil
    ) {
        self.id = id
        self.title = title
        self.surface = surface
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.turnCount = turnCount
        self.schemaVersion = schemaVersion
        self.savedAt = savedAt
        self.byteCount = byteCount
        self.issue = issue
    }
}

/// One JSON file per conversation, written atomically with owner-only
/// permissions, and readable back as a typed record.
///
/// - IDs are the app's own strings; the file name is a slug plus a hash of the
///   ID, so any ID is safe and lookups are exact.
/// - `load` separates `missing` from `corrupt`: a damaged file never reads as
///   an empty conversation.
/// - `saveIfAbsent` makes a legacy import idempotent.
public actor ConversationArchive {
    public struct Configuration: Sendable, Equatable {
        public var directoryPermissions: Int
        public var filePermissions: Int

        public init(directoryPermissions: Int = 0o700, filePermissions: Int = 0o600) {
            self.directoryPermissions = directoryPermissions
            self.filePermissions = filePermissions
        }

        public static let `default` = Configuration()
    }

    public nonisolated let root: URL
    public nonisolated let configuration: Configuration

    public init(root: URL, configuration: Configuration = .default) throws {
        guard root.isFileURL, !root.path.isEmpty, root.path != "/" else {
            throw ConversationArchiveError.invalidRoot(root.path)
        }
        self.root = root
        self.configuration = configuration
    }

    // MARK: Writing

    /// Writes the conversation, replacing any file for the same ID.
    @discardableResult
    public func save(
        _ conversation: ConversationRecord,
        savedAt: Date = Date()
    ) throws -> ConversationSummary {
        try Self.validate(id: conversation.id)
        guard !AtomicFile.isSymlink(root) else {
            throw ConversationArchiveError.unsafeRoot(path: root.path)
        }
        let envelope = ConversationEnvelope(savedAt: savedAt, conversation: conversation)
        let data = try HouseChatCoding.makeEncoder(prettyPrinted: true).encode(envelope)
        let url = fileURL(for: conversation.id)
        do {
            try AtomicFile.ensureDirectory(root, permissions: configuration.directoryPermissions)
            try AtomicFile.write(data, to: url, permissions: configuration.filePermissions)
        } catch AtomicFile.Failure.symlink {
            throw ConversationArchiveError.unsafeRoot(path: root.path)
        } catch AtomicFile.Failure.notADirectory {
            throw ConversationArchiveError.unsafeRoot(path: root.path)
        } catch let error as AtomicFile.Failure {
            throw ConversationArchiveError.writeFailed(id: conversation.id, detail: String(describing: error))
        } catch let error as ConversationArchiveError {
            throw error
        } catch {
            throw ConversationArchiveError.writeFailed(id: conversation.id, detail: error.localizedDescription)
        }
        return ConversationSummary(
            id: conversation.id,
            title: conversation.title,
            surface: conversation.surface,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            turnCount: conversation.turns.count,
            schemaVersion: conversation.schemaVersion,
            savedAt: savedAt,
            byteCount: data.count
        )
    }

    /// Writes the conversation only when no file for its ID exists. Returns
    /// true when it wrote. This is what makes a legacy import idempotent: the
    /// consumer's adapter converts its own old format and calls this once per
    /// conversation, and a second run changes nothing.
    @discardableResult
    public func saveIfAbsent(
        _ conversation: ConversationRecord,
        savedAt: Date = Date()
    ) throws -> Bool {
        // Validate first: an unusable ID must be an error, not a silent
        // "nothing to do".
        try Self.validate(id: conversation.id)
        guard !contains(conversation.id) else { return false }
        try save(conversation, savedAt: savedAt)
        return true
    }

    // MARK: Reading

    public nonisolated func contains(_ id: String) -> Bool {
        guard (try? Self.validate(id: id)) != nil else { return false }
        return AtomicFile.isRegularFile(fileURL(for: id))
    }

    /// The stored conversation. Throws `.missing` when there is no file and
    /// `.corrupt` when there is one but it does not decode, is not a
    /// conversation envelope, or holds a different conversation.
    public func load(id: String) throws -> ConversationRecord {
        try Self.validate(id: id)
        return try envelope(forID: id).conversation
    }

    /// The stored envelope, with every integrity check: a readable file, the
    /// expected format, a schema this build understands at both levels, and a
    /// conversation whose own ID matches the one asked for.
    public func envelope(forID id: String) throws -> ConversationEnvelope {
        try Self.validate(id: id)
        guard !AtomicFile.isSymlink(root) else {
            throw ConversationArchiveError.unsafeRoot(path: root.path)
        }
        let url = fileURL(for: id)
        guard AtomicFile.isRegularFile(url) else { throw ConversationArchiveError.missing(id: id) }
        guard let data = try? AtomicFile.read(url) else {
            throw ConversationArchiveError.corrupt(id: id, detail: "unreadable file")
        }
        let envelope = try Self.decodeEnvelope(data, id: id)
        guard envelope.conversation.id == id else {
            throw ConversationArchiveError.corrupt(id: id, detail: "conversation ID does not match the file")
        }
        return envelope
    }

    /// Summaries for every conversation on disk, newest first. A damaged file
    /// is listed with `issue` set instead of being skipped. A root that exists
    /// but cannot be listed throws: an unreadable store is not an empty one.
    public func list() throws -> [ConversationSummary] {
        let manager = FileManager.default
        guard !AtomicFile.isSymlink(root) else {
            throw ConversationArchiveError.unsafeRoot(path: root.path)
        }
        guard manager.fileExists(atPath: root.path) else { return [] }
        let files: [URL]
        do {
            files = try manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            )
        } catch {
            throw ConversationArchiveError.rootUnreadable(path: root.path)
        }

        var summaries: [ConversationSummary] = []
        for file in files where file.pathExtension.lowercased() == "json" {
            let byteCount = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard let data = try? AtomicFile.read(file) else {
                summaries.append(ConversationSummary(
                    id: Self.idHint(fromFileName: file.lastPathComponent),
                    byteCount: byteCount,
                    issue: .unreadable
                ))
                continue
            }
            do {
                let envelope = try Self.decodeEnvelope(data, id: Self.idHint(fromFileName: file.lastPathComponent))
                let conversation = envelope.conversation
                summaries.append(ConversationSummary(
                    id: conversation.id,
                    title: conversation.title,
                    surface: conversation.surface,
                    createdAt: conversation.createdAt,
                    updatedAt: conversation.updatedAt,
                    turnCount: conversation.turns.count,
                    schemaVersion: conversation.schemaVersion,
                    savedAt: envelope.savedAt,
                    byteCount: byteCount
                ))
            } catch let error as ConversationArchiveError {
                var issue: ConversationIssue = .corrupt
                if case .unsupportedSchema = error { issue = .unsupportedSchema }
                summaries.append(ConversationSummary(
                    id: Self.idHint(fromFileName: file.lastPathComponent),
                    byteCount: byteCount,
                    issue: issue
                ))
            } catch {
                summaries.append(ConversationSummary(
                    id: Self.idHint(fromFileName: file.lastPathComponent),
                    byteCount: byteCount,
                    issue: .corrupt
                ))
            }
        }
        return summaries.sorted {
            ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id)
        }
    }

    // MARK: Export and delete

    /// One conversation as the same JSON that is on disk.
    public func export(id: String, prettyPrinted: Bool = true) throws -> Data {
        let envelope = try envelope(forID: id)
        if !prettyPrinted {
            return try HouseChatCoding.makeEncoder(prettyPrinted: false).encode(envelope)
        }
        return try HouseChatCoding.makeEncoder(prettyPrinted: true).encode(envelope)
    }

    /// Every readable conversation in one bundle, for a whole-app export.
    public func exportAll(prettyPrinted: Bool = true) throws -> Data {
        var conversations: [ConversationRecord] = []
        for summary in try list() where summary.issue == nil {
            if let record = try? load(id: summary.id) { conversations.append(record) }
        }
        let bundle = ConversationBundle(exportedAt: Date(), conversations: conversations)
        return try HouseChatCoding.makeEncoder(prettyPrinted: prettyPrinted).encode(bundle)
    }

    /// Deletes one conversation. Missing is an error, not a silent no-op.
    public func delete(id: String) throws {
        try Self.validate(id: id)
        let url = fileURL(for: id)
        guard AtomicFile.isRegularFile(url) else { throw ConversationArchiveError.missing(id: id) }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Paths and decoding

    /// `<root>/<slug>-<idhash>.json`. The slug is cosmetic; the hash suffix
    /// makes the mapping from ID to file exact.
    public nonisolated func fileURL(for id: String) -> URL {
        root.appendingPathComponent(Self.fileName(for: id), isDirectory: false)
    }

    static func fileName(for id: String) -> String {
        var slug = ""
        for scalar in id.unicodeScalars {
            switch scalar.value {
            case 48...57, 65...90, 97...122: slug.unicodeScalars.append(scalar)
            case 45, 46, 95: slug.unicodeScalars.append(scalar)
            default: slug.append("-")
            }
            if slug.utf8.count >= 40 { break }
        }
        if slug.isEmpty || slug == "." || slug == ".." { slug = "conversation" }
        let suffix = SHA256Digest.hex(id).prefix(10)
        return "\(slug)-\(suffix).json"
    }

    /// Best effort ID from a file name, for a damaged file with no readable
    /// record inside.
    static func idHint(fromFileName name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        guard let dash = stem.lastIndex(of: "-") else { return stem }
        return String(stem[stem.startIndex..<dash])
    }

    static func validate(id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 512, !id.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ConversationArchiveError.invalidID(id)
        }
    }

    static func decodeEnvelope(_ data: Data, id: String) throws -> ConversationEnvelope {
        let envelope: ConversationEnvelope
        do {
            envelope = try HouseChatCoding.makeDecoder().decode(ConversationEnvelope.self, from: data)
        } catch {
            throw ConversationArchiveError.corrupt(id: id, detail: "not a conversation envelope")
        }
        guard envelope.format == ConversationEnvelope.formatName else {
            throw ConversationArchiveError.corrupt(id: id, detail: "unexpected format \(envelope.format)")
        }
        guard envelope.schemaVersion <= HouseChatCoding.schemaVersion else {
            throw ConversationArchiveError.unsupportedSchema(id: id, version: envelope.schemaVersion)
        }
        guard envelope.conversation.schemaVersion <= HouseChatCoding.schemaVersion else {
            throw ConversationArchiveError.unsupportedSchema(id: id, version: envelope.conversation.schemaVersion)
        }
        return envelope
    }
}
