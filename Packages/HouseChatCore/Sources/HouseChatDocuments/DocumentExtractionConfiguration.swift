import Foundation

/// Every cap the shared document reader holds, in one place, so the reader,
/// the callers and the tests read the same numbers.
///
/// The defaults are the approved House limits: a 50 MB document, a 5 MB text
/// file, 300 PDF pages, 300 slides, 10 sheets, 5,000 rows, 100 columns, OCR
/// on 10 pages, a 20-second ceiling, images scaled to 2,048 px, and up to
/// 2,000,000 characters of extracted text per file before any model budget is
/// applied.
public struct DocumentExtractionConfiguration: Sendable, Equatable {
    /// Largest document file that will be read, in bytes.
    public var maximumDocumentBytes: Int
    /// Largest plain text, Markdown, code, or HTML file that will be read.
    public var maximumTextFileBytes: Int
    /// Largest image file that will be read.
    public var maximumImageBytes: Int
    /// Extracted characters retained per file, before model selection.
    public var maximumCharacters: Int
    /// PDF pages read, from the first.
    public var pdfPageLimit: Int
    /// Scanned PDF pages OCR reads, from the first pages without text.
    public var ocrPageLimit: Int
    /// A page with fewer non-space characters than this counts as scanned.
    public var ocrPageCharacterThreshold: Int
    /// Long side a scanned page is rendered at for OCR.
    public var ocrRenderPixels: Int
    /// Slides read, from the first.
    public var slideLimit: Int
    /// Sheets read, from the first.
    public var sheetLimit: Int
    /// Rows read per sheet, from the first.
    public var rowLimit: Int
    /// Columns read per sheet, from the first.
    public var columnLimit: Int
    /// ZIP entries allowed before any entry is inflated.
    public var zipEntryLimit: Int
    /// Bytes one ZIP entry may inflate to.
    public var zipEntryOutputBytes: Int
    /// Bytes one archive may inflate to in total.
    public var zipArchiveOutputBytes: Int
    /// Long side an image is scaled to before it is sent to a model.
    public var imageLongSidePixels: Int
    /// An encoded image over this size is normalized to JPEG instead of PNG.
    public var imagePNGBytes: Int
    /// Bytes checked for a NUL when deciding whether a file is text.
    public var binaryCheckBytes: Int
    /// Cooperative deadline for one read. The read is cancelled at the
    /// deadline and then joined, so a cancellation-aware unit stops promptly
    /// while a native unit with no cancel hook runs to the end of its current
    /// section. It is not a hard wall-clock stop.
    public var timeout: Duration

    public init(
        maximumDocumentBytes: Int = 50 * 1_024 * 1_024,
        maximumTextFileBytes: Int = 5 * 1_024 * 1_024,
        maximumImageBytes: Int = 20 * 1_024 * 1_024,
        maximumCharacters: Int = 2_000_000,
        pdfPageLimit: Int = 300,
        ocrPageLimit: Int = 10,
        ocrPageCharacterThreshold: Int = 20,
        ocrRenderPixels: Int = 2_000,
        slideLimit: Int = 300,
        sheetLimit: Int = 10,
        rowLimit: Int = 5_000,
        columnLimit: Int = 100,
        zipEntryLimit: Int = 5_000,
        zipEntryOutputBytes: Int = 16 * 1_024 * 1_024,
        zipArchiveOutputBytes: Int = 64 * 1_024 * 1_024,
        imageLongSidePixels: Int = 2_048,
        imagePNGBytes: Int = 2 * 1_024 * 1_024,
        binaryCheckBytes: Int = 8 * 1_024,
        timeout: Duration = .seconds(20)
    ) {
        self.maximumDocumentBytes = maximumDocumentBytes
        self.maximumTextFileBytes = maximumTextFileBytes
        self.maximumImageBytes = maximumImageBytes
        self.maximumCharacters = maximumCharacters
        self.pdfPageLimit = pdfPageLimit
        self.ocrPageLimit = ocrPageLimit
        self.ocrPageCharacterThreshold = ocrPageCharacterThreshold
        self.ocrRenderPixels = ocrRenderPixels
        self.slideLimit = slideLimit
        self.sheetLimit = sheetLimit
        self.rowLimit = rowLimit
        self.columnLimit = columnLimit
        self.zipEntryLimit = zipEntryLimit
        self.zipEntryOutputBytes = zipEntryOutputBytes
        self.zipArchiveOutputBytes = zipArchiveOutputBytes
        self.imageLongSidePixels = imageLongSidePixels
        self.imagePNGBytes = imagePNGBytes
        self.binaryCheckBytes = binaryCheckBytes
        self.timeout = timeout
    }

    public static let standard = DocumentExtractionConfiguration()
}

/// The fixed ZIP-bomb heuristics that are not exposed as knobs.
enum DocumentLimits {
    /// An entry is refused when its declared ratio is over this and its
    /// declared output is over `zipRatioFloorBytes`.
    static let zipDeclaredRatio = 200
    static let zipRatioFloorBytes = 1 * 1_024 * 1_024
}
