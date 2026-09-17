import Foundation

/// Why the attachment archive could not do something.
public enum AttachmentArchiveError: Error, Sendable, Equatable, LocalizedError {
    case invalidRoot(String)
    case invalidDigest(String)
    case invalidExtension(String)
    case missing(kind: ArtifactRef.Kind, sha256: String)
    /// A file is there but its bytes are not what its name says.
    case corrupt(kind: ArtifactRef.Kind, sha256: String, detail: String)
    /// A symlink sits where the archive keeps a directory or a file.
    case unsafePath(String)
    /// An artifact kind this build does not know: no read, no verify, no delete.
    case unsupportedKind(String)
    case writeFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let path): "Attachment archive root is not usable: \(path)"
        case .invalidDigest(let digest): "Not a SHA-256 digest: \(digest)"
        case .invalidExtension(let ext): "Not a usable file extension: \(ext)"
        case .missing(let kind, let sha): "No \(kind.rawValue) artifact \(sha.prefix(12))…"
        case .corrupt(let kind, let sha, let detail): "Damaged \(kind.rawValue) artifact \(sha.prefix(12))…: \(detail)"
        case .unsafePath(let path): "Refusing a symlinked archive path: \(path)"
        case .unsupportedKind(let kind): "Unknown artifact kind: \(kind)"
        case .writeFailed(let path): "Could not write \(path)"
        }
    }
}

/// The immutable byte store: original sources, normalized images, extracted
/// text, and request snapshots, each named by its own SHA-256.
///
/// - **Nothing is ever evicted.** No size cap, no expiry, no pruning. The only
///   removal is `removeUnreferenced(keepingHashes:)`, which runs when a caller
///   asks for it and never on a timer.
/// - **Content addressed.** Storing the same bytes twice returns the same ref
///   and writes one file. A ref's digest is validated before it is joined to
///   any path, so a forged ref cannot escape the root.
/// - **Owner-only.** Directories are created 0700 and files 0600 in the same
///   syscall that creates them, written atomically through `AtomicFile`.
/// - **Root injected.** The app passes its own container URL; this package
///   never hardcodes a location.
public actor AttachmentArchive {
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
            throw AttachmentArchiveError.invalidRoot(root.path)
        }
        self.root = root
        self.configuration = configuration
    }

    // MARK: Storing

    /// Stores `data` and returns its ref. Storing the same bytes again is a
    /// no-op that returns the same ref.
    @discardableResult
    public func store(
        _ data: Data,
        kind: ArtifactRef.Kind,
        fileExtension: String? = nil
    ) throws -> ArtifactRef {
        try Self.validate(kind: kind)
        if let fileExtension { try Self.validate(extension: fileExtension) }
        let digest = SHA256Digest.hex(data)
        let ref = ArtifactRef(
            kind: kind,
            sha256: digest,
            byteCount: data.count,
            fileExtension: fileExtension?.lowercased()
        )
        let url = Self.fileURL(root: root, kind: kind, sha256: digest)

        do {
            try Self.prepareDirectoryChain(root: root, kind: kind, sha256: digest, permissions: configuration.directoryPermissions)
        } catch let error as AttachmentArchiveError {
            throw error
        } catch let error as AtomicFile.Failure {
            throw AttachmentArchiveError.writeFailed(path: Self.describe(error))
        }

        if AtomicFile.isRegularFile(url) {
            // Idempotent: the same bytes are already there. Verify, and
            // rewrite only if the file on disk drifted.
            if (try? AtomicFile.read(url)).map({ SHA256Digest.hex($0) }) == digest {
                return ref
            }
        }

        do {
            try AtomicFile.write(data, to: url, permissions: configuration.filePermissions)
        } catch let error as AtomicFile.Failure {
            throw AttachmentArchiveError.writeFailed(path: Self.describe(error))
        }
        return ref
    }

    // MARK: Reading

    public func contains(_ ref: ArtifactRef) -> Bool {
        guard ref.kind != .unknown else { return false }
        guard let url = try? Self.url(for: ref, root: root) else { return false }
        guard (try? Self.checkDirectoryChain(root: root, kind: ref.kind, sha256: ref.sha256)) != nil else {
            return false
        }
        return AtomicFile.isRegularFile(url)
    }

    /// The stored bytes. Refuses a symlink anywhere in the archive path, and
    /// distinguishes a missing artifact from a damaged one: the bytes are
    /// hashed again and compared to the ref, so tampered bytes are never
    /// returned as if they were the artifact.
    public func read(_ ref: ArtifactRef) throws -> Data {
        let url = try Self.url(for: ref, root: root)
        try Self.checkDirectoryChain(root: root, kind: ref.kind, sha256: ref.sha256)
        guard AtomicFile.isRegularFile(url) else {
            throw AttachmentArchiveError.missing(kind: ref.kind, sha256: ref.sha256)
        }
        guard let data = try? AtomicFile.read(url) else {
            throw AttachmentArchiveError.corrupt(kind: ref.kind, sha256: ref.sha256, detail: "unreadable file")
        }
        let actual = SHA256Digest.hex(data)
        guard actual == ref.sha256 else {
            throw AttachmentArchiveError.corrupt(
                kind: ref.kind,
                sha256: ref.sha256,
                detail: "content hashes to \(actual.prefix(12))…"
            )
        }
        guard data.count == ref.byteCount else {
            throw AttachmentArchiveError.corrupt(
                kind: ref.kind,
                sha256: ref.sha256,
                detail: "size \(data.count) is not \(ref.byteCount)"
            )
        }
        return data
    }

    /// Recomputes the hash of the stored bytes and compares it to the ref.
    public func verify(_ ref: ArtifactRef) throws -> ArtifactVerification {
        guard ref.kind != .unknown else { return .missing }
        let url = try Self.url(for: ref, root: root)
        guard (try? Self.checkDirectoryChain(root: root, kind: ref.kind, sha256: ref.sha256)) != nil else {
            return .missing
        }
        guard AtomicFile.isRegularFile(url) else { return .missing }
        guard let data = try? AtomicFile.read(url) else { return .missing }
        let actual = SHA256Digest.hex(data)
        return actual == ref.sha256 ? .verified : .mismatched(actualSHA256: actual)
    }

    /// Every artifact on disk, optionally of one kind, sorted by kind then
    /// digest. Only kinds that own a directory are listed, so an unknown kind
    /// can never be enumerated into a removal.
    public func list(kind: ArtifactRef.Kind? = nil) throws -> [ArtifactRef] {
        let kinds = kind.map { [$0] } ?? ArtifactRef.Kind.storable
        var refs: [ArtifactRef] = []
        for kind in kinds {
            let kindDirectory = root.appendingPathComponent(kind.rawValue, isDirectory: true)
            guard let prefixes = try? FileManager.default.contentsOfDirectory(
                at: kindDirectory,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }
            for prefix in prefixes {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: prefix,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
                ) else { continue }
                for file in files {
                    let digest = file.lastPathComponent
                    guard SHA256Digest.isValid(digest) else { continue }
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    refs.append(ArtifactRef(kind: kind, sha256: digest, byteCount: size))
                }
            }
        }
        return refs.sorted { ($0.kind.rawValue, $0.sha256) < ($1.kind.rawValue, $1.sha256) }
    }

    // MARK: Removing

    /// The only bulk removal. Deletes every artifact whose digest is not in
    /// `keepingHashes`. `nil` means an empty keep set, which deletes
    /// everything: pass a real set.
    @discardableResult
    public func removeUnreferenced(keepingHashes: Set<String>) throws -> [ArtifactRef] {
        let all = try list()
        var removed: [ArtifactRef] = []
        for ref in all where !keepingHashes.contains(ref.sha256) {
            try remove(ref)
            removed.append(ref)
        }
        return removed
    }

    /// Explicit single-artifact removal. The whole path is checked before
    /// anything is deleted, symlinks included.
    public func remove(_ ref: ArtifactRef) throws {
        let url = try Self.url(for: ref, root: root)
        try Self.checkDirectoryChain(root: root, kind: ref.kind, sha256: ref.sha256)
        guard AtomicFile.isRegularFile(url) else {
            throw AttachmentArchiveError.missing(kind: ref.kind, sha256: ref.sha256)
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: Paths

    /// `<root>/<kind>/<first two hex>/<digest>`.
    ///
    /// The digest is validated as lowercase hex before it touches a path, so
    /// no ref can point outside the root. The file extension is metadata for
    /// exporters; it is deliberately not part of the path, so one digest is
    /// one file.
    static func fileURL(root: URL, kind: ArtifactRef.Kind, sha256: String) -> URL {
        root
            .appendingPathComponent(kind.rawValue, isDirectory: true)
            .appendingPathComponent(String(sha256.prefix(2)), isDirectory: true)
            .appendingPathComponent(sha256, isDirectory: false)
    }

    /// The three directories that must all be real directories, never
    /// symlinks, for an artifact path to be trusted.
    static func directoryChain(root: URL, kind: ArtifactRef.Kind, sha256: String) -> [URL] {
        let kindDirectory = root.appendingPathComponent(kind.rawValue, isDirectory: true)
        let prefixDirectory = kindDirectory.appendingPathComponent(String(sha256.prefix(2)), isDirectory: true)
        return [root, kindDirectory, prefixDirectory]
    }

    /// Creates any directory in the chain that is missing, refusing to write
    /// through a symlink planted at the root, a kind directory, or a prefix
    /// directory. A directory another process creates concurrently is accepted,
    /// not treated as unsafe.
    static func prepareDirectoryChain(
        root: URL,
        kind: ArtifactRef.Kind,
        sha256: String,
        permissions: Int
    ) throws {
        for directory in directoryChain(root: root, kind: kind, sha256: sha256) {
            do {
                try AtomicFile.ensureDirectory(directory, permissions: permissions)
            } catch let failure as AtomicFile.Failure {
                switch failure {
                case .symlink, .notADirectory:
                    throw AttachmentArchiveError.unsafePath(directory.path)
                default:
                    throw AttachmentArchiveError.writeFailed(path: directory.path)
                }
            }
        }
    }

    /// Verifies the chain for a read or a delete: a symlink is refused, a
    /// missing directory is just a missing artifact.
    static func checkDirectoryChain(root: URL, kind: ArtifactRef.Kind, sha256: String) throws {
        for directory in directoryChain(root: root, kind: kind, sha256: sha256) {
            if AtomicFile.isSymlink(directory) {
                throw AttachmentArchiveError.unsafePath(directory.path)
            }
            guard AtomicFile.isDirectory(directory) else {
                throw AttachmentArchiveError.missing(kind: kind, sha256: sha256)
            }
        }
    }

    static func url(for ref: ArtifactRef, root: URL) throws -> URL {
        guard ref.kind != .unknown else {
            throw AttachmentArchiveError.unsupportedKind(ref.kindRaw ?? ref.kind.rawValue)
        }
        guard SHA256Digest.isValid(ref.sha256) else {
            throw AttachmentArchiveError.invalidDigest(ref.sha256)
        }
        return fileURL(root: root, kind: ref.kind, sha256: ref.sha256)
    }

    /// An unknown kind has no directory and no operations: refuse it rather
    /// than treating it as a known kind.
    static func validate(kind: ArtifactRef.Kind) throws {
        guard kind != .unknown else {
            throw AttachmentArchiveError.unsupportedKind(kind.rawValue)
        }
    }

    static func validate(extension ext: String) throws {
        let trimmed = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw AttachmentArchiveError.invalidExtension(ext) }
    }

    private static func describe(_ failure: AtomicFile.Failure) -> String {
        switch failure {
        case .open(let path, _), .write(let path, _), .rename(let path, _), .read(let path, _),
             .symlink(let path), .notADirectory(let path):
            path
        }
    }
}
