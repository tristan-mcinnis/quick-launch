import CoreGraphics
import CoreText
import Foundation
import HouseChatCore
import Testing
@testable import HouseChatDocuments

/// A recognizer that ignores cancellation entirely, to pin the honest
/// behaviour of the read's cooperative deadline.
actor StubbornOCR {
    private(set) var finished = false
    private let seconds: Double

    init(seconds: Double) { self.seconds = seconds }

    func recognize(_ image: CGImage) async -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { /* on purpose: no cancellation check */ }
        finished = true
        return "stubborn OCR text"
    }

    nonisolated var recognizer: DocumentTextRecognizer {
        { [self] image in await recognize(image) }
    }
}

@Suite("HouseChatDocuments verifier regressions")
struct DocumentRegressionTests {
    private let folder = Fixtures.folder("regression")

    private func failure(
        _ operation: () async throws -> DocumentExtraction
    ) async -> DocumentExtractionError? {
        do {
            _ = try await operation()
            return nil
        } catch let error as DocumentExtractionError {
            return error
        } catch {
            Issue.record("Unexpected error \(error)")
            return nil
        }
    }

    // MARK: OCR cap on a mixed document

    @Test("A mixed text and scanned PDF OCRs thin pages and reports the ones the cap skipped")
    func mixedScanPartial() async throws {
        let data = Fixtures.mixedPDF(
            text: "This first page has a real text layer with plenty of characters to read.",
            scannedPages: ["Scanned page two", "Scanned page three"]
        )
        var configuration = DocumentExtractionConfiguration.standard
        configuration.ocrPageLimit = 1
        let recognizer = FakeOCR(reply: "OCR read page two")
        let result = try await DocumentExtractor(configuration: configuration, recognizeText: recognizer.recognizer)
            .extract(fileURL: Fixtures.write(data, named: "mixed.pdf", in: folder))

        #expect(await recognizer.count == 1)
        #expect(result.document.unitCount == 3)
        #expect(result.document.text?.contains("real text layer") == true)
        #expect(result.document.text?.contains("OCR read page two") == true)
        #expect(result.document.truncation?.coveredUnits == [1, 2])
        #expect(result.document.truncation?.totalUnits == 3)
        #expect(result.document.truncation?.summary == "pages 1-2 of 3")
        #expect(result.limitSummary != nil)
        #expect(result.isComplete == false)
    }

    @Test("Scattered coverage is reported as the real set, never a false 1-3 range")
    func scatteredCoverage() async throws {
        // Page order: scanned(1), text(2), scanned(3), text(4), OCR cap 1.
        // Page 3's scan is skipped, so coverage is 1, 2, 4 - not 1-3.
        let data = interleavedPDF([
            .scanned("Scanned page one"),
            .text("This page two has a real text layer with plenty of characters to read."),
            .scanned("Scanned page three"),
            .text("This page four also has a real text layer with plenty of characters."),
        ])
        var configuration = DocumentExtractionConfiguration.standard
        configuration.ocrPageLimit = 1
        let recognizer = FakeOCR(reply: "OCR read page one")
        let result = try await DocumentExtractor(configuration: configuration, recognizeText: recognizer.recognizer)
            .extract(fileURL: Fixtures.write(data, named: "scattered.pdf", in: folder))

        #expect(await recognizer.count == 1)
        #expect(result.document.unitCount == 4)
        #expect(result.document.text?.contains("page two") == true)
        #expect(result.document.text?.contains("page four") == true)
        #expect(result.document.text?.contains("OCR read page one") == true)
        #expect(result.document.truncation?.coveredUnits == [1, 2, 4])
        #expect(result.document.truncation?.summary == "pages 1, 2, 4 of 4")
        #expect(result.document.truncation?.summary.contains("1-3") == false)
        #expect(result.isComplete == false)
    }

    @Test("A blank page OCR attempted is still reported as covered")
    func blankProcessedPageCovered() async throws {
        // Page 1 is scanned and OCR returns nothing; page 2 has text; page 3's
        // scan is skipped. Coverage is the processed pages 1 and 2, even though
        // page 1 produced no text.
        let data = interleavedPDF([
            .scanned("Blank scan page one"),
            .text("This page two has a real text layer with plenty of characters to read."),
            .scanned("Skipped scan page three"),
        ])
        var configuration = DocumentExtractionConfiguration.standard
        configuration.ocrPageLimit = 1
        let result = try await DocumentExtractor(configuration: configuration, recognizeText: FakeOCR(reply: "").recognizer)
            .extract(fileURL: Fixtures.write(data, named: "blank-covered.pdf", in: folder))

        #expect(result.document.truncation?.coveredUnits == [1, 2])
        #expect(result.document.truncation?.summary == "pages 1-2 of 3")
        #expect(result.isComplete == false)
    }

    @Test("An all-scan prefix is still written as a range")
    func allScanPrefixCoverage() async throws {
        let data = Fixtures.scannedPDF(pages: (1...4).map { "Scanned page \($0)" })
        var configuration = DocumentExtractionConfiguration.standard
        configuration.ocrPageLimit = 2
        let result = try await DocumentExtractor(configuration: configuration, recognizeText: FakeOCR().recognizer)
            .extract(fileURL: Fixtures.write(data, named: "allscan.pdf", in: folder))

        #expect(result.document.truncation?.coveredUnits == [1, 2])
        #expect(result.document.truncation?.summary == "pages 1-2 of 4")
        #expect(result.isComplete == false)
    }

    @Test("A scan read inside the cap is complete, with every page carrying text")
    func scanWithinCapComplete() async throws {
        let data = Fixtures.scannedPDF(pages: (1...3).map { "Scanned page \($0)" })
        let recognizer = FakeOCR(reply: "Recognized text")
        let result = try await DocumentExtractor(
            configuration: .standard,
            recognizeText: recognizer.recognizer
        ).extract(fileURL: Fixtures.write(data, named: "full.pdf", in: folder))

        #expect(await recognizer.count == 3)
        #expect(result.document.sections.count == 3)
        #expect(result.document.truncation == nil)
        #expect(result.isComplete)
    }

    // MARK: HTML blocks cut before their close tag

    @Test("An unclosed script block is discarded, not read into the text")
    func unclosedScript() async throws {
        let body = Data("""
        <html><body><p>Before</p><script>var leak = "UNCLOSED-TOKEN";
        function f() { return 1; }
        <p>After</p></body></html>
        """.utf8)
        let result = try await DocumentExtractor().extract(data: body, name: "unclosed.html")
        #expect(result.document.text?.contains("Before") == true)
        #expect(result.document.text?.contains("UNCLOSED-TOKEN") == false)
        #expect(result.document.text?.contains("function f()") == false)
        #expect(result.originalBytes == body)
    }

    @Test("A fetched body cut mid-script keeps its bytes and drops the script source")
    func cutMidScript() async throws {
        let minified = String(repeating: "var q=function(){return 1};", count: 400)
        let body = Data("<html><head><title>Cut Page</title></head><body><p>Real words.</p><script>\(minified)".utf8)
        let result = try await DocumentExtractor().extract(
            data: body,
            name: "cut.html",
            sourceURL: URL(string: "https://example.com/cut")!,
            bodyWasTruncated: true
        )
        #expect(result.document.text?.contains("Real words.") == true)
        #expect(result.document.text?.contains("q=function") == false)
        #expect(result.document.text?.count ?? 0 < 200)
        #expect(result.originalBytes == body)
        #expect(result.isComplete == false)
    }

    @Test("A paired script is still removed and an unclosed header does not swallow a header tag")
    func scriptStillRemoved() async throws {
        let body = Data("<div>Kept</div><script>DROP-ME</script><header>Header words</header><span>Also kept</span>".utf8)
        let result = try await DocumentExtractor().extract(data: body, name: "fragment.html")
        #expect(result.document.text?.contains("DROP-ME") == false)
        #expect(result.document.text?.contains("Kept") == true)
        #expect(result.document.text?.contains("Header words") == true)
    }

    // MARK: .rtfd

    @Test("A flat .rtfd file is read as RTF, not refused")
    @MainActor
    func flatRTFD() async throws {
        let rtf = Fixtures.attributed("flat rtfd body", type: .rtf)
        let url = Fixtures.write(rtf, named: "flat.rtfd", in: folder)
        let result = try await DocumentExtractor().extract(fileURL: url)
        #expect(result.document.text?.contains("flat rtfd body") == true)
        #expect(result.document.kind == .word)
        #expect(result.originalBytes == rtf)
    }

    @Test("A .rtfd package that reads past its cap is refused on the bytes actually read")
    func rtfdPostReadCap() throws {
        let package = folder.appending(path: "Docs.rtfd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 200).write(to: package.appending(path: "TXT.rtf"))
        try Data(repeating: 0x42, count: 200).write(to: package.appending(path: "extra.bin"))

        // Under the cap: the files' bytes in name order.
        let under = try DocumentFileGate.packageData(package, limit: 1_000)
        #expect(under.count > 400)

        // Over the cap: refused while reading, so the returned bytes never
        // exceed it.
        do {
            _ = try DocumentFileGate.packageData(package, limit: 100)
            Issue.record("Expected tooLarge")
        } catch let error as DocumentExtractionError {
            #expect(error == .tooLarge(limit: 100))
        }
    }

    // MARK: The cooperative deadline

    @Test("The deadline is cooperative: an uncancellable child is joined, then timedOut")
    func cooperativeDeadline() async throws {
        var configuration = DocumentExtractionConfiguration.standard
        configuration.timeout = .milliseconds(40)
        let stubborn = StubbornOCR(seconds: 0.3)
        let url = Fixtures.write(Fixtures.scannedPDF(pages: ["slow"]), named: "stubborn.pdf", in: folder)
        let clock = ContinuousClock()
        let start = clock.now
        let error = await failure {
            try await DocumentExtractor(configuration: configuration, recognizeText: stubborn.recognizer)
                .extract(fileURL: url)
        }
        let elapsed = start.duration(to: clock.now)

        #expect(error == .timedOut)
        // The deadline fires well before the child ends, but the call joins the
        // child rather than leaving it running: this is documented, not a hard
        // wall-clock stop.
        #expect(elapsed > .milliseconds(250))
        #expect(await stubborn.finished)
    }
}

// MARK: - Interleaved PDF fixture

/// A page in an interleaved PDF: a real text layer, or a picture of text with
/// no layer (a scan).
private enum MixedPage {
    case text(String)
    case scanned(String)
}

/// Builds one PDF whose pages keep the order given, so a scan can sit before a
/// text page: the case a prefix-only coverage range would get wrong.
private func interleavedPDF(_ pages: [MixedPage]) -> Data {
    let output = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let consumer = CGDataConsumer(data: output as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
    for page in pages {
        context.beginPDFPage(nil)
        switch page {
        case .text(let body):
            var y: CGFloat = 740
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                drawText(String(line), font: font, at: CGPoint(x: 54, y: y), in: context)
                y -= 14
            }
        case .scanned(let body):
            let image = Fixtures.textImage(body, width: 1_224, height: 400)
            context.draw(image, in: CGRect(x: 0, y: 792 - 200, width: 612, height: 200))
        }
        context.endPDFPage()
    }
    context.closePDF()
    return output as Data
}

private func drawText(_ text: String, font: CTFont, at point: CGPoint, in context: CGContext) {
    let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = point
    CTLineDraw(line, context)
}
