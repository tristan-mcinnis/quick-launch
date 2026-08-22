import Foundation
import Security

enum APIKeyStore {
    private static let service = "com.tristanmcinnis.quick-launch.provider-api-keys"

    /// Service names used by earlier builds. Keys saved there are read once
    /// and copied to `service`, so a rename never strands a provider key.
    static let legacyServices = [
        "com.fullstackoptimization.apfel-quick.provider-api-keys",
    ]

    static func load(providerID: UUID) -> String? {
        if let value = load(providerID: providerID, service: service) {
            return value
        }
        for legacyService in legacyServices {
            guard let value = load(providerID: providerID, service: legacyService) else { continue }
            // Migrate forward. Leave the legacy item alone so older builds keep working.
            try? save(value, providerID: providerID)
            return value
        }
        return nil
    }

    private static func load(providerID: UUID, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ apiKey: String, providerID: UUID) throws {
        let value = Data(apiKey.utf8)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID.uuidString,
        ]
        let attributes: [String: Any] = [kSecValueData as String: value]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(updateStatus)
        }

        var newItem = lookup
        newItem[kSecValueData as String] = value
        // This Mac only. Do not sync provider secrets through iCloud Keychain.
        newItem[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw APIKeyStoreError.keychain(addStatus)
        }
    }

    static func delete(providerID: UUID) throws {
        for candidate in [service] + legacyServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate,
                kSecAttrAccount as String: providerID.uuidString,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw APIKeyStoreError.keychain(status)
            }
        }
    }
}

enum APIKeyStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain error \(status)"
        }
    }
}
