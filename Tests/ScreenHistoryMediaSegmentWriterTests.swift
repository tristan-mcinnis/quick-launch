import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screen history compacted capture media", .serialized)
struct ScreenHistoryMediaSegmentWriterTests {
    @Test func interruptedStageRecoversIntoOneExactFrameVideo() async throws {
        let fixture = try SegmentWorkspace()
        var firstWriter: AVFoundationScreenHistoryMediaSegmentWriter? = try fixture.writer(maximumFrames: 3)
        let red = try Self.frame(at: 100, fingerprint: 1, color: .red, text: "recover red")

        #expect(try await firstWriter?.append(red).isEmpty == true)
        firstWriter = nil

        let recoveredWriter = try fixture.writer(maximumFrames: 3)
        let recovered = try await recoveredWriter.flush()
        let segment = try #require(recovered.first)
        #expect(recovered.count == 1)
        #expect(segment.frames == [red])
        #expect(segment.mediaURL.pathExtension == "mp4")
        let finalizedBytes = try fixture.fileSize(segment.mediaURL)
        #expect(segment.byteCount == finalizedBytes)

        let preview = try #require(await ScreenHistoryMediaPreviewService.image(for: Self.previewFrame(
            segment: segment,
            index: 0
        )))
        #expect(try Self.dominantColor(in: preview) == .red)

        try await recoveredWriter.commit(segment)
        #expect(try fixture.stagingDirectories().isEmpty)
        #expect(FileManager.default.fileExists(atPath: segment.mediaURL.path))
        #expect(try fixture.permissions(segment.mediaURL) == 0o600)
    }

    @Test func segmentedSinkPreservesSchemaSevenAndAttributesExactMediaBytes() async throws {
        let fixture = try SegmentWorkspace()
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            mediaDirectoryURL: fixture.mediaDirectory
        )
        let legacyImage = fixture.directory.appendingPathComponent("legacy.jpg")
        let legacyBytes = try Self.jpeg(color: .green)
        try legacyBytes.write(to: legacyImage)
        _ = try await store.record(ScreenHistoryFrameInput(
            sourceIdentifier: "legacy-v7-image",
            capturedAt: Date(timeIntervalSince1970: 50),
            ocrText: "legacy schema seven image",
            imageLocator: legacyImage.path,
            byteCount: Int64(legacyBytes.count)
        ))

        let writer = try fixture.writer(maximumFrames: 2)
        let sink = ScreenHistorySegmentedCaptureSink(
            store: store,
            writer: writer,
            estimatedCadenceSeconds: 3
        )
        try await sink.receive(Self.frame(at: 100, fingerprint: 10, color: .red, text: "segment red"))
        try await sink.receive(Self.frame(at: 103, fingerprint: 11, color: .blue, text: "segment blue"))

        #expect(SQLiteScreenHistoryStore.schemaVersion == 7)
        let legacy = try #require(
            try await store.search(ScreenHistorySearchQuery(text: "legacy schema")).first
        )
        #expect(legacy.imageLocator == legacyImage.path)
        #expect(legacy.mediaLocator == nil)

        let rows = try await store.search(ScreenHistorySearchQuery(text: "segment"))
            .sorted { ($0.mediaFrameIndex ?? -1) < ($1.mediaFrameIndex ?? -1) }
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.imageLocator == nil })
        #expect(Set(rows.compactMap(\.mediaLocator)).count == 1)
        #expect(rows.map(\.mediaFrameIndex) == [0, 1])
        #expect(rows.map(\.mediaFrameCount) == [2, 2])
        let mediaURL = URL(fileURLWithPath: try #require(rows.first?.mediaLocator))
        let exactMediaBytes = try fixture.fileSize(mediaURL)
        #expect(rows.reduce(Int64(0)) { $0 + $1.byteCount } == exactMediaBytes)
        let firstPreview = try #require(await ScreenHistoryMediaPreviewService.image(for: rows[0]))
        let secondPreview = try #require(await ScreenHistoryMediaPreviewService.image(for: rows[1]))
        #expect(try Self.dominantColor(in: firstPreview) == .red)
        #expect(try Self.dominantColor(in: secondPreview) == .blue)

        let receipt = try #require(await sink.latestStorageRateReceipt())
        #expect(receipt.frameCount == 2)
        #expect(receipt.attributedMediaBytes == exactMediaBytes)
        #expect(receipt.from == Date(timeIntervalSince1970: 100))
        #expect(receipt.through == Date(timeIntervalSince1970: 106))
        #expect(receipt.bytesPerHour == Int64((Double(exactMediaBytes) * 600).rounded()))
    }

    @Test func sharedSegmentRetentionWaitsForLastFrameAndRemainsRetryable() async throws {
        let fixture = try SegmentWorkspace()
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            mediaDirectoryURL: fixture.mediaDirectory,
            ownedMediaRootURLs: [fixture.mediaDirectory]
        )
        let writer = try fixture.writer(maximumFrames: 2)
        let sink = ScreenHistorySegmentedCaptureSink(store: store, writer: writer)
        try await sink.receive(Self.frame(at: 100, fingerprint: 20, color: .red, text: "old segment"))
        try await sink.receive(Self.frame(at: 103, fingerprint: 21, color: .blue, text: "new segment"))
        let mediaPath = try #require(
            try await store.search(ScreenHistorySearchQuery()).first?.mediaLocator
        )

        let first = try await store.prune(
            policy: ScreenHistoryRetentionPolicy(retentionDays: 0),
            now: Date(timeIntervalSince1970: 101)
        )
        #expect(first.rowsRemoved == 1)
        #expect(first.filesRetainedShared == 1)
        #expect(FileManager.default.fileExists(atPath: mediaPath))

        let final = try await store.prune(
            policy: ScreenHistoryRetentionPolicy(retentionDays: 0),
            now: Date(timeIntervalSince1970: 200)
        )
        #expect(final.rowsRemoved == 1)
        #expect(final.filesRemoved == 1)
        #expect(final.retryRequired == false)
        #expect(!FileManager.default.fileExists(atPath: mediaPath))
    }

    @Test func invalidImageKeepsItsPrivateStageForRetryAndCreatesNoVideo() async throws {
        let fixture = try SegmentWorkspace()
        let writer = try fixture.writer(maximumFrames: 2)
        let invalid = CapturedScreenFrame(
            capturedAt: Date(timeIntervalSince1970: 100),
            bundleIdentifier: "test.quick-launch.segment",
            applicationName: "Segment Test",
            windowTitle: "Invalid",
            pixelWidth: 96,
            pixelHeight: 64,
            imageData: Data([1, 2, 3]),
            recognizedText: "invalid media remains staged",
            fingerprint: 30
        )!
        #expect(try await writer.append(invalid).isEmpty)

        var failed = false
        do {
            _ = try await writer.flush()
        } catch ScreenHistoryMediaSegmentWriterError.unreadableFrame {
            failed = true
        }
        #expect(failed)
        #expect(try fixture.stagingDirectories().count == 1)
        #expect(try fixture.segmentFiles().isEmpty)

        let reopened = try fixture.writer(maximumFrames: 2)
        failed = false
        do {
            _ = try await reopened.flush()
        } catch ScreenHistoryMediaSegmentWriterError.unreadableFrame {
            failed = true
        }
        #expect(failed)
        #expect(try fixture.stagingDirectories().count == 1)
    }

    private static func frame(
        at timestamp: TimeInterval,
        fingerprint: UInt64,
        color: SegmentColor,
        text: String
    ) throws -> CapturedScreenFrame {
        try #require(CapturedScreenFrame(
            capturedAt: Date(timeIntervalSince1970: timestamp),
            bundleIdentifier: "test.quick-launch.segment",
            applicationName: "Segment Test",
            windowTitle: text,
            pixelWidth: 96,
            pixelHeight: 64,
            imageData: jpeg(color: color),
            recognizedText: text,
            fingerprint: fingerprint
        ))
    }

    private static func jpeg(color: SegmentColor) throws -> Data {
        let width = 96
        let height = 64
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw SegmentTestError.unreadableImage }
        guard let bytes = bitmap.bitmapData else { throw SegmentTestError.unreadableImage }
        let rgba: (UInt8, UInt8, UInt8)
        switch color {
        case .red: rgba = (255, 0, 0)
        case .green: rgba = (0, 255, 0)
        case .blue: rgba = (0, 0, 255)
        }
        for y in 0..<height {
            let row = bytes.advanced(by: y * bitmap.bytesPerRow)
            for x in 0..<width {
                row[x * 4] = rgba.0
                row[x * 4 + 1] = rgba.1
                row[x * 4 + 2] = rgba.2
                row[x * 4 + 3] = 255
            }
        }
        return try #require(bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.9]
        ))
    }

    private static func previewFrame(
        segment: ScreenHistoryFinalizedMediaSegment,
        index: Int
    ) -> ScreenHistoryFrame {
        ScreenHistoryFrame(
            id: Int64(index + 1),
            source: .owned,
            sourceIdentifier: "preview-\(index)",
            capturedAt: segment.frames[index].capturedAt,
            application: "Segment Test",
            bundleIdentifier: "test.quick-launch.segment",
            domain: nil,
            windowTitle: "Preview",
            ocrText: "preview",
            imageLocator: nil,
            mediaLocator: segment.mediaURL.path,
            mediaFrameIndex: index,
            mediaFrameCount: segment.frames.count,
            byteCount: segment.byteCount,
            sequenceIdentifier: segment.stagingIdentifier,
            sequenceOrdinal: index,
            contentHash: "preview-\(index)"
        )
    }

    private static func dominantColor(in image: NSImage) throws -> SegmentColor {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        else { throw SegmentTestError.unreadableImage }
        if color.redComponent > color.blueComponent * 1.5 { return .red }
        if color.blueComponent > color.redComponent * 1.5 { return .blue }
        throw SegmentTestError.ambiguousColor
    }
}

private enum SegmentColor: Equatable { case red, green, blue }
private enum SegmentTestError: Error { case unreadableImage, ambiguousColor }

private final class SegmentWorkspace: @unchecked Sendable {
    let directory: URL
    let databaseURL: URL
    let mediaDirectory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-segments-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directory.appendingPathComponent("screen-history.sqlite3")
        mediaDirectory = directory.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func writer(maximumFrames: Int) throws -> AVFoundationScreenHistoryMediaSegmentWriter {
        try AVFoundationScreenHistoryMediaSegmentWriter(
            mediaRootURL: mediaDirectory,
            configuration: ScreenHistoryMediaSegmentConfiguration(
                maximumFrames: maximumFrames,
                maximumDurationSeconds: 60
            )
        )
    }

    func fileSize(_ url: URL) throws -> Int64 {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return try #require(value).int64Value
    }

    func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return try #require(value).intValue
    }

    func stagingDirectories() throws -> [URL] {
        let root = mediaDirectory.appendingPathComponent(".segment-staging", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    func segmentFiles() throws -> [URL] {
        let root = mediaDirectory.appendingPathComponent("Segments", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }
}
