import AppKit
import Foundation
import HouseChatCore
import PDFKit

/// Reads a PDF page by page with PDFKit, one `DocumentSection` per page.
///
/// - A locked PDF (it needs a password to open) is refused; there is no
///   password prompt here.
/// - At most `configuration.pdfPageLimit` pages are read.
/// - A scan is detected (at least half the read pages give under
///   `ocrPageCharacterThreshold` characters) and the first
///   `ocrPageLimit` pages without text are read by on-device OCR, in order.
///   The notes say so.
enum PDFTextExtractor {
    static func extract(
        data: Data,
        recognizeText: DocumentTextRecognizer,
        configuration: DocumentExtractionConfiguration,
        progress: DocumentProgressHandler? = nil
    ) async throws -> DocumentText {
        guard let document = PDFDocument(data: data) else { throw DocumentExtractionError.damaged }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw DocumentExtractionError.passwordProtected
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else { throw DocumentExtractionError.empty }
        let readCount = min(pageCount, configuration.pdfPageLimit)

        var bodies: [String] = []
        bodies.reserveCapacity(readCount)
        for index in 0..<readCount {
            try Task.checkCancellation()
            bodies.append(document.page(at: index)?.string ?? "")
        }

        // Every page with too little text is a candidate for OCR. The page cap
        // bounds how many are attempted, and a page the cap leaves unread is
        // reported as a partial read rather than silently dropped.
        let thin = bodies.indices.filter {
            Self.isThin(bodies[$0], threshold: configuration.ocrPageCharacterThreshold)
        }
        var notes: [DocumentNote] = []
        var skippedThin: [Int] = []
        if !thin.isEmpty {
            let targets = Array(thin.prefix(configuration.ocrPageLimit))
            skippedThin = Array(thin.dropFirst(configuration.ocrPageLimit))
            var recognized: [Int] = []
            for (step, index) in targets.enumerated() {
                try Task.checkCancellation()
                progress?(.recognizingText(page: step + 1, of: targets.count))
                guard let page = document.page(at: index),
                      let image = render(page, pixels: configuration.ocrRenderPixels) else { continue }
                let text = await recognizeText(image)
                try Task.checkCancellation()
                let found = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !found.isEmpty { recognized.append(index + 1) }
                // OCR reads what the thin text layer had too; keep the longer.
                if found.count > bodies[index].trimmingCharacters(in: .whitespacesAndNewlines).count {
                    bodies[index] = text
                }
            }
            if !recognized.isEmpty {
                notes.append(.ocr(pages: recognized, totalPages: pageCount))
            }
            let anyText = bodies.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !anyText { throw DocumentExtractionError.scannedNoText }
        }

        let sections = bodies.enumerated().map { index, body in
            DocumentText.Section(
                label: "Page \(index + 1)",
                unit: .page,
                index: index + 1,
                range: DocumentRange(start: index + 1, end: index + 1),
                body: body
            )
        }
        var unitCut: DocumentText.UnitCut?
        if pageCount > readCount {
            unitCut = DocumentText.UnitCut(unit: .page, kept: readCount, total: pageCount)
        }
        var partialTruncation: TextTruncation?
        if !skippedThin.isEmpty {
            // Pages the OCR cap skipped were never read. Coverage is the pages
            // actually processed, which need not be a prefix: a text page after
            // a skipped scan is still covered. A blank page OCR attempted is
            // covered too, so coverage is not "pages with text".
            let skipped = Set(skippedThin.map { $0 + 1 })
            let covered = (1...readCount).filter { !skipped.contains($0) }
            partialTruncation = TextTruncation(
                unit: .page,
                keptUnits: covered.count,
                totalUnits: pageCount,
                coveredUnits: covered
            )
            // The page cap and the OCR cap can cut the same read. `finished`
            // then reports the page-cap line ("first 300 of 400 pages"), so
            // name the skipped pages here rather than let the record read as a
            // contiguous text-bearing head.
            if pageCount > readCount {
                let skippedPages = skippedThin.map { $0 + 1 }
                let phrase = Self.pagesPhrase(skippedPages)
                notes.append(DocumentNote(
                    kind: .partialExtraction,
                    modelLine: "[Some pages inside the read range had no text layer and were not read by OCR: \(phrase).]",
                    detailLine: "OCR skipped \(phrase)"
                ))
            }
        }
        return DocumentText(
            sections: sections,
            sectionUnit: .page,
            unitCount: pageCount,
            unitCut: unitCut,
            partialTruncation: partialTruncation,
            notes: notes
        )
    }

    /// A page with fewer non-space characters than the threshold.
    static func isThin(_ text: String, threshold: Int) -> Bool {
        var count = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            count += 1
            if count >= threshold { return false }
        }
        return true
    }

    /// Skipped pages as a compact one-based phrase: "page 7", "pages 3-5",
    /// "pages 2-4, 9". Input is ascending.
    static func pagesPhrase(_ pages: [Int]) -> String {
        guard !pages.isEmpty else { return "none" }
        var runs: [String] = []
        var start = pages[0]
        var previous = pages[0]
        for page in pages.dropFirst() {
            if page == previous + 1 {
                previous = page
                continue
            }
            runs.append(start == previous ? "\(start)" : "\(start)-\(previous)")
            start = page
            previous = page
        }
        runs.append(start == previous ? "\(start)" : "\(start)-\(previous)")
        return "\(pages.count == 1 ? "page" : "pages") \(runs.joined(separator: ", "))"
    }

    /// The page as an image with its long side at `pixels`.
    static func render(_ page: PDFPage, pixels: Int) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let width = rotated ? bounds.height : bounds.width
        let height = rotated ? bounds.width : bounds.height
        guard width > 0, height > 0 else { return nil }
        let scale = CGFloat(pixels) / max(width, height)
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
