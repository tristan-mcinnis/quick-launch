import Foundation
import Testing
@testable import QuickLaunch

/// Tests must never open a real browser tab, Finder window, or app, or quit
/// one. A view model built without these seams (most tests) gets
/// `InMemoryWorkspace` and `NoRunningApplications`; only the app injects the
/// system ones. A typed-URL
/// test once opened example.com in Tristan's browser on every run.
@Suite("Real workspace guard")
@MainActor
struct RealWorkspaceGuardTests {
    private static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent() // Tests/
        url.deleteLastPathComponent() // repo root
        return url
    }()

    @Test func aViewModelBuiltWithoutAWorkspaceOpensNothingReal() async throws {
        let vm = QuickViewModel(
            settings: QuickSettings(),
            launcherUsage: LauncherUsageStore(fileURL: nil),
            interactionJournal: InteractionJournalStore(fileURL: nil)
        )
        #expect(!(vm.workspace is SystemWorkspace))
        let workspace = try #require(vm.workspace as? InMemoryWorkspace)

        vm.input = "https://example.com/guard"
        let row = try #require(vm.launcherMatches.first { result in
            guard case .item(let item) = result else { return false }
            return item.itemID.hasPrefix("typed:")
        })
        await vm.performLauncherResult(row)

        #expect(workspace.openedURLs.map(\.absoluteString) == ["https://example.com/guard"])
    }

    @Test func aViewModelBuiltWithoutRunningApplicationsControlsNoRealApp() {
        let vm = QuickViewModel(settings: QuickSettings())
        #expect(vm.runningApplications is NoRunningApplications)
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        #expect(vm.runningApplications.runningApplication(
            bundleIdentifier: "com.apple.finder", bundleURL: finder
        ) == nil)
    }

    /// Opening calls that reach AppKit stay behind a seam the tests replace.
    /// A new direct call elsewhere would let a test open a real window.
    @Test func onlySeamFilesCallTheRealOpeners() throws {
        let allowed: Set<String> = [
            "Sources/Services/SystemServices.swift",
            "Sources/Services/ApplicationCatalogService.swift",
            "Sources/Services/SelectedTextService.swift",
            "Sources/App/AppDelegate.swift",
            "Sources/App/AppActivation.swift",
            "Sources/Views/ChatContextRecordView.swift",
        ]
        let offenders = try Self.files(under: "Sources").filter { path in
            try !allowed.contains(path) && Self.callsRealOpener(Self.source(path))
        }
        #expect(offenders.isEmpty, "Route these through `WorkspaceOpening`: \(offenders)")
    }

    @Test func noTestReachesTheRealWorkspace() throws {
        let offenders = try Self.files(under: "Tests").filter { path in
            guard path != "Tests/RealWorkspaceGuardTests.swift" else { return false }
            let source = try Self.source(path)
            return source.contains("SystemWorkspace(")
                || source.contains("SystemRunningApplications(")
                || Self.callsRealOpener(source)
        }
        #expect(offenders.isEmpty, "Inject `FakeWorkspace` instead: \(offenders)")
    }

    /// Every write to the system clipboard goes through `PasteboardWriting`,
    /// so a test with the fake or in-memory pasteboard cannot overwrite the
    /// user's clipboard. Reads of `.general` are fine.
    @Test func onlySeamFilesWriteTheGeneralPasteboard() throws {
        let allowed: Set<String> = [
            "Sources/Services/SystemServices.swift",
            // The paste service writes the answer, then guards Command-V on it.
            "Sources/Services/SelectedTextService.swift",
        ]
        let offenders = try Self.files(under: "Sources").filter { path in
            try !allowed.contains(path) && Self.writesGeneralPasteboard(Self.source(path))
        }
        #expect(offenders.isEmpty, "Route these through `PasteboardWriting`: \(offenders)")
    }

    @Test func noTestWritesTheGeneralPasteboard() throws {
        let offenders = try Self.files(under: "Tests").filter { path in
            guard path != "Tests/RealWorkspaceGuardTests.swift" else { return false }
            return try Self.writesGeneralPasteboard(Self.source(path))
        }
        #expect(offenders.isEmpty, "Use `FakePasteboard`, never `.general`: \(offenders)")
    }

    private static func writesGeneralPasteboard(_ source: String) -> Bool {
        source.contains(/write\(to:\s*(NSPasteboard)?\.general\)/)
            || source.contains(/NSPasteboard\s*\.\s*general\s*\.\s*(clearContents|setString|setData|setPropertyList|writeObjects|declareTypes)/)
    }

    private static func callsRealOpener(_ source: String) -> Bool {
        source.contains(/NSWorkspace\s*\.\s*shared\s*\.\s*(open|activateFileViewerSelecting)/)
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func files(under directory: String) throws -> [String] {
        let base = repoRoot.appendingPathComponent(directory)
        let enumerator = try #require(FileManager.default.enumerator(atPath: base.path))
        return enumerator.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .map { "\(directory)/\($0)" }
    }
}
