import Foundation
import Testing
@testable import QuickLaunch

/// The blob folder is owner-only from launch, not only after the next
/// image or rich-text copy writes a blob.
@Suite("Clipboard blob folder permissions")
struct ClipboardBlobFolderTests {
    @Test func aWorldReadableFolderIsTightenedWhenTheStoreOpens() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = ClipboardBlobStore(directory: folder)
        store.flush()

        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func aMissingFolderIsNotCreatedByOpening() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blob-folder-\(UUID().uuidString)", isDirectory: true)
        let store = ClipboardBlobStore(directory: folder)
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
