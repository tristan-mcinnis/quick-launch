import CryptoKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screen History media migration", .serialized)
struct ScreenHistoryMediaMigrationServiceTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("shared video blocks and images copy once, then repeat with zero delta")
    func uniqueCopyAndRepeat() async throws {
        let fixture = try MediaMigrationWorkspace()
        let videoURL = try fixture.sourceFile("blocks/shared.mp4", bytes: Data("shared-video".utf8))
        let imageURL = try fixture.sourceFile("images/frame.heic", bytes: Data("still-image".utf8))
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        try await importFrames([
            frame(101, app: "Editor", media: videoURL.path, index: 1),
            frame(102, app: "Browser", media: videoURL.path, index: 2),
            frame(103, app: "Notes", image: imageURL.path),
        ], into: store)
        let service = fixture.service(store: store, now: now)

        let first = try await service.migrate()

        #expect(first.sourceRows == 3)
        #expect(first.uniqueLocators == 2)
        #expect(first.copiedFileDelta == 2)
        #expect(first.hashDelta == 4)
        #expect(first.updatedRowDelta == 3)
        #expect(first.ledgerDelta == 2)
        #expect(first.failures.isEmpty)
        #expect(try fixture.ownedFiles().count == 2)
        #expect(try fixture.permissions(fixture.ownedDirectory) == 0o700)
        for file in try fixture.ownedFiles() {
            #expect(try fixture.permissions(file) == 0o600)
        }
        #expect(try Data(contentsOf: videoURL) == Data("shared-video".utf8))
        #expect(try Data(contentsOf: imageURL) == Data("still-image".utf8))

        let rows = try await store.search(ScreenHistorySearchQuery(limit: 20))
        let videos = rows.filter { $0.mediaLocator != nil }
        #expect(videos.count == 2)
        #expect(Set(videos.compactMap(\.mediaLocator)).count == 1)
        #expect(videos.allSatisfy { $0.mediaLocator?.hasPrefix(fixture.ownedDirectory.path + "/") == true })
        #expect(rows.first(where: { $0.sourceIdentifier == "103" })?.imageLocator?.hasPrefix(
            fixture.ownedDirectory.path + "/"
        ) == true)
        let videoPathHash = sha256(Data(videoURL.resolvingSymlinksInPath().path.utf8))
        let videoLedger = try #require(
            try await store.mediaMigrationLedgerEntry(sourcePathHash: videoPathHash)
        )
        #expect(videoLedger.status == .copied)
        #expect(videoLedger.byteCount == Int64(Data("shared-video".utf8).count))
        #expect(videoLedger.contentHash == sha256(Data("shared-video".utf8)))
        #expect(videoLedger.destinationLocator == videos.first?.mediaLocator)

        let repeated = try await service.migrate()
        #expect(repeated.copiedFileDelta == 0)
        #expect(repeated.hashDelta == 0)
        #expect(repeated.updatedRowDelta == 0)
        #expect(repeated.ledgerDelta == 0)
        #expect(repeated.failures.isEmpty)
    }

    @Test("a copied ledger is accepted only after hashing its source and destination again")
    func repeatLedgerHashProof() async throws {
        let fixture = try MediaMigrationWorkspace()
        let imageURL = try fixture.sourceFile("images/repeat.heic", bytes: Data("repeat-proof".utf8))
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        try await importFrames([frame(111, app: "Editor", image: imageURL.path)], into: store)
        let service = fixture.service(store: store, now: now)
        _ = try await service.migrate()
        try await importFrames([frame(112, app: "Browser", image: imageURL.path)], into: store)

        let repeated = try await service.migrate()

        #expect(repeated.copiedFileDelta == 0)
        #expect(repeated.hashDelta == 2)
        #expect(repeated.updatedRowDelta == 1)
        #expect(repeated.ledgerDelta == 0)
        #expect(repeated.failures.isEmpty)
        let second = try #require(
            try await store.search(ScreenHistorySearchQuery(limit: 20)).first {
                $0.sourceIdentifier == "112"
            }
        )
        #expect(second.imageLocator?.hasPrefix(fixture.ownedDirectory.path + "/") == true)
    }

    @Test("same-size destination tampering fails without rewriting the waiting row")
    func sameSizeTamperingFailsClosed() async throws {
        let fixture = try MediaMigrationWorkspace()
        let sourceBytes = Data("AAAA-same-size".utf8)
        let tamperedBytes = Data("BBBB-same-size".utf8)
        #expect(sourceBytes.count == tamperedBytes.count)
        let imageURL = try fixture.sourceFile("images/tamper.heic", bytes: sourceBytes)
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        try await importFrames([frame(121, app: "Editor", image: imageURL.path)], into: store)
        let service = fixture.service(store: store, now: now)
        _ = try await service.migrate()
        let migrated = try #require(
            try await store.search(ScreenHistorySearchQuery()).first?.imageLocator
        )
        try tamperedBytes.write(to: URL(fileURLWithPath: migrated), options: .atomic)
        try await importFrames([frame(122, app: "Browser", image: imageURL.path)], into: store)

        let rejected = try await service.migrate()

        #expect(rejected.copiedFileDelta == 0)
        #expect(rejected.hashDelta == 2)
        #expect(rejected.updatedRowDelta == 0)
        #expect(rejected.failures.map(\.status) == [.hashMismatch])
        let waiting = try #require(
            try await store.search(ScreenHistorySearchQuery(limit: 20)).first {
                $0.sourceIdentifier == "122"
            }
        )
        #expect(waiting.imageLocator == imageURL.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: migrated)) == tamperedBytes)
    }

    @Test("same-size source changes fail closed and keep the last proven ledger")
    func sameSizeSourceChangeFailsClosed() async throws {
        let fixture = try MediaMigrationWorkspace()
        let originalBytes = Data("AAAA-frozen-src".utf8)
        let changedBytes = Data("BBBB-frozen-src".utf8)
        #expect(originalBytes.count == changedBytes.count)
        let imageURL = try fixture.sourceFile("images/frozen.heic", bytes: originalBytes)
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        try await importFrames([frame(125, app: "Editor", image: imageURL.path)], into: store)
        let service = fixture.service(store: store, now: now)
        _ = try await service.migrate()
        let provenDestination = try #require(
            try await store.search(ScreenHistorySearchQuery()).first?.imageLocator
        )
        try changedBytes.write(to: imageURL, options: .atomic)
        try await importFrames([frame(126, app: "Browser", image: imageURL.path)], into: store)

        let rejected = try await service.migrate()

        #expect(rejected.copiedFileDelta == 0)
        #expect(rejected.hashDelta == 1)
        #expect(rejected.updatedRowDelta == 0)
        #expect(rejected.ledgerDelta == 0)
        #expect(rejected.failures.map(\.status) == [.hashMismatch])
        let waiting = try #require(
            try await store.search(ScreenHistorySearchQuery(limit: 20)).first {
                $0.sourceIdentifier == "126"
            }
        )
        #expect(waiting.imageLocator == imageURL.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: provenDestination)) == originalBytes)
        let sourcePathHash = sha256(Data(imageURL.resolvingSymlinksInPath().path.utf8))
        let ledger = try #require(
            try await store.mediaMigrationLedgerEntry(sourcePathHash: sourcePathHash)
        )
        #expect(ledger.status == .copied)
        #expect(ledger.contentHash == sha256(originalBytes))

        let repeated = try await service.migrate()
        #expect(repeated.hashDelta == 1)
        #expect(repeated.updatedRowDelta == 0)
        #expect(repeated.failures.map(\.status) == [.hashMismatch])
    }

    @Test("an owned media root that is itself a symlink is rejected")
    func ownedRootSymlinkFailsClosed() async throws {
        let fixture = try MediaMigrationWorkspace()
        let imageURL = try fixture.sourceFile("images/root-link.heic", bytes: Data("root-link".utf8))
        let outsideRoot = fixture.directory.appendingPathComponent("outside-owned", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.ownedDirectory,
            withDestinationURL: outsideRoot
        )
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        try await importFrames([frame(128, app: "Editor", image: imageURL.path)], into: store)
        let service = fixture.service(store: store, now: now)

        var receivedError: ScreenHistoryMediaMigrationError?
        do {
            _ = try await service.migrate()
        } catch let error as ScreenHistoryMediaMigrationError {
            receivedError = error
        }

        #expect(receivedError == .ownedMediaRootIsSymbolicLink)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outsideRoot.path).isEmpty)
        #expect(try await store.search(ScreenHistorySearchQuery()).first?.imageLocator == imageURL.path)
        #expect(try Data(contentsOf: imageURL) == Data("root-link".utf8))
    }

    @Test("a symlink at the owned destination is rejected and never followed")
    func destinationSymlinkFailsClosed() async throws {
        let fixture = try MediaMigrationWorkspace()
        let sourceBytes = Data("symlink-source".utf8)
        let imageURL = try fixture.sourceFile("images/link.heic", bytes: sourceBytes)
        let outsideURL = fixture.directory.appendingPathComponent("outside-owned-root.heic")
        try sourceBytes.write(to: outsideURL)
        try FileManager.default.createDirectory(at: fixture.ownedDirectory, withIntermediateDirectories: true)
        let sourcePathHash = sha256(Data(imageURL.resolvingSymlinksInPath().path.utf8))
        let destination = fixture.ownedDirectory.appendingPathComponent("\(sourcePathHash).heic")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outsideURL)
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        try await importFrames([frame(131, app: "Editor", image: imageURL.path)], into: store)

        let rejected = try await fixture.service(store: store, now: now).migrate()

        #expect(rejected.updatedRowDelta == 0)
        #expect(rejected.failures.map(\.status) == [.invalid])
        #expect(try await store.search(ScreenHistorySearchQuery()).first?.imageLocator == imageURL.path)
        #expect(try Data(contentsOf: outsideURL) == sourceBytes)
        #expect((try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
    }

    @Test("a copied ledger destination outside the owned root is rejected")
    func outsideLedgerDestinationFailsClosed() async throws {
        let fixture = try MediaMigrationWorkspace()
        let bytes = Data("outside-ledger".utf8)
        let imageURL = try fixture.sourceFile("images/outside.heic", bytes: bytes)
        let outsideURL = fixture.directory.appendingPathComponent("outside.heic")
        try bytes.write(to: outsideURL)
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        try await importFrames([frame(141, app: "Editor", image: imageURL.path)], into: store)
        let sourcePathHash = sha256(Data(imageURL.resolvingSymlinksInPath().path.utf8))
        _ = try await store.recordMediaMigrationOutcome(
            sourcePathHash: sourcePathHash,
            destinationLocator: outsideURL.path,
            byteCount: Int64(bytes.count),
            contentHash: sha256(bytes),
            status: .copied,
            migratedAt: now
        )

        let rejected = try await fixture.service(store: store, now: now).migrate()

        #expect(rejected.hashDelta == 1)
        #expect(rejected.updatedRowDelta == 0)
        #expect(rejected.failures.map(\.status) == [.invalid])
        #expect(try await store.search(ScreenHistorySearchQuery()).first?.imageLocator == imageURL.path)
        #expect(try Data(contentsOf: outsideURL) == bytes)
    }

    @Test("missing, relative, traversal, and escaping symlink paths stay explicit failures")
    func invalidAndMissingPaths() async throws {
        let fixture = try MediaMigrationWorkspace()
        let outsideURL = fixture.directory.appendingPathComponent("outside.mp4")
        try Data("outside".utf8).write(to: outsideURL)
        let escapingLink = fixture.legacyDirectory.appendingPathComponent("escape.mp4")
        try FileManager.default.createSymbolicLink(at: escapingLink, withDestinationURL: outsideURL)
        let missing = fixture.legacyDirectory.appendingPathComponent("missing.heic").path
        let traversal = fixture.legacyDirectory.appendingPathComponent("../outside.mp4").path
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        try await importFrames([
            frame(201, app: "Missing", image: missing),
            frame(202, app: "Relative", image: "../outside.mp4"),
            frame(203, app: "Traversal", media: traversal, index: 1),
            frame(204, app: "Symlink", media: escapingLink.path, index: 2),
        ], into: store)
        let service = fixture.service(store: store, now: now)

        let result = try await service.migrate()

        #expect(result.copiedFileDelta == 0)
        #expect(result.hashDelta == 0)
        #expect(result.updatedRowDelta == 0)
        #expect(result.failures.count == 4)
        #expect(result.failures.map(\.status).contains(.missing))
        #expect(result.failures.filter { $0.status == .invalid }.count == 3)
        #expect(try fixture.ownedFiles().isEmpty)
        #expect(try await store.search(ScreenHistorySearchQuery(limit: 20)).allSatisfy {
            $0.imageLocator == missing || $0.imageLocator == "../outside.mp4"
                || $0.mediaLocator == traversal || $0.mediaLocator == escapingLink.path
        })

        let repeated = try await service.migrate()
        #expect(repeated.copiedFileDelta == 0)
        #expect(repeated.hashDelta == 0)
        #expect(repeated.updatedRowDelta == 0)
        #expect(repeated.ledgerDelta == 0)
    }

    @Test("hash mismatch leaves the row untouched and a later run resumes")
    func hashMismatchAndResume() async throws {
        let fixture = try MediaMigrationWorkspace()
        let imageURL = try fixture.sourceFile("images/hash.heic", bytes: Data("verified-source".utf8))
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        try await importFrames([frame(301, app: "Editor", image: imageURL.path)], into: store)
        let corruptingService = fixture.service(store: store, now: now) { temporaryURL in
            try Data("changed-after-copy".utf8).write(to: temporaryURL)
        }

        let failed = try await corruptingService.migrate()

        #expect(failed.copiedFileDelta == 1)
        #expect(failed.hashDelta == 2)
        #expect(failed.updatedRowDelta == 0)
        #expect(failed.failures.map(\.status) == [.hashMismatch])
        #expect(try await store.search(ScreenHistorySearchQuery()).first?.imageLocator == imageURL.path)
        #expect(try fixture.ownedFiles().isEmpty)

        let resumed = try await fixture.service(store: store, now: now).migrate()
        #expect(resumed.copiedFileDelta == 1)
        #expect(resumed.hashDelta == 2)
        #expect(resumed.updatedRowDelta == 1)
        #expect(resumed.failures.isEmpty)
        #expect(try await store.search(ScreenHistorySearchQuery()).first?.imageLocator != imageURL.path)
        #expect(try Data(contentsOf: imageURL) == Data("verified-source".utf8))
    }

    @Test("row cursor resumes and converges without recopying earlier media")
    func cursorResume() async throws {
        let fixture = try MediaMigrationWorkspace()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        var inputs: [ScreenHistoryFrameInput] = []
        for id in 401...404 {
            let url = try fixture.sourceFile("images/\(id).heic", bytes: Data("image-\(id)".utf8))
            inputs.append(frame(Int64(id), app: id.isMultiple(of: 2) ? "Editor" : "Browser", image: url.path))
        }
        try await importFrames(inputs, into: store)
        let service = fixture.service(store: store, now: now)

        let first = try await service.migrate(maximumSourceRows: 2, batchSize: 1)
        let cursor = try #require(first.lastFrameID)
        #expect(first.copiedFileDelta == 2)
        #expect(first.updatedRowDelta == 2)

        let second = try await service.migrate(afterFrameID: cursor, batchSize: 1)
        #expect(second.sourceRows == 2)
        #expect(second.copiedFileDelta == 2)
        #expect(second.updatedRowDelta == 2)
        #expect(try fixture.ownedFiles().count == 4)

        let repeated = try await service.migrate()
        #expect(repeated.copiedFileDelta == 0)
        #expect(repeated.hashDelta == 0)
        #expect(repeated.updatedRowDelta == 0)
        #expect(repeated.ledgerDelta == 0)
    }

    @Test("the store refuses a locator update that does not match the imported row")
    func exactRowUpdateGate() async throws {
        let fixture = try MediaMigrationWorkspace()
        let imageURL = try fixture.sourceFile("images/exact.heic", bytes: Data("exact".utf8))
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        try await importFrames([frame(501, app: "Editor", image: imageURL.path)], into: store)
        let row = try #require(try await store.search(ScreenHistorySearchQuery()).first)
        let wrong = ScreenHistoryMediaReference(
            frameID: row.id,
            sourceIdentifier: row.sourceIdentifier,
            kind: .image,
            legacyLocator: imageURL.appendingPathExtension("wrong").path,
            mediaFrameIndex: nil
        )
        var rejected = false
        do {
            _ = try await store.updateImportedMediaLocator(
                wrong,
                destinationLocator: fixture.ownedDirectory.appendingPathComponent("verified.heic").path,
                byteCount: 5,
                contentHash: String(repeating: "a", count: 64),
                sourcePathHash: String(repeating: "b", count: 64),
                migratedAt: now
            )
        } catch {
            rejected = true
        }

        #expect(rejected)
        #expect(try await store.search(ScreenHistorySearchQuery()).first?.imageLocator == imageURL.path)
        #expect(try await store.mediaMigrationLedgerEntry(
            sourcePathHash: String(repeating: "b", count: 64)
        ) == nil)
    }

    @Test("preview sample is bounded and spans time, application, and media kind")
    func boundedSampling() async throws {
        let fixture = try MediaMigrationWorkspace()
        let sharedVideo = try fixture.sourceFile("blocks/sample.mp4", bytes: Data("video".utf8))
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        var inputs: [ScreenHistoryFrameInput] = []
        for ordinal in 0..<12 {
            let id = Int64(601 + ordinal)
            let app = ["Browser", "Editor", "Notes"][ordinal % 3]
            if ordinal.isMultiple(of: 2) {
                let image = try fixture.sourceFile(
                    "images/sample-\(ordinal).heic",
                    bytes: Data("sample-\(ordinal)".utf8)
                )
                inputs.append(frame(id, app: app, image: image.path, offset: TimeInterval(ordinal * 60)))
            } else {
                inputs.append(frame(
                    id,
                    app: app,
                    media: sharedVideo.path,
                    index: ordinal,
                    offset: TimeInterval(ordinal * 60)
                ))
            }
        }
        try await importFrames(inputs, into: store)
        let service = fixture.service(store: store, now: now)
        _ = try await service.migrate()

        let sample = try await service.migratedMomentSample(limit: 5)

        #expect(sample.count == 5)
        #expect(sample.map(\.capturedAt) == sample.map(\.capturedAt).sorted())
        #expect(Set(sample.compactMap(\.application)).count >= 2)
        #expect(sample.contains { $0.imageLocator != nil })
        #expect(sample.contains { $0.mediaLocator != nil })
        #expect(try await service.migratedMomentSample(limit: 500).count <= 100)
    }

    private func frame(
        _ id: Int64,
        app: String,
        image: String? = nil,
        media: String? = nil,
        index: Int? = nil,
        offset: TimeInterval = 0
    ) -> ScreenHistoryFrameInput {
        ScreenHistoryFrameInput(
            source: .coast,
            sourceIdentifier: String(id),
            capturedAt: now.addingTimeInterval(-10_000 + offset),
            application: app,
            bundleIdentifier: "test.synthetic.\(app.lowercased())",
            windowTitle: "Synthetic \(id)",
            ocrText: "synthetic media migration \(id)",
            imageLocator: image,
            mediaLocator: media,
            mediaFrameIndex: index,
            byteCount: 1,
            sequenceIdentifier: "synthetic-sequence",
            sequenceOrdinal: Int(id)
        )
    }

    private func importFrames(
        _ frames: [ScreenHistoryFrameInput],
        into store: SQLiteScreenHistoryStore
    ) async throws {
        for frame in frames {
            _ = try await store.applyMigration(frame, status: .imported, migratedAt: now)
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class MediaMigrationWorkspace: @unchecked Sendable {
    let directory: URL
    let legacyDirectory: URL
    let ownedDirectory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-media-migration-\(UUID().uuidString)", isDirectory: true)
        legacyDirectory = directory.appendingPathComponent("legacy", isDirectory: true)
        ownedDirectory = directory.appendingPathComponent("owned", isDirectory: true)
        databaseURL = directory.appendingPathComponent("screen-history.sqlite3")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func sourceFile(_ relativePath: String, bytes: Data) throws -> URL {
        let url = legacyDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    func service(
        store: SQLiteScreenHistoryStore,
        now: Date,
        afterCopy: (@Sendable (URL) throws -> Void)? = nil
    ) -> ScreenHistoryMediaMigrationService {
        ScreenHistoryMediaMigrationService(
            store: store,
            legacyContentRootURL: legacyDirectory,
            ownedMediaDirectoryURL: ownedDirectory,
            clock: { now },
            afterCopy: afterCopy
        )
    }

    func ownedFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: ownedDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: ownedDirectory,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".partial-") }
    }

    func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try #require(value).intValue
    }
}
