import AppKit
import AVFoundation
import CryptoKit
import Foundation

enum ScreenHistoryMediaPreviewService {
    static func image(for frame: ScreenHistoryFrame) async -> NSImage? {
        if let locator = frame.imageLocator {
            return await MainActor.run {
                ScreenshotThumbnailCache.thumbnail(forPath: locator)
            }
        }
        guard let locator = frame.mediaLocator else { return nil }
        return await videoFrame(
            at: URL(fileURLWithPath: locator),
            frameIndex: frame.mediaFrameIndex ?? 0,
            frameCount: frame.mediaFrameCount
        )
    }

    static func materializedMomentURL(
        for frame: ScreenHistoryFrame,
        directory requestedDirectory: URL? = nil
    ) async -> URL? {
        if let locator = frame.imageLocator { return URL(fileURLWithPath: locator) }
        guard let image = await image(for: frame),
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let jpeg = representation.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.9]
              ) else { return nil }

        let directory = requestedDirectory ?? SQLiteScreenHistoryStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("Screen History Moment Previews", isDirectory: true)
        let filename = SHA256.hash(data: Data(
            "\(frame.source.rawValue):\(frame.sourceIdentifier):\(frame.contentHash)".utf8
        )).map { String(format: "%02x", $0) }.joined() + ".jpg"
        let destination = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try jpeg.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try pruneDerivedPreviews(in: directory, keeping: 100)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }

    private static func videoFrame(
        at url: URL,
        frameIndex: Int,
        frameCount: Int?
    ) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let requestedIndex = frameCount.map {
                min(max(0, frameIndex), max(0, $0 - 1))
            } ?? max(0, frameIndex)
            guard let time = try exactSampleTime(
                at: requestedIndex,
                asset: asset,
                track: track
            ) else { return nil }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let generated = try await generator.image(at: time)
            return NSImage(
                cgImage: generated.image,
                size: NSSize(width: generated.image.width, height: generated.image.height)
            )
        } catch {
            return nil
        }
    }

    /// `mediaFrameIndex` is a decoded-sample ordinal, not a position in the
    /// asset duration. Looking up its real timestamp keeps variable-rate and
    /// unevenly spaced video exact.
    private static func exactSampleTime(
        at requestedIndex: Int,
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> CMTime? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var index = 0
        var lastTime: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard time.isValid else { continue }
            lastTime = time
            if index == requestedIndex { return time }
            index += 1
        }
        if reader.status == .failed {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        return lastTime
    }

    private static func pruneDerivedPreviews(in directory: URL, keeping limit: Int) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted {
                let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        for file in files.dropFirst(max(1, limit)) where !isSymbolicLink(file) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
