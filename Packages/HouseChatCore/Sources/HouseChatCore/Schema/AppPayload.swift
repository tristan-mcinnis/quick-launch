import Foundation

/// Where a request went, with everything that could carry a secret removed.
///
/// A receipt must be safe to write to disk and to show in a UI. Building this
/// from a `URL` drops:
/// - userinfo (`https://user:secret@host`),
/// - the query string, where API keys travel (`?api_key=…`, `?key=…`),
/// - the fragment.
///
/// Anything holding a credential (an API key, an `Authorization` header, a
/// token, a bearer, a closure that would produce one) must never be given a
/// field on a schema type. If it is not a property, it cannot be encoded.
public struct EndpointDescriptor: Codable, Sendable, Equatable, Hashable {
    public var scheme: String?
    public var host: String?
    /// The port, if it is not the scheme default.
    public var port: Int?
    /// The path only; no query, no fragment, credential-shaped segments redacted.
    public var path: String?
    /// `scheme://host[:port][/path]`, the only form written to a receipt.
    public var sanitized: String

    /// Nil when the URL has no scheme or no usable host.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              let host = Self.normalizedHost(url.host())
        else { return nil }
        self.init(normalizedScheme: scheme, host: host, port: url.port, path: url.path)
    }

    /// Sanitizes whatever it is given: userinfo is dropped from the host, a
    /// query or fragment is cut from the path, and a credential-shaped path
    /// segment is redacted. An unusable authority produces an empty descriptor
    /// (`isUsable == false`), never a leak. Use `init(validatingScheme:…)` when
    /// nil is a better signal.
    public init(scheme: String?, host: String?, port: Int? = nil, path: String? = nil) {
        let normalizedScheme = scheme?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard let normalizedHost = Self.normalizedHost(host) else {
            self.init(normalizedScheme: "", host: "", port: nil, path: nil)
            return
        }
        self.init(normalizedScheme: normalizedScheme, host: normalizedHost, port: port, path: path)
    }

    /// Nil when the authority is unusable: no scheme, an empty host, userinfo
    /// that cannot be resolved to a host, or characters that cannot be in a
    /// host.
    public init?(validatingScheme scheme: String?, host: String?, port: Int? = nil, path: String? = nil) {
        guard let normalizedScheme = scheme?.lowercased(), !normalizedScheme.isEmpty,
              let normalizedHost = Self.normalizedHost(host)
        else { return nil }
        self.init(normalizedScheme: normalizedScheme, host: normalizedHost, port: port, path: path)
    }

    private init(normalizedScheme scheme: String, host: String, port: Int?, path: String?) {
        self.scheme = scheme.isEmpty ? nil : scheme
        self.host = host.isEmpty ? nil : host
        self.port = host.isEmpty ? nil : port
        let cleaned = host.isEmpty ? nil : Self.sanitizedPath(path)
        self.path = cleaned
        self.sanitized = Self.text(scheme: scheme, host: host, port: port, path: cleaned)
    }

    /// False for an endpoint built from an unusable authority. Such an endpoint
    /// is stored as an empty record, never as a redacted guess.
    public var isUsable: Bool { !sanitized.isEmpty }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case scheme, host, port, path, sanitized
    }

    /// Decoding re-sanitizes through the designated initializer, so a stored
    /// or hand-written record can never smuggle a query string, userinfo, or a
    /// credential-shaped path back into memory. A stored `sanitized` value is
    /// rebuilt, never trusted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let scheme = try c.decodeIfPresent(String.self, forKey: .scheme)
        let host = try c.decodeIfPresent(String.self, forKey: .host)
        let port = try c.decodeIfPresent(Int.self, forKey: .port)
        let path = try c.decodeIfPresent(String.self, forKey: .path)
        if let normalizedScheme = scheme?.lowercased(), !normalizedScheme.isEmpty,
           let normalizedHost = Self.normalizedHost(host) {
            self.init(normalizedScheme: normalizedScheme, host: normalizedHost, port: port, path: path)
        } else {
            // An unreadable authority becomes an empty endpoint, not a crash and
            // never a partial leak.
            self.init(normalizedScheme: "", host: "", port: nil, path: nil)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(scheme, forKey: .scheme)
        try c.encodeIfPresent(host, forKey: .host)
        try c.encodeIfPresent(port, forKey: .port)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encode(sanitized, forKey: .sanitized)
    }

    /// The safe text form of a URL, or nil when it has no scheme and host.
    public static func sanitized(_ url: URL) -> String? {
        EndpointDescriptor(url: url)?.sanitized
    }

    /// The host with any userinfo removed and lowercase-normalized; nil when
    /// what is left is not a usable authority.
    static func normalizedHost(_ raw: String?) -> String? {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return nil
        }
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        guard !host.isEmpty,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "@/?#\\ \t\n\r")) == nil
        else { return nil }
        return host.lowercased()
    }

    /// A path cut at any query or fragment, with credential-shaped segments
    /// replaced. Nil for an empty or root path.
    static func sanitizedPath(_ raw: String?) -> String? {
        guard var path = raw, !path.isEmpty else { return nil }
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[path.startIndex..<cut])
        }
        guard !path.isEmpty, path != "/" else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            looksLikeCredential(String(segment)) ? "[redacted]" : String(segment)
        }
        return segments.joined(separator: "/")
    }

    /// A path segment that is a named credential pair (`api_key=…`) or carries
    /// a well-known key prefix (`sk-…`, `ghp_…`). Deliberately narrow, so an
    /// ordinary UUID or content hash in a path is left alone.
    static func looksLikeCredential(_ segment: String) -> Bool {
        let lowered = segment.lowercased()
        let labels = [
            "api_key", "apikey", "api-key", "access_token", "auth_token", "token",
            "secret", "password", "passwd", "bearer", "authorization",
        ]
        for label in labels {
            if lowered.hasPrefix(label + "=") || lowered.hasPrefix(label + ":") { return true }
        }
        let prefixes = ["sk-", "pk-", "rk-", "ghp_", "gho_", "ghs_", "github_pat_", "xoxb-", "xoxp-", "aiza", "akia"]
        for prefix in prefixes where lowered.hasPrefix(prefix) && segment.count > prefix.count + 3 {
            return true
        }
        return false
    }

    private static func text(scheme: String, host: String, port: Int?, path: String?) -> String {
        guard !scheme.isEmpty, !host.isEmpty else { return "" }
        var text = "\(scheme)://\(host)"
        if let port { text += ":\(port)" }
        if let path, !path.isEmpty, path != "/" { text += path }
        return text
    }
}

/// Scrubs credential-shaped content out of free text before it is stored in a
/// receipt, a log line, or a chat record.
///
/// The typed `EndpointDescriptor` is already safe by construction. This exists
/// for the places no type can protect: a provider error that echoes the URL it
/// called, a tool argument, a status line. The package never rewrites what it
/// is given (a user's bytes and words are theirs); the consumer calls this
/// before writing.
public enum SecretRedactor {
    /// Redacts, in order: the query and fragment of any URL in the text, a
    /// named credential pair (`api_key=…`, `"token": "…"`), a `Bearer …`
    /// value, and a bare well-known key prefix (`sk-…`, `ghp_…`).
    public static func redact(_ text: String) -> String {
        var result = redactURLs(in: text)
        result = replace(credentialPair, in: result, with: "$1$2$3[redacted]$3")
        result = replace(bearer, in: result, with: "$1[redacted]")
        result = replace(bareKey, in: result, with: "[redacted]")
        return result
    }

    /// True when `redact` would change the text.
    public static func containsCredentialShapedText(_ text: String) -> Bool {
        redact(text) != text
    }

    // MARK: Patterns

    private static let urlPattern = regex(#"https?://[^\s"'<>()\[\]]+"#)
    private static let credentialPair = regex(
        #"(?i)((?:api[_-]?key|apikey|access[_-]?token|auth[_-]?token|refresh[_-]?token|token|secret|password|passwd|authorization))(\"?\s*[:=]\s*)(\"?)([^\s\"&,;]{4,})\3"#
    )
    private static let bearer = regex(#"(?i)(\bbearer\s+)([A-Za-z0-9._\-]{8,})"#)
    private static let bareKey = regex(
        #"\b(?:sk|pk|rk)-[A-Za-z0-9_\-]{6,}|\b(?:ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{6,}|\bxox[bp]-[A-Za-z0-9\-]{6,}|\bAIza[A-Za-z0-9_\-]{10,}|\bAKIA[A-Z0-9]{10,}"#
    )

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // A constant pattern: a failure here is a programmer error, and the
        // test suite covers every branch.
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    /// Cuts every URL in the text at its query and fragment, and redacts a
    /// credential-shaped path segment.
    private static func redactURLs(in text: String) -> String {
        let matches = urlPattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            result += redactedURL(String(text[range]))
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    private static func redactedURL(_ raw: String) -> String {
        var url = raw
        if let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            url = String(url[url.startIndex..<cut])
        }
        let separator = url.contains("://") ? "://" : ""
        var head = ""
        var body = url
        if !separator.isEmpty, let range = url.range(of: separator) {
            head = String(url[url.startIndex..<range.upperBound])
            body = String(url[range.upperBound...])
        }
        let segments = body.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            EndpointDescriptor.looksLikeCredential(String(segment)) ? "[redacted]" : String(segment)
        }
        return head + segments.joined(separator: "/")
    }
}

/// Opaque, app-namespaced fields kept alongside the shared schema.
///
/// This is for data that belongs to one app's own format and should not
/// become a shared field with two owners: QL's `titleSource`, `assistantID`,
/// `enabledTools`, `cards`, `toolRecords`; RTI's meeting-side equivalents.
/// The app writes them under one namespace and reads them back; the shared
/// schema never interprets them, and the conversation file stays the single
/// authority.
public struct AppPayload: Codable, Sendable, Equatable {
    /// "quick-launch", "rti".
    public var namespace: String?
    public var values: ExtraFields
    /// Unknown fields on the payload envelope, distinct from its app values.
    public var extra: ExtraFields

    public init(namespace: String? = nil, values: ExtraFields = ExtraFields(), extra: ExtraFields = ExtraFields()) {
        self.namespace = namespace
        self.values = values
        self.extra = extra
    }

    public init(namespace: String?, _ values: [String: JSONValue]) {
        self.init(namespace: namespace, values: ExtraFields(values))
    }

    private static let knownKeys: Set<String> = ["namespace", "values"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        namespace = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("namespace"))
        values = try c.decodeIfPresent(ExtraFields.self, forKey: AnyCodingKey("values")) ?? ExtraFields()
        extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(namespace, forKey: AnyCodingKey("namespace"))
        try c.encode(values, forKey: AnyCodingKey("values"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }

    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var isEmpty: Bool { values.isEmpty && extra.isEmpty }

    /// Namespaced keys, with the other payload's values merged under the same
    /// namespace. Same-namespace keys from `other` win.
    public func merging(_ other: AppPayload?) -> AppPayload {
        guard let other else { return self }
        var merged = values
        for key in other.values.keys {
            merged[key] = other.values[key]
        }
        var mergedExtra = extra
        for key in other.extra.keys {
            mergedExtra[key] = other.extra[key]
        }
        return AppPayload(namespace: namespace ?? other.namespace, values: merged, extra: mergedExtra)
    }
}
