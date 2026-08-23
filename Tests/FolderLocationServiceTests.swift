import Foundation
import Testing
@testable import QuickLaunch

@Suite("FolderLocationService")
struct FolderLocationServiceTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-location-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func builtInIdentifiersAreUnique() {
        let ids = FolderLocationService.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("downloads"))
        #expect(ids.contains("desktop"))
    }

    @Test func builtInPathsAreTildeOrAbsolute() {
        for location in FolderLocationService.builtIn {
            #expect(location.path.hasPrefix("~") || location.path.hasPrefix("/"), "\(location.id)")
            #expect(location.isBuiltIn)
            #expect(!location.systemImage.isEmpty)
        }
    }

    @Test func expandedURLExpandsTilde() {
        let location = FolderLocation(id: "x", title: "X", path: "~/Downloads", systemImage: "folder", isBuiltIn: true)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(location.expandedURL.path == home + "/Downloads")
        #expect(!location.expandedURL.path.contains("~"))
    }

    @Test func expandedURLKeepsAbsolutePaths() {
        let location = FolderLocation(id: "x", title: "X", path: "/Applications", systemImage: "folder", isBuiltIn: true)
        #expect(location.expandedURL.path == "/Applications")
    }

    @Test func customUsesLastPathComponentAsTitle() {
        let location = FolderLocationService.custom(from: URL(fileURLWithPath: "/Users/someone/Projects/Quick Launch"))
        #expect(location.title == "Quick Launch")
        #expect(location.path == "/Users/someone/Projects/Quick Launch")
        #expect(!location.isBuiltIn)
        #expect(location.systemImage == "folder")
    }

    @Test func customIdentifierIsStable() {
        let url = URL(fileURLWithPath: "/Users/someone/Projects/Quick Launch")
        let first = FolderLocationService.custom(from: url)
        let second = FolderLocationService.custom(from: url)
        #expect(first.id == second.id)
        #expect(first.id == StableIdentifier.make(url.standardizedFileURL.path))
        let other = FolderLocationService.custom(from: URL(fileURLWithPath: "/Users/someone/Other"))
        #expect(other.id != first.id)
    }

    @Test func availableDropsMissingFolders() throws {
        let existing = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: existing) }
        let missing = existing.appendingPathComponent("missing-\(UUID().uuidString)")
        let result = FolderLocationService.available(custom: [
            FolderLocationService.custom(from: existing),
            FolderLocationService.custom(from: missing),
        ])
        let paths = result.map(\.expandedURL.standardizedFileURL.path)
        #expect(paths.contains(existing.standardizedFileURL.path))
        #expect(!paths.contains(missing.standardizedFileURL.path))
    }

    @Test func availableDeduplicatesByExpandedPath() throws {
        let existing = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: existing) }
        let duplicate = FolderLocationService.custom(from: existing)
        let downloads = FolderLocation(id: "dup", title: "Dup", path: "~/Downloads", systemImage: "folder", isBuiltIn: false)
        let result = FolderLocationService.available(custom: [duplicate, duplicate, downloads])
        let paths = result.map(\.expandedURL.standardizedFileURL.path)
        #expect(Set(paths).count == paths.count)
        let matches = paths.filter { $0 == existing.standardizedFileURL.path }.count
        let keptDuplicateDownloads = result.contains { $0.id == "dup" }
        #expect(matches == 1)
        #expect(!keptDuplicateDownloads)
    }

    @Test func availableKeepsBuiltInFirst() {
        let result = FolderLocationService.available(custom: [])
        let allBuiltIn = result.allSatisfy(\.isBuiltIn)
        #expect(allBuiltIn)
        #expect(result.first?.id == "home")
    }

    @Test func openPlanUsesOsascriptWithPathAsLastArgument() {
        let location = FolderLocation(id: "x", title: "X", path: "~/Downloads", systemImage: "folder", isBuiltIn: true)
        let plan = FolderLocationService.openPlan(for: location)
        #expect(plan.executable == "/usr/bin/osascript")
        #expect(plan.arguments.first == "-e")
        #expect(plan.arguments.contains(FolderLocationService.finderScript))
        #expect(plan.arguments.contains("--"))
        #expect(plan.arguments.last == location.expandedURL.path)
        #expect(plan.arguments.firstIndex(of: "--")! < plan.arguments.count - 1)
    }

    @Test func openPlanScriptNeverContainsThePath() {
        let location = FolderLocation(id: "x", title: "X", path: "/tmp/it's \"quoted\"", systemImage: "folder", isBuiltIn: false)
        let plan = FolderLocationService.openPlan(for: location)
        let script = plan.arguments[1]
        #expect(!script.contains("/tmp"))
        #expect(!script.contains("quoted"))
        #expect(script.contains("item 1 of argv"))
        #expect(script.contains("return \"fronted\""))
        #expect(script.contains("return \"opened\""))
    }

    @Test func folderLocationRoundTripsThroughCodable() throws {
        let location = FolderLocationService.custom(from: URL(fileURLWithPath: "/Users/someone/Projects"))
        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(FolderLocation.self, from: data)
        #expect(decoded == location)
        #expect(decoded.expandedURL == location.expandedURL)
    }
}
