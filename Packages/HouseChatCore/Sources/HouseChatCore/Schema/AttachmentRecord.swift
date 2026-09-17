import Foundation

/// What the history keeps for one attachment. The text itself lives in
/// `AttachmentArchive`; this record keeps the facts and the artifact hashes.
///
/// Every field an older writer may not have is optional, and unknown keys are
/// kept in `extra`.
public struct AttachmentRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: AttachmentKind
    /// The original kind string when it did not map to a known case.
    public var kindRaw: String?
    public var name: String
    public var byteCount: Int?
    public var pageCount: Int?
    public var characterCount: Int?
    public var truncation: TextTruncation?
    /// SHA-256 of the original bytes, lowercase hex. Nil for images.
    public var contentHash: String?
    public var extractorVersion: Int?
    /// The file on this Mac. Files only.
    public var path: String?
    /// The final URL after redirects. Links only.
    public var url: URL?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var addedAt: Date?
    /// Where the archived bytes and text are, when the app archived them.
    public var artifacts: AttachmentArtifacts?
    public var extra: ExtraFields

    public init(
        id: String = UUID().uuidString,
        kind: AttachmentKind,
        kindRaw: String? = nil,
        name: String,
        byteCount: Int? = nil,
        pageCount: Int? = nil,
        characterCount: Int? = nil,
        truncation: TextTruncation? = nil,
        contentHash: String? = nil,
        extractorVersion: Int? = nil,
        path: String? = nil,
        url: URL? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        addedAt: Date? = nil,
        artifacts: AttachmentArtifacts? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.id = id
        self.kind = kind
        self.kindRaw = kind == .other ? kindRaw : nil
        self.name = name
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.characterCount = characterCount
        self.truncation = truncation
        self.contentHash = contentHash
        self.extractorVersion = extractorVersion
        self.path = path
        self.url = url
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.addedAt = addedAt
        self.artifacts = artifacts
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "id", "kind", "kindRaw", "name", "byteCount", "pageCount",
        "characterCount", "truncation", "contentHash", "extractorVersion",
        "path", "url", "pixelWidth", "pixelHeight", "addedAt", "artifacts",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        // Identity and content are required: a record missing them is damaged,
        // not a record this build may invent. A legacy adapter supplies them
        // during migration.
        self.id = try c.decodeNonEmptyString(forKey: AnyCodingKey("id"))
        // The kind is read as its raw string, so an unknown kind from a newer
        // build keeps its own name instead of collapsing to "other".
        let kindText = try c.decode(String.self, forKey: AnyCodingKey("kind"))
        let parsedKind = AttachmentKind(rawValue: kindText) ?? .other
        let kindRaw = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("kindRaw"))
        self.kind = parsedKind
        self.kindRaw = parsedKind == .other ? (kindRaw ?? kindText) : nil
        self.name = try c.decodeNonEmptyString(forKey: AnyCodingKey("name"))
        self.byteCount = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("byteCount"))
        self.pageCount = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("pageCount"))
        self.characterCount = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("characterCount"))
        self.truncation = try c.decodeIfPresent(TextTruncation.self, forKey: AnyCodingKey("truncation"))
        self.contentHash = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("contentHash"))
        self.extractorVersion = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("extractorVersion"))
        self.path = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("path"))
        self.url = try c.decodeIfPresent(URL.self, forKey: AnyCodingKey("url"))
        self.pixelWidth = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("pixelWidth"))
        self.pixelHeight = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("pixelHeight"))
        self.addedAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("addedAt"))
        self.artifacts = try c.decodeIfPresent(AttachmentArtifacts.self, forKey: AnyCodingKey("artifacts"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(id, forKey: AnyCodingKey("id"))
        try c.encode(kind, forKey: AnyCodingKey("kind"))
        try c.encodeIfPresent(kindRaw, forKey: AnyCodingKey("kindRaw"))
        try c.encode(name, forKey: AnyCodingKey("name"))
        try c.encodeIfPresent(byteCount, forKey: AnyCodingKey("byteCount"))
        try c.encodeIfPresent(pageCount, forKey: AnyCodingKey("pageCount"))
        try c.encodeIfPresent(characterCount, forKey: AnyCodingKey("characterCount"))
        try c.encodeIfPresent(truncation, forKey: AnyCodingKey("truncation"))
        try c.encodeIfPresent(contentHash, forKey: AnyCodingKey("contentHash"))
        try c.encodeIfPresent(extractorVersion, forKey: AnyCodingKey("extractorVersion"))
        try c.encodeIfPresent(path, forKey: AnyCodingKey("path"))
        try c.encodeIfPresent(url, forKey: AnyCodingKey("url"))
        try c.encodeIfPresent(pixelWidth, forKey: AnyCodingKey("pixelWidth"))
        try c.encodeIfPresent(pixelHeight, forKey: AnyCodingKey("pixelHeight"))
        try c.encodeIfPresent(addedAt, forKey: AnyCodingKey("addedAt"))
        try c.encodeIfPresent(artifacts, forKey: AnyCodingKey("artifacts"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }

    /// True for an image or a screenshot. The record keeps every fact it was
    /// given, including the original's hash and any real source path; it never
    /// fabricates one.
    public var isImage: Bool { kind.isImage }
}

/// The archived byte artifacts for one attachment, by role.
public struct AttachmentArtifacts: Codable, Sendable, Equatable, Hashable {
    public var original: ArtifactRef?
    public var normalizedImage: ArtifactRef?
    public var extractedText: ArtifactRef?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        original: ArtifactRef? = nil,
        normalizedImage: ArtifactRef? = nil,
        extractedText: ArtifactRef? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.original = original
        self.normalizedImage = normalizedImage
        self.extractedText = extractedText
        self.extra = extra
    }

    private static let knownKeys: Set<String> = ["original", "normalizedImage", "extractedText"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.original = try c.decodeIfPresent(ArtifactRef.self, forKey: AnyCodingKey("original"))
        self.normalizedImage = try c.decodeIfPresent(ArtifactRef.self, forKey: AnyCodingKey("normalizedImage"))
        self.extractedText = try c.decodeIfPresent(ArtifactRef.self, forKey: AnyCodingKey("extractedText"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(original, forKey: AnyCodingKey("original"))
        try c.encodeIfPresent(normalizedImage, forKey: AnyCodingKey("normalizedImage"))
        try c.encodeIfPresent(extractedText, forKey: AnyCodingKey("extractedText"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

/// What a request pointed at, by hash, so an audit can find the exact bytes
/// even after a file changed on disk.
public struct AttachmentSnapshotRef: Codable, Sendable, Equatable, Hashable {
    public var attachmentID: String?
    /// SHA-256 of the original bytes.
    public var contentHash: String?
    /// SHA-256 of the exact text or image bytes that were sent.
    public var snapshotHash: String?
    /// "text", "normalizedImage", "pdf", …
    public var kind: String?
    public var byteCount: Int?
    public var characterCount: Int?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        attachmentID: String? = nil,
        contentHash: String? = nil,
        snapshotHash: String? = nil,
        kind: String? = nil,
        byteCount: Int? = nil,
        characterCount: Int? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.attachmentID = attachmentID
        self.contentHash = contentHash
        self.snapshotHash = snapshotHash
        self.kind = kind
        self.byteCount = byteCount
        self.characterCount = characterCount
        self.extra = extra
    }

    /// A snapshot ref for bytes the caller is about to submit as a
    /// `PendingArtifact(role: .requestSnapshot, …)`.
    ///
    /// The hash has to be known *before* the commit writes the conversation
    /// that carries it, so this computes it from the exact bytes: build the ref
    /// with this initializer, put it in the receipt's `attachmentRefs`, then
    /// commit the same `Data`. The stored artifact's SHA-256 and
    /// `snapshotHash` then match by construction.
    public init(
        snapshotData: Data,
        kind: String? = nil,
        attachmentID: String? = nil,
        contentHash: String? = nil,
        characterCount: Int? = nil
    ) {
        self.init(
            attachmentID: attachmentID,
            contentHash: contentHash,
            snapshotHash: SHA256Digest.hex(snapshotData),
            kind: kind,
            byteCount: snapshotData.count,
            characterCount: characterCount
        )
    }

    private static let knownKeys: Set<String> = [
        "attachmentID", "contentHash", "snapshotHash", "kind", "byteCount", "characterCount",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.attachmentID = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("attachmentID"))
        self.contentHash = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("contentHash"))
        self.snapshotHash = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("snapshotHash"))
        self.kind = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("kind"))
        self.byteCount = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("byteCount"))
        self.characterCount = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("characterCount"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(attachmentID, forKey: AnyCodingKey("attachmentID"))
        try c.encodeIfPresent(contentHash, forKey: AnyCodingKey("contentHash"))
        try c.encodeIfPresent(snapshotHash, forKey: AnyCodingKey("snapshotHash"))
        try c.encodeIfPresent(kind, forKey: AnyCodingKey("kind"))
        try c.encodeIfPresent(byteCount, forKey: AnyCodingKey("byteCount"))
        try c.encodeIfPresent(characterCount, forKey: AnyCodingKey("characterCount"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}
