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

    @Test func aViewModelBuiltWithoutAKeychainHoldsNoRealOne() {
        let vm = QuickViewModel(settings: QuickSettings())
        #expect(!(vm.keychain is SystemKeychainStore))
    }
}
