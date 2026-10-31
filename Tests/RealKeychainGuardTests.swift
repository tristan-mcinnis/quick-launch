import Foundation
import Testing
@testable import QuickLaunch

/// Views and view models reach the Keychain only through the injected
/// `QuickViewModel.keychain`. Rendering the Models pane in a test once read
/// the real provider and search keys, which can prompt and hang `swift test`.
@Suite("Real Keychain guard")
@MainActor
struct RealKeychainGuardTests {
    private static let sourcesRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources")

    private static let keychainCalls = [
        "APIKeyStore.load(", "APIKeyStore.save(", "APIKeyStore.delete(",
        "APIKeyStore.loadFeatureKey(", "APIKeyStore.saveFeatureKey(", "APIKeyStore.deleteFeatureKey(",
    ]

    /// The one production lookup the app injects as `apiKeyProvider`.
    private static let allowed = ["static let keychainAPIKey"]

    @Test func viewsAndViewModelsPassTheInjectedKeychain() throws {
        for directory in ["Views", "ViewModels"] {
            let root = Self.sourcesRoot.appending(path: directory)
            let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated()
                where Self.keychainCalls.contains(where: line.contains)
                    && !line.contains("keychain:")
                    && !Self.allowed.contains(where: line.contains) {
                    Issue.record("\(file.lastPathComponent):\(index + 1): Keychain call without the injected store -> pass keychain: viewModel.keychain")
                }
            }
        }
    }

    /// The other direction: a view model the app builds without `keychain:`
    /// would show "Key saved in Keychain" and keep the key only in memory.
    @Test func everyAppViewModelGetsTheSystemKeychain() throws {
        let root = Self.sourcesRoot.appending(path: "App")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var found = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            var rest = source[...]
            while let start = rest.range(of: "QuickViewModel(") {
                var depth = 1
                var end = start.upperBound
                while end < rest.endIndex, depth > 0 {
                    if rest[end] == "(" { depth += 1 } else if rest[end] == ")" { depth -= 1 }
                    end = rest.index(after: end)
                }
                let call = rest[start.lowerBound..<end]
                found += 1
                #expect(call.contains("keychain: SystemKeychainStore()"), "\(file.lastPathComponent): QuickViewModel built without keychain: SystemKeychainStore()")
                rest = rest[end...]
            }
        }
        #expect(found >= 2, "found the app's view models")
    }

    @Test func aViewModelBuiltWithoutAKeychainHoldsNoRealOne() {
        let vm = QuickViewModel(settings: QuickSettings())
        #expect(!(vm.keychain is SystemKeychainStore))
    }
}
