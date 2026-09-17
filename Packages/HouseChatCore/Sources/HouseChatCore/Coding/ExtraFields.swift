import Foundation

/// A coding key for any string, so a record can walk its own JSON.
public struct AnyCodingKey: CodingKey, Sendable, Hashable {
    public let stringValue: String
    public var intValue: Int? { nil }

    public init(_ string: String) { self.stringValue = string }

    public init?(stringValue: String) { self.stringValue = stringValue }

    public init?(intValue: Int) { nil }
}

/// Keys this build does not know about, kept verbatim so a newer build's
/// record survives an older build reading and rewriting it.
///
/// Every schema record exposes an `extra` property of this type. On decode the
/// record collects the keys it does not model; on encode it writes them back at
/// the same level. This is how a legacy record with missing fields and a newer
/// record with added fields both round trip.
public struct ExtraFields: Codable, Sendable, Equatable, Hashable {
    public private(set) var values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public var isEmpty: Bool { values.isEmpty }

    /// Known keys in a stable order, so encoding is deterministic.
    public var keys: [String] { values.keys.sorted() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.values = (try? container.decode([String: JSONValue].self)) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// Every key not named in `known`, decoded as a JSON value.
    public func extras(excluding known: Set<String>) -> ExtraFields {
        var values: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            if let value = try? decode(JSONValue.self, forKey: key) {
                values[key.stringValue] = value
            }
        }
        return ExtraFields(values)
    }
}

extension KeyedEncodingContainer where Key == AnyCodingKey {
    /// Writes each unknown key back at the record's own level.
    public mutating func encodeExtras(_ extras: ExtraFields, excluding known: Set<String>) throws {
        for key in extras.keys where !known.contains(key) {
            guard let value = extras.values[key] else { continue }
            try encode(value, forKey: AnyCodingKey(key))
        }
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// A required, non-empty string. Missing, null, wrong type, or empty all
    /// fail closed: identity is never invented.
    public func decodeNonEmptyString(forKey key: AnyCodingKey) throws -> String {
        let value = try decode(String.self, forKey: key)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "empty \(key.stringValue)"
            )
        }
        return value
    }
}
