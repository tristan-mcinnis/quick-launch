import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

enum ScreenHistoryMediaSegmentWriterError: Error, Equatable {
    case invalidConfiguration
    case unsafePath(String)
    case corruptManifest(String)
    case unreadableFrame(String)
    case videoWriter(String)
}

struct ScreenHistoryMediaSegmentConfiguration: Equatable, Sendable {
    /// At the default three-second capture cadence this bounds staging to about
    /// one minute and at most 40 MiB of accepted JPEG input.
    var maximumFrames = 20
    var maximumDurationSeconds: TimeInterval = 60

    init(maximumFrames: Int = 20, maximumDurationSeconds: TimeInterval = 60) {
        self.maximumFrames = maximumFrames
        self.maximumDurationSeconds = maximumDurationSeconds
    }
}

/// Converts bounded JPEG captures into small H.264 segments. Every accepted
/// frame is first written to a private stage with an atomic manifest. The stage
/// is removed only after the caller commits the segment's database rows, which
/// makes both encoder failure and interruption between media and SQLite retryable.
actor AVFoundationScreenHistoryMediaSegmentWriter: ScreenHistoryMediaSegmentWriting {
    private struct Manifest: Codable, Sendable {
        let identifier: String
        let createdAt: Date
        let pixelWidth: Int
        let pixelHeight: Int
        var frames: [StagedFrame]
    }

    private struct StagedFrame: Codable, Sendable {
        let filename: String
        let capturedAt: Date
        let bundleIdentifier: String
        let applicationName: String
        let windowTitle: String?
        let pixelWidth: Int
        let pixelHeight: Int
        let recognizedText: String
        let recognizedBoxes: [ScreenHistoryOCRBox]
        let fingerprint: UInt64

        init(frame: CapturedScreenFrame, filename: String) {
            self.filename = filename
            capturedAt = frame.capturedAt
            bundleIdentifier = frame.bundleIdentifier
            applicationName = frame.applicationName
            windowTitle = frame.windowTitle
            pixelWidth = frame.pixelWidth
            pixelHeight = frame.pixelHeight
            recognizedText = frame.recognizedText
            recognizedBoxes = frame.recognizedBoxes
            fingerprint = frame.fingerprint
        }

        func materialize(in stageURL: URL) throws -> CapturedScreenFrame {
            let imageURL = stageURL.appendingPathComponent(filename)
            guard !Self.isSymbolicLink(imageURL),
                  let data = try? Data(contentsOf: imageURL),
                  let frame = CapturedScreenFrame(
                      capturedAt: capturedAt,
                      bundleIdentifier: bundleIdentifier,
                      applicationName: applicationName,
                      windowTitle: windowTitle,
                      pixelWidth: pixelWidth,
                      pixelHeight: pixelHeight,
                      imageData: data,
                      recognizedText: recognizedText,
                      recognizedBoxes: recognizedBoxes,
                      fingerprint: fingerprint
                  )
            else { throw ScreenHistoryMediaSegmentWriterError.unreadableFrame(filename) }
            return frame
        }

        private static func isSymbolicLink(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        }
    }

    private let mediaRootURL: URL
    private let stagingRootURL: URL
    private let segmentsRootURL: URL
    private let configuration: ScreenHistoryMediaSegmentConfiguration
    private var activeManifest: Manifest?

    init(
        mediaRootURL: URL,
        configuration: ScreenHistoryMediaSegmentConfiguration = .init()
    ) throws {
        guard configuration.maximumFrames > 0,
              configuration.maximumDurationSeconds > 0
        else { throw ScreenHistoryMediaSegmentWriterError.invalidConfiguration }
        self.mediaRootURL = mediaRootURL.standardizedFileURL
        stagingRootURL = self.mediaRootURL.appendingPathComponent(".segment-staging", isDirectory: true)
        segmentsRootURL = self.mediaRootURL.appendingPathComponent("Segments", isDirectory: true)
        self.configuration = configuration
    }

    func append(_ frame: CapturedScreenFrame) async throws -> [ScreenHistoryFinalizedMediaSegment] {
        try prepareDirectories()
        var finalized = try await recoverPendingStages(excluding: activeManifest?.identifier)

        if let activeManifest, shouldRotate(activeManifest, before: frame) {
            finalized.append(try await finalize(activeManifest))
            self.activeManifest = nil
        }

        if finalized.contains(where: { segment in
            segment.frames.contains { Self.sameIdentity($0, frame) }
        }) {
            return finalized
        }

        var manifest = try activeManifest ?? makeStage(for: frame)
        if manifest.frames.contains(where: {
            $0.capturedAt == frame.capturedAt && $0.fingerprint == frame.fingerprint
        }) {
            return finalized
        }

        let stageURL = stageURL(for: manifest.identifier)
        let filename = String(format: "%06d.jpg", manifest.frames.count)
        let imageURL = stageURL.appendingPathComponent(filename)
        guard !isSymbolicLink(imageURL) else {
            throw ScreenHistoryMediaSegmentWriterError.unsafePath(imageURL.path)
        }
        try frame.imageData.write(to: imageURL, options: .atomic)
        try setOwnerOnlyFile(imageURL)
        manifest.frames.append(StagedFrame(frame: frame, filename: filename))
        try writeManifest(manifest)
        activeManifest = manifest

        if manifest.frames.count >= configuration.maximumFrames {
            finalized.append(try await finalize(manifest))
            activeManifest = nil
        }
        return finalized
    }

    func flush() async throws -> [ScreenHistoryFinalizedMediaSegment] {
        try prepareDirectories()
        var finalized = try await recoverPendingStages(excluding: activeManifest?.identifier)
        if let activeManifest, !activeManifest.frames.isEmpty {
            finalized.append(try await finalize(activeManifest))
            self.activeManifest = nil
        }
        return finalized
    }

    func commit(_ segment: ScreenHistoryFinalizedMediaSegment) async throws {
        let stageURL = stageURL(for: segment.stagingIdentifier)
        guard stageURL.deletingLastPathComponent().standardizedFileURL == stagingRootURL,
              !isSymbolicLink(stageURL)
        else { throw ScreenHistoryMediaSegmentWriterError.unsafePath(stageURL.path) }
        guard FileManager.default.fileExists(atPath: stageURL.path) else { return }
        try FileManager.default.removeItem(at: stageURL)
    }

    private func makeStage(for frame: CapturedScreenFrame) throws -> Manifest {
        let identifier = UUID().uuidString.lowercased()
        let url = stageURL(for: identifier)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw ScreenHistoryMediaSegmentWriterError.unsafePath(url.path)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try setOwnerOnlyDirectory(url)
        let manifest = Manifest(
            identifier: identifier,
            createdAt: frame.capturedAt,
            pixelWidth: frame.pixelWidth,
            pixelHeight: frame.pixelHeight,
            frames: []
        )
        try writeManifest(manifest)
        return manifest
    }

    private func shouldRotate(_ manifest: Manifest, before frame: CapturedScreenFrame) -> Bool {
        manifest.frames.count >= configuration.maximumFrames
            || manifest.pixelWidth != frame.pixelWidth
            || manifest.pixelHeight != frame.pixelHeight
            || frame.capturedAt.timeIntervalSince(manifest.createdAt) >= configuration.maximumDurationSeconds
    }

    private func recoverPendingStages(
        excluding activeIdentifier: String?
    ) async throws -> [ScreenHistoryFinalizedMediaSegment] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: stagingRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var recovered: [ScreenHistoryFinalizedMediaSegment] = []
        for url in urls where url.lastPathComponent != activeIdentifier {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ScreenHistoryMediaSegmentWriterError.unsafePath(url.path)
            }
            let manifestURL = url.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else {
                // The only pre-manifest state is an unacknowledged empty stage.
                // Remove it rather than allowing unbounded crash debris.
                try FileManager.default.removeItem(at: url)
                continue
            }
            let manifest = try readManifest(at: manifestURL)
            guard manifest.identifier == url.lastPathComponent,
                  !manifest.frames.isEmpty
            else {
                throw ScreenHistoryMediaSegmentWriterError.corruptManifest(url.lastPathComponent)
            }
            recovered.append(try await finalize(manifest))
        }
        return recovered
    }

    private func finalize(_ manifest: Manifest) async throws -> ScreenHistoryFinalizedMediaSegment {
        let stageURL = stageURL(for: manifest.identifier)
        guard !isSymbolicLink(stageURL), !manifest.frames.isEmpty else {
            throw ScreenHistoryMediaSegmentWriterError.unsafePath(stageURL.path)
        }
        let frames = try manifest.frames.map { try $0.materialize(in: stageURL) }
        let destination = segmentsRootURL.appendingPathComponent("\(manifest.identifier).mp4")
        guard !isSymbolicLink(destination) else {
            throw ScreenHistoryMediaSegmentWriterError.unsafePath(destination.path)
        }

        if !FileManager.default.fileExists(atPath: destination.path) {
            let partial = stageURL.appendingPathComponent("encoded.partial.mp4")
            if FileManager.default.fileExists(atPath: partial.path) {
                guard !isSymbolicLink(partial) else {
                    throw ScreenHistoryMediaSegmentWriterError.unsafePath(partial.path)
                }
                try FileManager.default.removeItem(at: partial)
            }
            try await encode(frames: frames, to: partial)
            try setOwnerOnlyFile(partial)
            try FileManager.default.moveItem(at: partial, to: destination)
            try setOwnerOnlyFile(destination)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0
        else { throw ScreenHistoryMediaSegmentWriterError.videoWriter("empty finalized segment") }
        return ScreenHistoryFinalizedMediaSegment(
            stagingIdentifier: manifest.identifier,
            mediaURL: destination,
            frames: frames,
            byteCount: size.int64Value
        )
    }

    private func encode(frames: [CapturedScreenFrame], to url: URL) async throws {
        let width = max(2, frames[0].pixelWidth + frames[0].pixelWidth % 2)
        let height = max(2, frames[0].pixelHeight + frames[0].pixelHeight % 2)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 750_000,
                    AVVideoExpectedSourceFrameRateKey: 1,
                    AVVideoMaxKeyFrameIntervalKey: configuration.maximumFrames,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw ScreenHistoryMediaSegmentWriterError.videoWriter("cannot add video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw ScreenHistoryMediaSegmentWriterError.videoWriter(
                writer.error?.localizedDescription ?? "cannot start video writer"
            )
        }
        writer.startSession(atSourceTime: .zero)

        do {
            for (index, frame) in frames.enumerated() {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else {
                        throw ScreenHistoryMediaSegmentWriterError.videoWriter(
                            writer.error?.localizedDescription ?? "video writer stopped"
                        )
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard let buffer = try pixelBuffer(
                    imageData: frame.imageData,
                    width: width,
                    height: height
                ), adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 1)
                ) else {
                    throw ScreenHistoryMediaSegmentWriterError.videoWriter(
                        writer.error?.localizedDescription ?? "cannot append video frame"
                    )
                }
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames.count), timescale: 1))
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw ScreenHistoryMediaSegmentWriterError.videoWriter(
                    writer.error?.localizedDescription ?? "cannot finish video writer"
                )
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    private func pixelBuffer(imageData: Data, width: Int, height: Int) throws -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ScreenHistoryMediaSegmentWriterError.unreadableFrame("invalid JPEG data") }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw ScreenHistoryMediaSegmentWriterError.videoWriter("cannot allocate pixel buffer")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw ScreenHistoryMediaSegmentWriterError.videoWriter("pixel buffer has no storage")
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else { throw ScreenHistoryMediaSegmentWriterError.videoWriter("cannot create bitmap context") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func prepareDirectories() throws {
        try ensurePrivateDirectory(mediaRootURL)
        try ensurePrivateDirectory(stagingRootURL)
        try ensurePrivateDirectory(segmentsRootURL)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            guard !isSymbolicLink(url),
                  try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            else { throw ScreenHistoryMediaSegmentWriterError.unsafePath(url.path) }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try setOwnerOnlyDirectory(url)
    }

    private func writeManifest(_ manifest: Manifest) throws {
        let stageURL = stageURL(for: manifest.identifier)
        let url = stageURL.appendingPathComponent("manifest.json")
        guard !isSymbolicLink(url) else {
            throw ScreenHistoryMediaSegmentWriterError.unsafePath(url.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
        try setOwnerOnlyFile(url)
    }

    private func readManifest(at url: URL) throws -> Manifest {
        guard !isSymbolicLink(url) else {
            throw ScreenHistoryMediaSegmentWriterError.unsafePath(url.path)
        }
        do {
            return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        } catch {
            throw ScreenHistoryMediaSegmentWriterError.corruptManifest(url.deletingLastPathComponent().lastPathComponent)
        }
    }

    private func stageURL(for identifier: String) -> URL {
        stagingRootURL.appendingPathComponent(identifier, isDirectory: true).standardizedFileURL
    }

    private func setOwnerOnlyDirectory(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func setOwnerOnlyFile(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func sameIdentity(_ lhs: CapturedScreenFrame, _ rhs: CapturedScreenFrame) -> Bool {
        lhs.capturedAt == rhs.capturedAt && lhs.fingerprint == rhs.fingerprint
    }
}
