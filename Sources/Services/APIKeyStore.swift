import Foundation
import Security

enum APIKeyStore {
    private static let service = "com.tristanmcinnis.quick-launch.provider-api-keys"

    /// Service names used by earlier builds. Keys saved there are read once
    /// and copied to `service`, so a rename never strands a provider key.
    static let legacyServices = [
        "com.fullstackoptimization.apfel-quick.provider-api-keys",
    ]

    static func load(providerID: UUID, keychain: any KeychainStoring = SystemKeychainStore()) -> String? {
        if let value = load(providerID: providerID, service: service, keychain: keychain) {
            return value
        }
        for legacyService in legacyServices {
            guard let value = load(providerID: providerID, service: legacyService, keychain: keychain) else { continue }
            // Migrate forward. Leave the legacy item alone so older builds keep working.
            AppLog.attempt("Migrate provider key to the current Keychain service") {
                try save(value, providerID: providerID, keychain: keychain)
            }
            return value
        }
        return nil
    }

    private static func load(providerID: UUID, service: String, keychain: any KeychainStoring) -> String? {
        guard let data = AppLog.attempt("Read provider key from Keychain", {
            try keychain.read(service: service, account: providerID.uuidString)
        }) ?? nil else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ apiKey: String, providerID: UUID, keychain: any KeychainStoring = SystemKeychainStore()) throws {
        do {
            // This Mac only. Do not sync provider secrets through iCloud Keychain.
            try keychain.write(
                Data(apiKey.utf8),
                service: service,
                account: providerID.uuidString,
                options: .thisMacOnly
            )
        } catch {
            throw APIKeyStoreError.keychain(error.status)
        }
    }

    static func delete(providerID: UUID, keychain: any KeychainStoring = SystemKeychainStore()) throws {
        for candidate in [service] + legacyServices {
            do {
                try keychain.delete(service: candidate, account: providerID.uuidString)
            } catch {
                throw APIKeyStoreError.keychain(error.status)
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
