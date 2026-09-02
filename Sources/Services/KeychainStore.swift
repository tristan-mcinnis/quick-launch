import Foundation
import Security

/// Error carrying the raw Security framework status so callers can react to
/// specific codes (`errSecAuthFailed`, `errSecDuplicateItem`, ...).
struct KeychainError: LocalizedError, Equatable, Sendable {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

/// Attributes applied when a generic-password item is first created.
struct KeychainItemOptions: Equatable, Sendable {
    /// `kSecAttrSynchronizable`. `nil` leaves the attribute unset.
    var synchronizable: Bool?
    /// `kSecAttrAccessible` value, for example
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. `nil` leaves it unset.
    var accessible: String?

    init(synchronizable: Bool? = nil, accessible: String? = nil) {
        self.synchronizable = synchronizable
        self.accessible = accessible
    }

    /// Never sync through iCloud Keychain.
    static let thisMacOnly = KeychainItemOptions(synchronizable: false)
}

/// Generic-password Keychain access behind a protocol, so the app has one
/// client and tests can use an in-memory fake instead of the real Keychain.
protocol KeychainStoring: Sendable {
    /// The stored bytes, or `nil` when no item matches.
    func read(service: String, account: String) throws(KeychainError) -> Data?
    /// Creates a new item. Fails with `errSecDuplicateItem` when one exists.
    func add(_ data: Data, service: String, account: String, options: KeychainItemOptions) throws(KeychainError)
    /// Replaces the bytes of an existing item. Returns `false` when there is none.
    func update(_ data: Data, service: String, account: String) throws(KeychainError) -> Bool
    /// Removes the item. A missing item is not an error.
    func delete(service: String, account: String) throws(KeychainError)
}

extension KeychainStoring {
    /// Update-or-add.
    func write(_ data: Data, service: String, account: String, options: KeychainItemOptions) throws(KeychainError) {
        if try update(data, service: service, account: account) { return }
        try add(data, service: service, account: account, options: options)
    }
}

/// The real Keychain.
struct SystemKeychainStore: KeychainStoring {
    init() {}

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(service: String, account: String) throws(KeychainError) -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return item as? Data ?? Data()
    }

    func add(_ data: Data, service: String, account: String, options: KeychainItemOptions) throws(KeychainError) {
        var item = baseQuery(service: service, account: account)
        item[kSecValueData as String] = data
        if let synchronizable = options.synchronizable {
            item[kSecAttrSynchronizable as String] = synchronizable
        }
        if let accessible = options.accessible {
            item[kSecAttrAccessible as String] = accessible
        }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func update(_ data: Data, service: String, account: String) throws(KeychainError) -> Bool {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(
            baseQuery(service: service, account: account) as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw KeychainError(status: status)
    }

    func delete(service: String, account: String) throws(KeychainError) {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

/// In-memory Keychain for tests. Never touches the real Keychain.
/// `@unchecked`: `items` is guarded by `lock`; `failureStatus` is set once
/// by the test before any concurrent use.
final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
    struct Item: Equatable, Sendable {
        var data: Data
        var options: KeychainItemOptions
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    /// When set, every call fails with this status. Simulates a locked
    /// or denied Keychain.
    var failureStatus: OSStatus?

    init() {}

    private static func key(_ service: String, _ account: String) -> String {
        service + "\u{1F}" + account
    }

    /// Everything stored, keyed by `service` then `account`.
    var storedItems: [String: [String: Item]] {
        lock.withLock {
            var result: [String: [String: Item]] = [:]
            for (key, item) in items {
                let parts = key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
                result[parts[0], default: [:]][parts[1]] = item
            }
            return result
        }
    }

    private func checkFailure() throws(KeychainError) {
        if let failureStatus { throw KeychainError(status: failureStatus) }
    }

    func read(service: String, account: String) throws(KeychainError) -> Data? {
        try checkFailure()
        return lock.withLock { items[Self.key(service, account)]?.data }
    }

    func add(_ data: Data, service: String, account: String, options: KeychainItemOptions) throws(KeychainError) {
        try checkFailure()
        let key = Self.key(service, account)
        let inserted: Bool = lock.withLock {
            if items[key] != nil { return false }
            items[key] = Item(data: data, options: options)
            return true
        }
        if !inserted { throw KeychainError(status: errSecDuplicateItem) }
    }

    func update(_ data: Data, service: String, account: String) throws(KeychainError) -> Bool {
        try checkFailure()
        let key = Self.key(service, account)
        return lock.withLock {
            guard items[key] != nil else { return false }
            items[key]?.data = data
            return true
        }
    }

    func delete(service: String, account: String) throws(KeychainError) {
        try checkFailure()
        lock.withLock { _ = items.removeValue(forKey: Self.key(service, account)) }
    }
}
