import CryptoKit
import Foundation
import Security
import Testing
@testable import QuickLaunch

@Suite("Keychain store")
struct KeychainStoreTests {
    @Test func inMemoryStoreBehavesLikeGenericPasswordItems() throws {
        let keychain = InMemoryKeychainStore()
        #expect(try keychain.read(service: "s", account: "a") == nil)
        #expect(try keychain.update(Data("x".utf8), service: "s", account: "a") == false)

        try keychain.add(Data("one".utf8), service: "s", account: "a", options: .thisMacOnly)
        #expect(try keychain.read(service: "s", account: "a") == Data("one".utf8))
        #expect(throws: KeychainError(status: errSecDuplicateItem)) {
            try keychain.add(Data("two".utf8), service: "s", account: "a", options: .thisMacOnly)
        }
        #expect(try keychain.update(Data("two".utf8), service: "s", account: "a") == true)
        #expect(try keychain.read(service: "s", account: "a") == Data("two".utf8))
        #expect(keychain.storedItems["s"]?["a"]?.options == .thisMacOnly)

        try keychain.delete(service: "s", account: "a")
        try keychain.delete(service: "s", account: "a")
        #expect(try keychain.read(service: "s", account: "a") == nil)
    }

    @Test func writeUpdatesOrAdds() throws {
        let keychain = InMemoryKeychainStore()
        try keychain.write(Data("a".utf8), service: "s", account: "k", options: .thisMacOnly)
        try keychain.write(Data("b".utf8), service: "s", account: "k", options: .thisMacOnly)
        #expect(try keychain.read(service: "s", account: "k") == Data("b".utf8))
        #expect(keychain.storedItems["s"]?.count == 1)
    }

    @Test func apiKeyStoreSavesLoadsAndDeletesThroughTheClient() throws {
        let keychain = InMemoryKeychainStore()
        let provider = UUID()
        #expect(APIKeyStore.load(providerID: provider, keychain: keychain) == nil)

        try APIKeyStore.save("sk-test", providerID: provider, keychain: keychain)
        #expect(APIKeyStore.load(providerID: provider, keychain: keychain) == "sk-test")
        let stored = keychain.storedItems["com.tristanmcinnis.quick-launch.provider-api-keys"]?[provider.uuidString]
        #expect(stored?.options.synchronizable == false)

        try APIKeyStore.save("sk-new", providerID: provider, keychain: keychain)
        #expect(APIKeyStore.load(providerID: provider, keychain: keychain) == "sk-new")

        try APIKeyStore.delete(providerID: provider, keychain: keychain)
        #expect(APIKeyStore.load(providerID: provider, keychain: keychain) == nil)
    }

    @Test func apiKeyStoreMigratesLegacyServiceForward() throws {
        let keychain = InMemoryKeychainStore()
        let provider = UUID()
        let legacy = APIKeyStore.legacyServices[0]
        #expect(legacy == "com.fullstackoptimization.apfel-quick.provider-api-keys")
        try keychain.add(Data("legacy-key".utf8), service: legacy, account: provider.uuidString, options: .thisMacOnly)

        #expect(APIKeyStore.load(providerID: provider, keychain: keychain) == "legacy-key")
        let items = keychain.storedItems
        #expect(items["com.tristanmcinnis.quick-launch.provider-api-keys"]?[provider.uuidString]?.data == Data("legacy-key".utf8))
        // The legacy item is left for older builds.
        #expect(items[legacy]?[provider.uuidString] != nil)

        try APIKeyStore.delete(providerID: provider, keychain: keychain)
        #expect(keychain.storedItems.isEmpty)
    }

    @Test func apiKeyStoreSurfacesKeychainStatus() {
        let keychain = InMemoryKeychainStore()
        keychain.failureStatus = errSecAuthFailed
        #expect(APIKeyStore.load(providerID: UUID(), keychain: keychain) == nil)
        #expect(throws: APIKeyStoreError.self) {
            try APIKeyStore.save("x", providerID: UUID(), keychain: keychain)
        }
    }

    @Test func apiKeyLoadResultSeparatesNoKeyFromAKeychainFailure() throws {
        let provider = UUID()
        let empty = InMemoryKeychainStore()
        #expect(try APIKeyStore.loadResult(providerID: provider, keychain: empty).get() == nil)

        let locked = InMemoryKeychainStore()
        try APIKeyStore.save("sk-test", providerID: provider, keychain: locked)
        locked.failureStatus = errSecAuthFailed
        // The key exists; the failure to read it must not read as "no key".
        let result = APIKeyStore.loadResult(providerID: provider, keychain: locked)
        #expect((try? result.get()) == nil)
        #expect(result == .failure(KeychainError(status: errSecAuthFailed)))
    }

    @Test func coastIntegrityKeyIsCreatedOnceAndReused() throws {
        let keychain = InMemoryKeychainStore()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-coast-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let fallback = folder.appendingPathComponent("integrity.key")

        let first = try ScreenHistoryCoastFreezeReceiptService.loadOrCreateIntegrityKeyForTesting(
            receiptDirectoryURL: folder, fallbackFileURL: fallback, keychain: keychain
        )
        let second = try ScreenHistoryCoastFreezeReceiptService.loadOrCreateIntegrityKeyForTesting(
            receiptDirectoryURL: folder, fallbackFileURL: fallback, keychain: keychain
        )
        #expect(first == second)
        let items = keychain.storedItems[ScreenHistoryCoastFreezeReceiptService.integrityKeyServiceForTesting]
        #expect(items?.count == 1)
        #expect(items?.values.first?.data.count == 32)
        #expect(items?.values.first?.options.accessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(!FileManager.default.fileExists(atPath: fallback.path))
    }

    @Test func coastIntegrityKeyFallsBackToOwnerOnlyFileWhenKeychainIsLocked() throws {
        let keychain = InMemoryKeychainStore()
        keychain.failureStatus = errSecInteractionNotAllowed
        // The fallback refuses any symlinked path component, so use a
        // real /private/tmp folder (mkdtemp makes it owner-only).
        var template = Array("/private/tmp/quick-launch-keychain-tests.XXXXXX".utf8CString)
        try #require(mkdtemp(&template) != nil)
        let folder = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fallback = folder.appendingPathComponent("integrity.key")

        let key = try ScreenHistoryCoastFreezeReceiptService.loadOrCreateIntegrityKeyForTesting(
            receiptDirectoryURL: folder, fallbackFileURL: fallback, keychain: keychain
        )
        #expect(FileManager.default.fileExists(atPath: fallback.path))
        let again = try ScreenHistoryCoastFreezeReceiptService.loadOrCreateIntegrityKeyForTesting(
            receiptDirectoryURL: folder, fallbackFileURL: fallback, keychain: keychain
        )
        #expect(key == again)
        #expect(keychain.storedItems.isEmpty)
    }

    @Test func coastIntegrityKeyReportsOtherKeychainFailures() {
        let keychain = InMemoryKeychainStore()
        keychain.failureStatus = errSecInternalError
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString)")
        #expect(throws: ScreenHistoryCoastFreezeReceiptError.self) {
            try ScreenHistoryCoastFreezeReceiptService.loadOrCreateIntegrityKeyForTesting(
                receiptDirectoryURL: folder, fallbackFileURL: folder.appendingPathComponent("k"), keychain: keychain
            )
        }
    }
}
