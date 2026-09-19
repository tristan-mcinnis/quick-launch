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
        switch loadResult(providerID: providerID, keychain: keychain) {
        case .success(let value):
            return value
        case .failure(let error):
            // A locked, denied, or undecodable item is not "no key". Leave the
            // real status in the log rather than reporting a missing key.
            AppLog.persistence.error(
                "Read provider key from Keychain failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Reads a provider key, separating "nothing stored" from a real Keychain
    /// failure, so a caller can show `errSecAuthFailed` instead of asking for
    /// a key that already exists. `load` keeps its value-only shape for
    /// presence checks.
    static func loadResult(
        providerID: UUID,
        keychain: any KeychainStoring = SystemKeychainStore()
    ) -> Result<String?, KeychainError> {
        switch loadValue(providerID: providerID, service: service, keychain: keychain) {
        case .failure(let error):
            return .failure(error)
        case .success(let value):
            if let value { return .success(value) }
        }
        for legacyService in legacyServices {
            switch loadValue(providerID: providerID, service: legacyService, keychain: keychain) {
            case .failure(let error):
                return .failure(error)
            case .success(let value):
                guard let value else { continue }
                // Migrate forward. Leave the legacy item alone so older builds keep working.
                AppLog.attempt("Migrate provider key to the current Keychain service") {
                    try save(value, providerID: providerID, keychain: keychain)
                }
                return .success(value)
            }
        }
        return .success(nil)
    }

    private static func loadValue(
        providerID: UUID,
        service: String,
        keychain: any KeychainStoring
    ) -> Result<String?, KeychainError> {
        do {
            guard let data = try keychain.read(service: service, account: providerID.uuidString) else {
                return .success(nil)
            }
            return .success(String(data: data, encoding: .utf8))
        } catch {
            return .failure(error)
        }
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
