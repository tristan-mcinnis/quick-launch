import AppKit
import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screen history media preview", .serialized)
struct ScreenHistoryMediaPreviewServiceTests {
    @Test func mediaFrameIndexLoadsAndMaterializesTheExactVariableRateFrame() async throws {
        let fixture = try await SyntheticVariableRateVideo()
        defer { fixture.remove() }
        let expected: [DominantColor] = [.red, .green, .blue, .yellow]

        for (index, color) in expected.enumerated() {
            let frame = ScreenHistoryFrame(
                id: Int64(index + 1),
                source: .coast,
                sourceIdentifier: "variable-rate-\(index)",
                capturedAt: Date(timeIntervalSince1970: Double(index)),
                application: "Synthetic Preview",
                bundleIdentifier: "test.quick-launch.preview",
                domain: nil,
                windowTitle: "Frame \(index)",
                ocrText: "frame \(index)",
                imageLocator: nil,
                mediaLocator: fixture.videoURL.path,
                mediaFrameIndex: index,
                mediaFrameCount: expected.count,
                byteCount: 1,
                sequenceIdentifier: "variable-rate",
                sequenceOrdinal: index,
                contentHash: "variable-rate-frame-\(index)"
            )

            let image = try #require(await ScreenHistoryMediaPreviewService.image(for: frame))
            #expect(try Self.dominantColor(in: image) == color)

            let materialized = try #require(
                await ScreenHistoryMediaPreviewService.materializedMomentURL(
                    for: frame,
                    directory: fixture.previewDirectory
                )
            )
            let materializedImage = try #require(NSImage(contentsOf: materialized))
            #expect(try Self.dominantColor(in: materializedImage) == color)
        }
    }

    @Test func ocrBoxesFitGlobalDisplayCoordinatesAcrossDisplayOriginsAndSizes() {
        let cases: [(ScreenHistoryDisplayGeometry, ScreenHistoryOCRBox, CGSize, CGRect)] = [
            (
                ScreenHistoryDisplayGeometry(x: -1_728, y: 0, width: 1_728, height: 1_116),
                ScreenHistoryOCRBox(
                    ordinal: 0,
                    text: "left display",
                    x: -1_555.2,
                    y: 111.6,
                    width: 345.6,
                    height: 223.2
                ),
                CGSize(width: 600, height: 400),
                CGRect(x: 60, y: 45, width: 120, height: 77.5)
            ),
            (
                ScreenHistoryDisplayGeometry(x: 2_560, y: -900, width: 1_440, height: 900),
                ScreenHistoryOCRBox(
                    ordinal: 0,
                    text: "upper right display",
                    x: 3_280,
                    y: -450,
                    width: 360,
                    height: 225
                ),
                CGSize(width: 320, height: 240),
                CGRect(x: 160, y: 120, width: 80, height: 50)
            ),
        ]

        for (display, box, container, expected) in cases {
            let actual = ScreenHistoryOCRBoxLayout.rect(
                for: box,
                imageSize: CGSize(width: display.width, height: display.height),
                displayGeometry: display,
                containerSize: container
            )
            #expect(abs(actual.minX - expected.minX) < 0.1)
            #expect(abs(actual.minY - expected.minY) < 0.1)
            #expect(abs(actual.width - expected.width) < 0.1)
            #expect(abs(actual.height - expected.height) < 0.1)
        }
    }

    private static func dominantColor(in image: NSImage) throws -> DominantColor {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        else { throw PreviewTestError.unreadableImage }
        let red = color.redComponent
        let green = color.greenComponent
        let blue = color.blueComponent
        if red > 0.65, green > 0.65, blue < 0.35 { return .yellow }
        if red > green * 1.5, red > blue * 1.5 { return .red }
        if green > red * 1.5, green > blue * 1.5 { return .green }
        if blue > red * 1.5, blue > green * 1.5 { return .blue }
        throw PreviewTestError.ambiguousColor(red, green, blue)
    }
}

private enum DominantColor: Equatable {
    case red
    case green
    case blue
    case yellow
}

private enum PreviewTestError: Error {
    case unreadableImage
    case ambiguousColor(CGFloat, CGFloat, CGFloat)
    case videoWriter(String)
}

private final class SyntheticVariableRateVideo: @unchecked Sendable {
    let directory: URL
    let videoURL: URL
    let previewDirectory: URL

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-variable-video-\(UUID().uuidString)")
        videoURL = directory.appendingPathComponent("moments.mov")
        previewDirectory = directory.appendingPathComponent("previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Self.writeVideo(to: videoURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 48,
                AVVideoHeightKey: 48,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 48,
                kCVPixelBufferHeightKey as String: 48,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        guard writer.canAdd(input) else { throw PreviewTestError.videoWriter("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw PreviewTestError.videoWriter(writer.error?.localizedDescription ?? "start failed")
        }
        writer.startSession(atSourceTime: .zero)

        let frames: [(Double, (UInt8, UInt8, UInt8))] = [
            (0, (255, 0, 0)),
            (0.1, (0, 255, 0)),
            (0.2, (0, 0, 255)),
            (5, (255, 255, 0)),
        ]
        for (seconds, rgb) in frames {
            let readyDeadline = ContinuousClock.now + .seconds(15)
            while !input.isReadyForMoreMediaData, ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.isReadyForMoreMediaData,
                  let pool = adaptor.pixelBufferPool,
                  let buffer = makePixelBuffer(
                    in: pool,
                    red: rgb.0,
                    green: rgb.1,
                    blue: rgb.2
                  ),
                  adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
            else { throw PreviewTestError.videoWriter(writer.error?.localizedDescription ?? "append failed") }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 6, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw PreviewTestError.videoWriter(writer.error?.localizedDescription ?? "finish failed")
        }
    }

    private static func makePixelBuffer(
        in pool: CVPixelBufferPool,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<48 {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<48 {
                row[x * 4] = blue
                row[x * 4 + 1] = green
                row[x * 4 + 2] = red
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }
}
