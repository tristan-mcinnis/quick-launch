import CoreGraphics
import Foundation

enum ScreenHistoryReleasePolicy {
    /// The first installed release is search-only. Capture code stays present
    /// for its test and soak path, but no production control can start it.
    static let allowsOwnedCapture = false
}

/// A bounded screen-history record ready for a local storage sink.
/// The capture engine never persists or transmits this value itself.
struct CapturedScreenFrame: Equatable, Sendable {
    static let maximumImageBytes = 2 * 1_024 * 1_024
    static let maximumOCRCharacters = 12_000
    static let maximumApplicationNameCharacters = 120
    static let maximumWindowTitleCharacters = 300

    let capturedAt: Date
    let bundleIdentifier: String
    let applicationName: String
    let windowTitle: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let imageData: Data
    let recognizedText: String
    let recognizedBoxes: [ScreenHistoryOCRBox]
    let fingerprint: UInt64

    init?(
        capturedAt: Date,
        bundleIdentifier: String,
        applicationName: String,
        windowTitle: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        imageData: Data,
        recognizedText: String,
        recognizedBoxes: [ScreenHistoryOCRBox] = [],
        fingerprint: UInt64
    ) {
        let bundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleIdentifier.isEmpty,
              pixelWidth > 0,
              pixelHeight > 0,
              !imageData.isEmpty,
              imageData.count <= Self.maximumImageBytes
        else { return nil }

        self.capturedAt = capturedAt
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = String(applicationName.prefix(Self.maximumApplicationNameCharacters))
        self.windowTitle = windowTitle.map { String($0.prefix(Self.maximumWindowTitleCharacters)) }
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.imageData = imageData
        self.recognizedText = String(recognizedText.prefix(Self.maximumOCRCharacters))
        self.recognizedBoxes = Array(recognizedBoxes.prefix(1_000))
        self.fingerprint = fingerprint
    }
}

/// Identity checked before ScreenCaptureKit is allowed to read any pixels.
struct ScreenHistoryCaptureTarget: Equatable, Sendable {
    /// The exact front-window identity selected before privacy inspection.
    /// ScreenCaptureKit must capture this same window, never another window
    /// found later by process identifier or front-to-back order.
    let windowIdentifier: CGWindowID
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    /// Read from window metadata before any pixels are requested.
    let windowTitle: String?
    /// Read through Accessibility before any pixels are requested. The full
    /// URL is used only for the privacy decision and is never persisted.
    let pageURL: URL?
    /// Normalized host derived from `pageURL` before capture.
    let domain: String?
    /// Focused web-area title used only for the privacy decision.
    let pageTitle: String?
    /// True when the application manifest declares that it handles HTTP or
    /// HTTPS URLs. This is resolved before any screen pixels are requested.
    let declaresWebURLHandling: Bool

    init(
        windowIdentifier: CGWindowID,
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        windowTitle: String? = nil,
        pageURL: URL? = nil,
        domain: String? = nil,
        pageTitle: String? = nil,
        declaresWebURLHandling: Bool = false
    ) {
        self.windowIdentifier = windowIdentifier
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.windowTitle = windowTitle
        self.pageURL = pageURL
        self.domain = domain
        self.pageTitle = pageTitle
        self.declaresWebURLHandling = declaresWebURLHandling
    }
}

/// Unbounded pixels returned by the capture adapter. The engine validates and
/// bounds them before a sink can see them.
struct ScreenHistoryRawFrame: Equatable, Sendable {
    let capturedAt: Date
    let windowTitle: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let imageData: Data
}

protocol ScreenHistoryFrameSourcing: Sendable {
    func screenRecordingIsAuthorized() async -> Bool
    func requestScreenRecordingAuthorization() async -> Bool
    func frontmostWindowTarget() async -> ScreenHistoryCaptureTarget?
    func captureWindow(for target: ScreenHistoryCaptureTarget) async throws -> ScreenHistoryRawFrame?
}

extension ScreenHistoryFrameSourcing {
    func screenRecordingIsAuthorized() async -> Bool { true }
    func requestScreenRecordingAuthorization() async -> Bool {
        await screenRecordingIsAuthorized()
    }
}

protocol ScreenHistoryActivityReading: Sendable {
    func secondsSinceLastInput() async -> TimeInterval
}

protocol ScreenHistoryTextRecognizing: Sendable {
    func recognizeText(in imageData: Data) async -> String
    func recognize(
        in imageData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) async -> ScreenHistoryTextRecognition
}

struct ScreenHistoryTextRecognition: Equatable, Sendable {
    let text: String
    let boxes: [ScreenHistoryOCRBox]
}

extension ScreenHistoryTextRecognizing {
    func recognize(
        in imageData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) async -> ScreenHistoryTextRecognition {
        ScreenHistoryTextRecognition(
            text: await recognizeText(in: imageData),
            boxes: []
        )
    }
}

protocol ScreenHistoryFrameSink: Sendable {
    func receive(_ frame: CapturedScreenFrame) async throws
    /// Finalizes any bounded staged media before a normal capture stop. A sink
    /// must keep staged data recoverable when this call fails or is interrupted.
    func flush() async throws
}

extension ScreenHistoryFrameSink {
    func flush() async throws {}
}

struct ScreenHistoryFinalizedMediaSegment: Sendable {
    let stagingIdentifier: String
    let mediaURL: URL
    let frames: [CapturedScreenFrame]
    let byteCount: Int64
}

protocol ScreenHistoryMediaSegmentWriting: Sendable {
    /// Accepts one frame and returns every segment that is ready for a database
    /// commit. A returned segment remains recoverable until `commit` succeeds.
    func append(_ frame: CapturedScreenFrame) async throws -> [ScreenHistoryFinalizedMediaSegment]
    func flush() async throws -> [ScreenHistoryFinalizedMediaSegment]
    func commit(_ segment: ScreenHistoryFinalizedMediaSegment) async throws
}
