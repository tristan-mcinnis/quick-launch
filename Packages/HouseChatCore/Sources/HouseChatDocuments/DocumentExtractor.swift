import CoreGraphics
import CryptoKit
import Foundation
import HouseChatCore

/// Reads one document or picture into the shared schema, holding every cap
/// and reporting each limited read honestly.
///
/// - Routing is by content type and extension, then confirmed against the
///   bytes, so a `.docx` that is not a ZIP says so.
/// - The original bytes are returned untouched in
///   `DocumentExtraction.originalBytes`; nothing here mutates them.
/// - Work runs in child tasks, so reads can run concurrently; cancellation is
///   checked between pages, slides, entries, and rows, and a 20-second
///   ceiling applies by default.
/// - No network: this module never fetches a link. A caller hands in the
///   fetched body with its source URL, and the original body is retained.
public actor DocumentExtractor {
    /// Written into each record; a newer extractor reads the source again.
    public static let version = 1

    /// The OCR entry point used when a caller injects none: on-device Apple
    /// Vision.
    public static let defaultRecognizer: DocumentTextRecognizer = { image in
        await VisionTextRecognizer.recognize(in: image)
    }

    /// The limits this reader holds.
    public nonisolated let configuration: DocumentExtractionConfiguration

    private let gate: DocumentFileGate
    private let recognizeText: DocumentTextRecognizer

    public init(
        configuration: DocumentExtractionConfiguration = .standard,
        recognizeText: @escaping DocumentTextRecognizer = DocumentExtractor.defaultRecognizer
    ) {
        self.configuration = configuration
        self.gate = DocumentFileGate(configuration: configuration)
        self.recognizeText = recognizeText
    }

    /// Reads a file on this Mac.
    public func extract(
        fileURL url: URL,
        progress: DocumentProgressHandler? = nil
    ) async throws -> DocumentExtraction {
        let configuration = self.configuration
        let gate = self.gate
        let recognizeText = self.recognizeText
        return try await Self.withTimeout(configuration.timeout) {
            let resolved = try await gate.resolve(url, progress: progress)
            progress?(.reading)
            try Task.checkCancellation()
            let data = try gate.readData(resolved)
            let source = DocumentSource(kind: .file, name: resolved.name, fileURL: resolved.url)
            return try await Self.read(
                data,
                name: resolved.name,
                route: resolved.route,
                packageURL: resolved.route == .rtfd ? resolved.url : nil,
                source: source,
                bodyWasTruncated: false,
                configuration: configuration,
                recognizeText: recognizeText,
                progress: progress
            )
        }
    }

    /// Reads bytes already in hand: a paste, a drop, or a caller's own read.
    ///
    /// When `sourceURL` is an http or https URL, the bytes are treated as a
    /// fetched page body and the source kind is `.fetchedBody`; the module
    /// never fetches anything itself. Pass `bodyWasTruncated` when the caller
    /// cut the body at a download cap, so the record says the page was
    /// partial.
    public func extract(
        data: Data,
        name: String,
        sourceURL: URL? = nil,
        bodyWasTruncated: Bool = false,
        progress: DocumentProgressHandler? = nil
    ) async throws -> DocumentExtraction {
        let configuration = self.configuration
        let recognizeText = self.recognizeText
        return try await Self.withTimeout(configuration.timeout) {
            let kind: DocumentSourceKind
            if let scheme = sourceURL?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                kind = .fetchedBody
            } else {
                kind = .data
            }
            let source = DocumentSource(kind: kind, name: name, url: sourceURL)
            let route = try Self.routeForData(
                name: name,
                data: data,
                isFetchedBody: kind == .fetchedBody,
                configuration: configuration
            )
            return try await Self.read(
                data,
                name: name,
                route: route,
                packageURL: nil,
                source: source,
                bodyWasTruncated: bodyWasTruncated && kind == .fetchedBody,
                configuration: configuration,
                recognizeText: recognizeText,
                progress: progress
            )
        }
    }

    // MARK: - Routing for bytes with no file

    static func routeForData(
        name: String,
        data: Data,
        isFetchedBody: Bool,
        configuration: DocumentExtractionConfiguration
    ) throws -> DocumentRoute {
        let url = URL(fileURLWithPath: name)
        var route = try DocumentFileGate.route(for: url, contentType: nil)
        if case .plainText(_, let label) = route, label == DocumentFileGate.unknownLabel {
            guard DocumentFileGate.looksLikeText(data, configuration: configuration) else {
                throw DocumentExtractionError.unsupported(DocumentFileGate.unsupportedLine(for: url))
            }
            route = .plainText(.text, label: "Text")
        }
        if isFetchedBody, route == .plainText(.text, label: "Text") || route == .plainText(.text, label: DocumentFileGate.unknownLabel) {
            if Self.looksLikeHTML(data) { route = .html }
        }
        let limit = route.byteLimit(configuration)
        guard data.count <= limit else { throw DocumentExtractionError.tooLarge(limit: limit) }
        return route
    }

    static func looksLikeHTML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2_048), as: UTF8.self).lowercased()
        return head.contains("<!doctype html")
            || head.contains("<html")
            || head.contains("<head")
            || head.contains("<body")
    }

    // MARK: - The read

    static func read(
        _ data: Data,
        name: String,
        route: DocumentRoute,
        packageURL: URL?,
        source: DocumentSource,
        bodyWasTruncated: Bool,
        configuration: DocumentExtractionConfiguration,
        recognizeText: DocumentTextRecognizer,
        progress: DocumentProgressHandler?
    ) async throws -> DocumentExtraction {
        let confirmed = try DocumentFileGate.confirm(route, data: data)
        let hash = sha256(data)
        try Task.checkCancellation()

        if confirmed == .image {
            let normalized = try DocumentImageReader.normalizedImage(from: data, configuration: configuration)
            let document = ExtractedDocument(
                kind: .image,
                kindLabel: "Image",
                name: name,
                notes: [],
                contentHash: hash,
                byteCount: data.count,
                path: source.fileURL?.path,
                url: source.url,
                pixelWidth: normalized.pixelWidth,
                pixelHeight: normalized.pixelHeight,
                normalizedImageMimeType: normalized.mimeType,
                extractorVersion: version,
                extractedAt: Date()
            )
            return DocumentExtraction(
                document: document,
                originalBytes: data,
                normalizedImage: normalized,
                source: source
            )
        }

        var notes: [DocumentNote] = []
        let documentText: DocumentText
        switch confirmed {
        case .pdf:
            documentText = try await PDFTextExtractor.extract(
                data: data,
                recognizeText: recognizeText,
                configuration: configuration,
                progress: progress
            )
        case .docx:
            documentText = try OOXMLTextExtractor.word(data: data, configuration: configuration)
        case .pptx:
            documentText = try OOXMLTextExtractor.powerPoint(data: data, configuration: configuration)
        case .xlsx:
            documentText = try OOXMLTextExtractor.excel(data: data, configuration: configuration)
        case .odt:
            documentText = try OOXMLTextExtractor.openDocument(data: data, configuration: configuration)
        case .doc, .rtf, .rtfd:
            documentText = try AttributedDocumentReader.read(
                route: confirmed,
                data: data,
                packageURL: packageURL,
                packageByteLimit: configuration.maximumDocumentBytes
            )
        case .html:
            let html = PlainTextReader.decodeHTML(data)
            let extracted = HTMLTextExtractor.text(from: html)
            if !extracted.droppedUnclosedBlocks.isEmpty {
                let names = extracted.droppedUnclosedBlocks.joined(separator: ">, <")
                notes.append(DocumentNote(
                    kind: .partialExtraction,
                    modelLine: "[Part of this page was unreadable and left out: an unclosed <\(names)> block.]",
                    detailLine: "unclosed <\(names)> left out"
                ))
            }
            documentText = DocumentText(text: htmlText(html, extracted: extracted))
        case .plainText(let kind, _):
            let text: String
            do {
                text = try PlainTextReader.decode(
                    data,
                    fileURL: source.fileURL,
                    binaryCheckBytes: configuration.binaryCheckBytes
                )
            } catch {
                throw DocumentExtractionError.wrongContent(kind)
            }
            documentText = DocumentText(text: text, normalizes: kind != .code)
        case .image:
            throw DocumentExtractionError.wrongContent(.image)
        }
        try Task.checkCancellation()

        if bodyWasTruncated {
            notes.append(.linkBodyCut(limitBytes: data.count))
        }

        let finished = try documentText.finished(characterCap: configuration.maximumCharacters)
        let fetchedPage = source.kind == .fetchedBody && (confirmed == .html || confirmed == .plainText(.text, label: "Text"))
        let document = ExtractedDocument(
            kind: fetchedPage ? .link : confirmed.kind,
            kindLabel: fetchedPage ? "Web page" : confirmed.label,
            name: name,
            sections: finished.sections,
            sectionUnit: documentText.sectionUnit,
            unitCount: documentText.unitCount,
            unitCut: documentText.unitCut.map {
                DocumentUnitCut(unit: $0.unit, kept: $0.kept, total: $0.total)
            },
            notes: documentText.notes + notes,
            contentHash: hash,
            byteCount: data.count,
            characterCount: finished.characterCount,
            text: finished.text,
            truncation: finished.truncation,
            path: source.fileURL?.path,
            url: source.url,
            extractorVersion: version,
            extractedAt: Date()
        )
        return DocumentExtraction(
            document: document,
            originalBytes: data,
            normalizedImage: nil,
            source: source
        )
    }

    /// An HTML document as a title line, then its readable text.
    static func htmlText(_ html: String) -> String {
        htmlText(html, extracted: HTMLTextExtractor.text(from: html))
    }

    /// The same, with an extraction that already carries the dropped-block
    /// list, so the read reports a partial page once.
    static func htmlText(_ html: String, extracted: HTMLTextExtractor.Result) -> String {
        let body = extracted.text
        guard let title = HTMLTextExtractor.title(from: html) else { return body }
        return body.isEmpty ? title : "\(title)\n\n\(body)"
    }

    // MARK: - Time and hashing

    /// Runs `body`, or throws `.timedOut` when it passes `limit`.
    ///
    /// This is a cooperative deadline, not a hard stop: the losing child is
    /// cancelled and then joined, so the call returns once the child reaches
    /// its next cancellation check. Work that cannot check cancellation (a
    /// blocking native call with no cancel hook) runs to the end of that
    /// section, and the join waits for it. Nothing is left running in the
    /// background. On-device OCR is cancelled through `VNRequest.cancel()`,
    /// so the common long path is bounded.
    static func withTimeout<T: Sendable>(
        _ limit: Duration,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw DocumentExtractionError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    /// SHA-256 of the source bytes, lowercase hex.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
