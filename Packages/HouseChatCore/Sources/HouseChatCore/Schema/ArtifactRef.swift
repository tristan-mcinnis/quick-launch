import Foundation

/// One immutable artifact in `AttachmentArchive`. The SHA-256 is both the
/// name and the integrity check; the path is derived, never stored on disk.
public struct ArtifactRef: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The exact bytes the user attached, whole, even when extraction
        /// only read part of them.
        case original
        /// A re-encoded image with its metadata dropped, as sent to a model.
        case normalizedImage
        /// The extracted text, UTF-8, after the extractor's cap.
        case extractedText
        /// The exact request body a provider received, for audit.
        case requestSnapshot
        /// A kind this build does not know. It has no directory and no
        /// artifact operation: `kindRaw` keeps the original string, and every
        /// use is refused rather than treated as `.original`.
        case unknown

        /// The kinds that own a directory on disk.
        public static let storable: [Kind] = [.original, .normalizedImage, .extractedText, .requestSnapshot]

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var kind: Kind
    /// The original kind string when it did not map to a known case.
    public var kindRaw: String?
    /// Lowercase hex SHA-256 of the stored bytes.
    public var sha256: String
    public var byteCount: Int
    /// "png", "json", "txt"; nil when the artifact has no extension. Metadata
    /// for exporters only: the stored path is the digest.
    public var fileExtension: String?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        kind: Kind,
        kindRaw: String? = nil,
        sha256: String,
        byteCount: Int,
        fileExtension: String? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.kind = kind
        self.kindRaw = kind == .unknown ? (kindRaw ?? kind.rawValue) : nil
        self.sha256 = sha256
        self.byteCount = byteCount
        self.fileExtension = fileExtension
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "kind", "kindRaw", "sha256", "byteCount", "fileExtension",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let kindText = try c.decode(String.self, forKey: AnyCodingKey("kind"))
        let parsed = Kind(rawValue: kindText) ?? .unknown
        let raw = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("kindRaw"))
        self.kind = parsed
        self.kindRaw = parsed == .unknown ? (raw ?? kindText) : nil
        self.sha256 = try c.decode(String.self, forKey: AnyCodingKey("sha256"))
        self.byteCount = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("byteCount")) ?? 0
        self.fileExtension = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("fileExtension"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(kind.rawValue, forKey: AnyCodingKey("kind"))
        try c.encodeIfPresent(kindRaw, forKey: AnyCodingKey("kindRaw"))
        try c.encode(sha256, forKey: AnyCodingKey("sha256"))
        try c.encode(byteCount, forKey: AnyCodingKey("byteCount"))
        try c.encodeIfPresent(fileExtension, forKey: AnyCodingKey("fileExtension"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }

    /// False for an unknown kind: no read, no verify, no delete.
    public var isReadable: Bool { kind != .unknown }
}

/// The outcome of checking an artifact's bytes against its own hash.
public enum ArtifactVerification: Sendable, Equatable {
    case missing
    case verified
    case mismatched(actualSHA256: String)
}
