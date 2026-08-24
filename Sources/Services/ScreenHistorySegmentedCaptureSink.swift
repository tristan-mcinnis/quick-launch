import Foundation

/// Opt-in capture sink for the compacted-media path. It is separate from the
/// legacy JPEG sink so activation and rollback are one wiring change. Existing
/// schema-v7 rows need no migration because video locator, frame index, frame
/// count, sequence, and attributed byte columns already exist.
actor ScreenHistorySegmentedCaptureSink: ScreenHistoryFrameSink {
    private let store: any ScreenHistoryStoring
    private let writer: any ScreenHistoryMediaSegmentWriting
    private let estimatedCadenceSeconds: TimeInterval
    private var latestReceipt: ScreenHistoryStorageRateReceipt?

    init(
        store: any ScreenHistoryStoring,
        writer: any ScreenHistoryMediaSegmentWriting,
        estimatedCadenceSeconds: TimeInterval = 3
    ) {
        self.store = store
        self.writer = writer
        self.estimatedCadenceSeconds = max(0.001, estimatedCadenceSeconds)
    }

    func receive(_ frame: CapturedScreenFrame) async throws {
        try await persist(try await writer.append(frame))
    }

    func flush() async throws {
        try await persist(try await writer.flush())
    }

    func latestStorageRateReceipt() -> ScreenHistoryStorageRateReceipt? {
        latestReceipt
    }

    private func persist(_ segments: [ScreenHistoryFinalizedMediaSegment]) async throws {
        for segment in segments {
            guard !segment.frames.isEmpty, segment.byteCount > 0 else { continue }
            let frameCount = segment.frames.count
            let baseBytes = segment.byteCount / Int64(frameCount)
            let remainder = Int(segment.byteCount % Int64(frameCount))
            let inputs = segment.frames.enumerated().map { index, frame in
                ScreenHistoryFrameInput(
                    sourceIdentifier: Self.sourceIdentifier(for: frame),
                    capturedAt: frame.capturedAt,
                    application: frame.applicationName,
                    bundleIdentifier: frame.bundleIdentifier,
                    windowTitle: frame.windowTitle,
                    ocrText: frame.recognizedText,
                    mediaLocator: segment.mediaURL.path,
                    mediaFrameIndex: index,
                    mediaFrameCount: frameCount,
                    ocrBoxes: frame.recognizedBoxes,
                    byteCount: baseBytes + (index < remainder ? 1 : 0),
                    sequenceIdentifier: segment.stagingIdentifier,
                    sequenceOrdinal: index
                )
            }

            // SQLite commits first. If stage cleanup then fails, recovery
            // replays the same stable source identifiers and converges.
            _ = try await store.record(inputs)
            try await writer.commit(segment)

            let earliest = segment.frames.map(\.capturedAt).min()!
            let latest = segment.frames.map(\.capturedAt).max()!
            latestReceipt = ScreenHistoryStorageRateReceipt(
                from: earliest,
                through: latest.addingTimeInterval(estimatedCadenceSeconds),
                frameCount: frameCount,
                attributedMediaBytes: segment.byteCount
            )
        }
    }

    private static func sourceIdentifier(for frame: CapturedScreenFrame) -> String {
        let milliseconds = Int64(frame.capturedAt.timeIntervalSince1970 * 1_000)
        return "\(milliseconds)-\(String(frame.fingerprint, radix: 16))"
    }
}
