import Foundation
import CryptoKit

enum ScreenHistorySource: String, Sendable, Codable {
    case owned
    case coast
}

struct ScreenHistoryDisplayGeometry: Equatable, Sendable, Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var stableIdentifier: String {
        [x, y, width, height].map { String(format: "%.3f", $0) }.joined(separator: ":")
    }
}

struct ScreenHistoryOCRBox: Equatable, Sendable, Codable, Identifiable {
    let ordinal: Int
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var id: Int { ordinal }
}

struct ScreenHistoryFrameInput: Equatable, Sendable {
    let source: ScreenHistorySource
    let sourceIdentifier: String
    let capturedAt: Date
    let application: String?
    let bundleIdentifier: String?
    let domain: String?
    let windowTitle: String?
    let ocrText: String
    let imageLocator: String?
    let mediaLocator: String?
    let mediaFrameIndex: Int?
    let mediaFrameCount: Int?
    let displayGeometry: ScreenHistoryDisplayGeometry?
    let ocrBoxes: [ScreenHistoryOCRBox]
    let byteCount: Int64
    let sequenceIdentifier: String?
    let sequenceOrdinal: Int?
    let contentHash: String

    init(
        source: ScreenHistorySource = .owned,
        sourceIdentifier: String,
        capturedAt: Date,
        application: String? = nil,
        bundleIdentifier: String? = nil,
        domain: String? = nil,
        windowTitle: String? = nil,
        ocrText: String = "",
        imageLocator: String? = nil,
        mediaLocator: String? = nil,
        mediaFrameIndex: Int? = nil,
        mediaFrameCount: Int? = nil,
        displayGeometry: ScreenHistoryDisplayGeometry? = nil,
        ocrBoxes: [ScreenHistoryOCRBox] = [],
        byteCount: Int64 = 0,
        sequenceIdentifier: String? = nil,
        sequenceOrdinal: Int? = nil,
        contentHash: String? = nil
    ) {
        self.source = source
        self.sourceIdentifier = sourceIdentifier
        self.capturedAt = capturedAt
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
        self.windowTitle = windowTitle
        self.ocrText = ocrText
        self.imageLocator = imageLocator
        self.mediaLocator = mediaLocator
        self.mediaFrameIndex = mediaFrameIndex
        self.mediaFrameCount = mediaFrameCount.map { max(1, $0) }
        self.displayGeometry = displayGeometry
        self.ocrBoxes = Array(ocrBoxes.prefix(1_000))
        self.byteCount = max(0, byteCount)
        self.sequenceIdentifier = sequenceIdentifier
        self.sequenceOrdinal = sequenceOrdinal.map { max(0, $0) }
        self.contentHash = contentHash ?? Self.makeContentHash(
            source: source,
            sourceIdentifier: sourceIdentifier,
            capturedAt: capturedAt,
            application: application,
            bundleIdentifier: bundleIdentifier,
            domain: domain,
            windowTitle: windowTitle,
            ocrText: ocrText,
            imageLocator: imageLocator,
            mediaLocator: mediaLocator,
            mediaFrameIndex: mediaFrameIndex,
            mediaFrameCount: mediaFrameCount,
            displayGeometry: displayGeometry,
            ocrBoxes: Array(ocrBoxes.prefix(1_000)),
            byteCount: max(0, byteCount),
            sequenceIdentifier: sequenceIdentifier,
            sequenceOrdinal: sequenceOrdinal.map { max(0, $0) }
        )
    }

    /// Hashes length-prefixed UTF-8 fields so equal content has one stable
    /// identity without delimiter ambiguity. The hash is local metadata only.
    private static func makeContentHash(
        source: ScreenHistorySource,
        sourceIdentifier: String,
        capturedAt: Date,
        application: String?,
        bundleIdentifier: String?,
        domain: String?,
        windowTitle: String?,
        ocrText: String,
        imageLocator: String?,
        mediaLocator: String?,
        mediaFrameIndex: Int?,
        mediaFrameCount: Int?,
        displayGeometry: ScreenHistoryDisplayGeometry?,
        ocrBoxes: [ScreenHistoryOCRBox],
        byteCount: Int64,
        sequenceIdentifier: String?,
        sequenceOrdinal: Int?
    ) -> String {
        var fields: [String] = []
        fields.reserveCapacity(19 + ocrBoxes.count * 6)
        fields.append(source.rawValue)
        fields.append(sourceIdentifier)
        fields.append(String(capturedAt.timeIntervalSince1970.bitPattern))
        fields.append(application ?? "")
        fields.append(bundleIdentifier ?? "")
        fields.append(domain ?? "")
        fields.append(windowTitle ?? "")
        fields.append(ocrText)
        fields.append(imageLocator ?? "")
        fields.append(mediaLocator ?? "")
        fields.append(mediaFrameIndex.map { String($0) } ?? "")
        fields.append(mediaFrameCount.map { String($0) } ?? "")
        fields.append(displayGeometry?.stableIdentifier ?? "")
        for box in ocrBoxes {
            fields.append(String(box.ordinal))
            fields.append(box.text)
            fields.append(String(box.x))
            fields.append(String(box.y))
            fields.append(String(box.width))
            fields.append(String(box.height))
        }
        fields.append(String(byteCount))
        fields.append(sequenceIdentifier ?? "")
        fields.append(sequenceOrdinal.map { String($0) } ?? "")
        var canonical = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { canonical.append(contentsOf: $0) }
            canonical.append(bytes)
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}

struct ScreenHistoryFrame: Equatable, Sendable {
    let id: Int64
    let source: ScreenHistorySource
    let sourceIdentifier: String
    let capturedAt: Date
    let application: String?
    let bundleIdentifier: String?
    let domain: String?
    let windowTitle: String?
    let ocrText: String
    let imageLocator: String?
    let mediaLocator: String?
    let mediaFrameIndex: Int?
    let mediaFrameCount: Int?
    let displayGeometry: ScreenHistoryDisplayGeometry?
    let byteCount: Int64
    let sequenceIdentifier: String?
    let sequenceOrdinal: Int?
    let contentHash: String

    init(
        id: Int64,
        source: ScreenHistorySource,
        sourceIdentifier: String,
        capturedAt: Date,
        application: String?,
        bundleIdentifier: String?,
        domain: String?,
        windowTitle: String?,
        ocrText: String,
        imageLocator: String?,
        mediaLocator: String?,
        mediaFrameIndex: Int?,
        mediaFrameCount: Int? = nil,
        displayGeometry: ScreenHistoryDisplayGeometry? = nil,
        byteCount: Int64,
        sequenceIdentifier: String?,
        sequenceOrdinal: Int?,
        contentHash: String
    ) {
        self.id = id
        self.source = source
        self.sourceIdentifier = sourceIdentifier
        self.capturedAt = capturedAt
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
        self.windowTitle = windowTitle
        self.ocrText = ocrText
        self.imageLocator = imageLocator
        self.mediaLocator = mediaLocator
        self.mediaFrameIndex = mediaFrameIndex
        self.mediaFrameCount = mediaFrameCount
        self.displayGeometry = displayGeometry
        self.byteCount = byteCount
        self.sequenceIdentifier = sequenceIdentifier
        self.sequenceOrdinal = sequenceOrdinal
        self.contentHash = contentHash
    }
}

struct ScreenHistorySearchQuery: Equatable, Sendable {
    var text: String
    var from: Date?
    var through: Date?
    var application: String?
    var domain: String?
    var limit: Int
    var offset: Int

    init(
        text: String = "",
        from: Date? = nil,
        through: Date? = nil,
        application: String? = nil,
        domain: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) {
        self.text = text
        self.from = from
        self.through = through
        self.application = application
        self.domain = domain
        self.limit = min(max(1, limit), 200)
        self.offset = max(0, offset)
    }
}

struct ScreenHistoryRetentionPolicy: Equatable, Sendable {
    var retentionDays: Int?
    var storageCapBytes: Int64?

    init(retentionDays: Int? = nil, storageCapBytes: Int64? = nil) {
        self.retentionDays = retentionDays.map { max(0, $0) }
        self.storageCapBytes = storageCapBytes.map { max(0, $0) }
    }
}

struct ScreenHistoryPruneResult: Equatable, Sendable {
    /// Rows added to the durable prune queue by this call. A resumed queue has
    /// zero newly planned rows until it finishes.
    let rowsPlanned: Int
    let rowsRemoved: Int
    let bytesRemoved: Int64
    let filesRemoved: Int
    let filesRetainedShared: Int
    let filesRetainedUnowned: Int
    let filesAbsent: Int
    /// Rows and locators remain searchable until every required owned file is
    /// removed. A later call retries this durable queue.
    let pendingRows: Int
    let pendingLocators: Int
    let retryRequired: Bool
    let resumedQueue: Bool
}

struct ScreenHistoryPrunePreview: Equatable, Sendable {
    let policy: ScreenHistoryRetentionPolicy
    let rowsPlanned: Int
    let bytesPlanned: Int64
    let ownedFilesPlanned: Int
    let earliestRemoval: Date?
    let latestRemoval: Date?
    let retainedBytes: Int64
    let hasPendingQueue: Bool
}

/// A deterministic accounting receipt over one explicit wall-clock window.
/// Video bytes are attributed across their frame rows, so a complete segment's
/// row bytes sum to the exact media-file size without counting shared media once
/// per frame.
struct ScreenHistoryStorageRateReceipt: Equatable, Sendable {
    let from: Date
    let through: Date
    let frameCount: Int
    let attributedMediaBytes: Int64
    let bytesPerHour: Int64

    init?(
        from: Date,
        through: Date,
        frameCount: Int,
        attributedMediaBytes: Int64
    ) {
        let duration = through.timeIntervalSince(from)
        guard duration > 0, duration.isFinite,
              frameCount > 0,
              attributedMediaBytes >= 0
        else { return nil }
        self.from = from
        self.through = through
        self.frameCount = frameCount
        self.attributedMediaBytes = attributedMediaBytes
        bytesPerHour = Int64(
            (Double(attributedMediaBytes) * 3_600 / duration).rounded()
        )
    }
}

protocol ScreenHistoryStoring: Sendable {
    func record(_ frame: ScreenHistoryFrameInput) async throws -> Int64
    func record(_ frames: [ScreenHistoryFrameInput]) async throws -> Int
    func search(_ query: ScreenHistorySearchQuery) async throws -> [ScreenHistoryFrame]
    func sequence(containingFrameID frameID: Int64, limit: Int) async throws -> [ScreenHistoryFrame]
    func count() async throws -> Int
    func ocrBoxes(source: ScreenHistorySource, sourceIdentifier: String) async throws -> [ScreenHistoryOCRBox]
    func previewPrune(
        policy: ScreenHistoryRetentionPolicy,
        now: Date
    ) async throws -> ScreenHistoryPrunePreview
    func prune(policy: ScreenHistoryRetentionPolicy, now: Date) async throws -> ScreenHistoryPruneResult
}

extension ScreenHistoryStoring {
    func ocrBoxes(
        source: ScreenHistorySource,
        sourceIdentifier: String
    ) async throws -> [ScreenHistoryOCRBox] { [] }
    func previewPrune(
        policy: ScreenHistoryRetentionPolicy,
        now: Date
    ) async throws -> ScreenHistoryPrunePreview {
        ScreenHistoryPrunePreview(
            policy: policy,
            rowsPlanned: 0,
            bytesPlanned: 0,
            ownedFilesPlanned: 0,
            earliestRemoval: nil,
            latestRemoval: nil,
            retainedBytes: 0,
            hasPendingQueue: false
        )
    }
}

protocol CoastLegacyReading: Sendable {
    func isAvailable() async -> Bool
    func search(_ query: ScreenHistorySearchQuery) async throws -> [ScreenHistoryFrame]
    func page(offset: Int, limit: Int) async throws -> [ScreenHistoryFrame]
    func moments(from: Date, through: Date, limit: Int) async throws -> [ScreenHistoryFrame]
    func importRows(afterFrameID: Int64?, limit: Int) async throws -> [ScreenHistoryFrameInput]
    func migrationSourceBatch(
        afterFrameID: Int64?,
        limit: Int
    ) async throws -> ScreenHistoryMigrationSourceBatch
    func ocrBoxes(sourceIdentifier: String) async throws -> [ScreenHistoryOCRBox]
}

extension CoastLegacyReading {
    func ocrBoxes(sourceIdentifier: String) async throws -> [ScreenHistoryOCRBox] { [] }
    func moments(from: Date, through: Date, limit: Int) async throws -> [ScreenHistoryFrame] {
        []
    }

    func migrationSourceBatch(
        afterFrameID: Int64?,
        limit: Int
    ) async throws -> ScreenHistoryMigrationSourceBatch {
        let rows = try await importRows(afterFrameID: afterFrameID, limit: limit)
        return ScreenHistoryMigrationSourceBatch(
            rows: rows,
            supportedFamilies: Set(ScreenHistoryMigrationFamily.allCases),
            memberships: rows.map { frame in
                let application = frame.bundleIdentifier
                    .flatMap(Self.migrationIdentity)
                    .map { "bundle:\($0)" }
                    ?? frame.application.flatMap(Self.migrationIdentity).map { "name:\($0)" }
                let domain = frame.domain.flatMap(Self.migrationIdentity)
                let sequence = frame.sequenceIdentifier.flatMap(Self.migrationIdentity)
                var media: Set<String> = []
                if let image = frame.imageLocator, !image.isEmpty { media.insert("image:\(image)") }
                if let video = frame.mediaLocator, !video.isEmpty { media.insert("video:\(video)") }
                return ScreenHistoryMigrationFamilyMembership(
                    sourceIdentifier: frame.sourceIdentifier,
                    ocrIdentifier: "ocr:\(frame.sourceIdentifier)",
                    applicationIdentifier: application,
                    domainIdentifier: domain.map { "domain:\($0)" },
                    sequenceIdentifier: sequence.map { "sequence:\($0)" },
                    mediaIdentifiers: media
                )
            }
        )
    }

    private static func migrationIdentity(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
