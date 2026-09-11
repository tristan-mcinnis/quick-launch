import AppKit
import Foundation
import PDFKit

/// Reads a PDF page by page with PDFKit, with `--- Page N ---` markers.
///
/// - A locked PDF (it needs a password to open) is refused; v1 has no
///   password prompt.
/// - At most `AttachmentLimits.pdfPages` pages are read.
/// - A scan is detected (at least half the read pages give under 20
///   characters) and the first `AttachmentLimits.ocrPages` pages without
///   text are read by on-device OCR, in order. The notes say so.
enum PDFTextExtractor {
    static func extract(
        data: Data,
        recognizeText: AttachmentTextRecognizer,
        progress: AttachmentProgressHandler? = nil
    ) async throws -> DocumentText {
        guard let document = PDFDocument(data: data) else { throw AttachmentFailure.damaged }
        if document.isLocked, !document.unlock(withPassword: "") {
            throw AttachmentFailure.passwordProtected
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else { throw AttachmentFailure.empty }
        let readCount = min(pageCount, AttachmentLimits.pdfPages)

        var bodies: [String] = []
        bodies.reserveCapacity(readCount)
        for index in 0..<readCount {
            try Task.checkCancellation()
            bodies.append(document.page(at: index)?.string ?? "")
        }

        let thin = bodies.indices.filter { Self.isThin(bodies[$0]) }
        var notes: [AttachmentNote] = []
        let isScan = thin.count * 2 >= readCount
        if isScan {
            let targets = Array(thin.prefix(AttachmentLimits.ocrPages))
            var recognized: [Int] = []
            for (step, index) in targets.enumerated() {
                try Task.checkCancellation()
                progress?(.recognizingText(page: step + 1, of: targets.count))
                guard let page = document.page(at: index), let image = render(page) else { continue }
                let text = await recognizeText(image)
                try Task.checkCancellation()
                recognized.append(index + 1)
                // OCR reads what the thin text layer had too; keep the longer.
                let found = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if found.count > bodies[index].trimmingCharacters(in: .whitespacesAndNewlines).count {
                    bodies[index] = text
                }
            }
            if !recognized.isEmpty {
                notes.append(.ocr(pages: recognized, totalPages: pageCount))
            }
            let anyText = bodies.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !anyText { throw AttachmentFailure.scannedNoText }
        }

        let sections = bodies.enumerated().map { index, body in
            DocumentText.Section(marker: "--- Page \(index + 1) ---", body: body)
        }
        let cut = pageCount > readCount
            ? DocumentText.UnitCut(unit: .page, kept: readCount, total: pageCount)
            : nil
        return DocumentText(
            sections: sections,
            sectionUnit: .page,
            unitCount: pageCount,
            unitCut: cut,
            notes: notes
        )
    }

    /// A page with fewer than `scannedPageCharacters` non-space characters.
    static func isThin(_ text: String) -> Bool {
        var count = 0
        for scalar in text.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            count += 1
            if count >= AttachmentLimits.scannedPageCharacters { return false }
        }
        return true
    }

    /// The page as an image with its long side at `ocrRenderPixels`.
    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let width = rotated ? bounds.height : bounds.width
        let height = rotated ? bounds.width : bounds.height
        guard width > 0, height > 0 else { return nil }
        let scale = CGFloat(AttachmentLimits.ocrRenderPixels) / max(width, height)
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
