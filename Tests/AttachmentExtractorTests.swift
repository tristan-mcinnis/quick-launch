import AppKit
import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import QuickLaunch

/// Counts OCR calls and answers with canned text.
private final class FakeRecognizer: Sendable {
    private let calls = Mutex(0)
    private let reply: String
    private let delay: Duration

    init(reply: String = "Recognized text from a scanned page of the report.", delay: Duration = .zero) {
        self.reply = reply
        self.delay = delay
    }

    var count: Int { calls.withLock { $0 } }

    var recognizer: AttachmentTextRecognizer {
        { [self] _ in
            calls.withLock { $0 += 1 }
            if delay > .zero { try? await Task.sleep(for: delay) }
            return reply
        }
    }
}

/// Records the read phases a chip would show.
private final class PhaseLog: Sendable {
    private let phases = Mutex<[AttachmentReadPhase]>([])
    var all: [AttachmentReadPhase] { phases.withLock { $0 } }
    var handler: AttachmentProgressHandler { { [self] phase in phases.withLock { $0.append(phase) } } }
}

/// Every file kind the extractor reads, its caps and failure lines, and the
/// file gate in front of it. Fixtures are built here; none is committed.
@Suite("Attachment extractor")
struct AttachmentExtractorTests {
    private let folder = AttachmentFixtures.folder("extract")

    private func extractor(
        recognizer: FakeRecognizer = FakeRecognizer(),
        gate: AttachmentFileGate = AttachmentFileGate(),
        timeout: Duration = AttachmentLimits.extractionTimeout
    ) -> AttachmentExtractor {
        AttachmentExtractor(
            gate: gate,
            linkReader: LinkAttachmentReader(remoteRead: nil),
            recognizeText: recognizer.recognizer,
            timeout: timeout
        )
    }

    private func file(_ name: String, _ data: Data) -> URL {
        AttachmentFixtures.write(data, named: name, in: folder)
    }

    private func file(_ name: String, text: String) -> URL {
        file(name, Data(text.utf8))
    }

    private func read(_ url: URL, with extractor: AttachmentExtractor? = nil) async throws -> ExtractedAttachment {
        try await (extractor ?? self.extractor()).extract(fileAt: url)
    }

    private func failure(_ url: URL, with extractor: AttachmentExtractor? = nil) async -> AttachmentFailure? {
        do {
            _ = try await read(url, with: extractor)
            return nil
        } catch let failure as AttachmentFailure {
            return failure
        } catch {
            Issue.record("Unexpected error \(error)")
            return nil
        }
    }

    // MARK: Text, Markdown, code

    @Test("A text file keeps English, accents, and Chinese, with its reference")
    func plainText() async throws {
        let text = [AttachmentFixtures.english, AttachmentFixtures.accents, AttachmentFixtures.chinese]
            .joined(separator: "\n")
        let url = file("notes.txt", text: text)
        let result = try await read(url)

        #expect(result.text == text)
        #expect(result.kindLabel == "Text")
        #expect(result.ref.kind == .text)
        #expect(result.ref.name == "notes.txt")
        #expect(result.ref.path == url.resolvingSymlinksInPath().path)
        #expect(result.ref.characterCount == text.count)
        #expect(result.ref.byteCount == Data(text.utf8).count)
        #expect(result.ref.extractorVersion == AttachmentExtractor.version)
        let expectedHash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(result.ref.contentHash == expectedHash)
        #expect(result.ref.truncation == nil)
        #expect(result.image == nil)
    }

    @Test("NFKC turns the Kangxi radical U+2F42 into 文 in text, never in code")
    func nfkc() async throws {
        let raw = "中\u{2F42} ｗｉｄｅ ﬁle"
        let text = try await read(file("kangxi.md", text: raw))
        #expect(text.text == "中文 wide file")
        #expect(text.ref.kind == .markdown)

        let code = try await read(file("kangxi.swift", text: "let s = \"\(raw)\"\r\n"))
        #expect(code.text == "let s = \"\(raw)\"")
        #expect(code.ref.kind == .code)
        #expect(code.kindLabel == "Swift source")
        #expect(AttachmentTextCleaner.clean("中\u{2F42}", normalizes: true) == "中文")
    }

    @Test("Text decoding: byte-order marks, GB18030, Windows-1252, and a NUL byte")
    func decoding() async throws {
        let sample = "Café 中文 naïve"
        let utf8BOM = Data([0xEF, 0xBB, 0xBF]) + Data(sample.utf8)
        #expect(try await read(file("bom8.txt", utf8BOM)).text == sample)

        let utf16LE = Data([0xFF, 0xFE]) + sample.data(using: .utf16LittleEndian)!
        #expect(try await read(file("bom16le.txt", utf16LE)).text == sample)

        let utf16BE = Data([0xFE, 0xFF]) + sample.data(using: .utf16BigEndian)!
        #expect(try await read(file("bom16be.txt", utf16BE)).text == sample)

        let utf32LE = Data([0xFF, 0xFE, 0x00, 0x00]) + sample.data(using: .utf32LittleEndian)!
        #expect(try await read(file("bom32le.txt", utf32LE)).text == sample)

        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let chinese = "季度报告 收入增长 成本下降。这是一个简单的中文文本文件。"
        let gb = try #require(chinese.data(using: gbEncoding))
        #expect(try await read(file("gb.txt", gb)).text == chinese)

        let latin = "naïve café résumé"
        #expect(try await read(file("latin.txt", latin.data(using: .windowsCP1252)!)).text == latin)

        var binary = Data("looks like text".utf8)
        binary.append(0)
        binary.append(contentsOf: Data("then a NUL".utf8))
        #expect(await failure(file("nul.txt", binary)) == .wrongContent(.text))
        #expect(AttachmentFailure.wrongContent(.text).chipLine == "Not a text file")
    }

    @Test("A file of unknown type is read only when it looks like text")
    func unknownType() async throws {
        let text = try await read(file("notes.zzq", text: "plain words in an odd file"))
        #expect(text.text == "plain words in an odd file")
        #expect(text.kindLabel == "Text")

        var binary = Data([0x00, 0x01, 0x02, 0xFF])
        binary.append(contentsOf: Data(repeating: 0, count: 64))
        #expect(await failure(file("blob.zzq", binary)) == .unsupported(".zzq files cannot be read."))
    }

    // MARK: HTML

    @Test("HTML drops nav, script, and style, and leads with its title")
    func html() async throws {
        let page = """
        <html><head><title>Sample Page &amp; Title</title><style>body { color: black }</style>
        <script>var secret = 1;</script></head><body><nav>Menu Home About</nav>
        <article><h1>Heading</h1><p>Paragraph with café 中文.</p><ul><li>Alpha</li><li>Beta</li></ul></article>
        </body></html>
        """
        let result = try await read(file("page.html", text: page))
        let text = try #require(result.text)
        #expect(text.hasPrefix("Sample Page & Title\n\n"))
        #expect(text.contains("Heading"))
        #expect(text.contains("Paragraph with café 中文."))
        #expect(text.contains("- Alpha"))
        #expect(!text.contains("Menu Home About"))
        #expect(!text.contains("secret"))
        #expect(!text.contains("color"))
        #expect(result.ref.kind == .html)
    }

    @Test("HTML in GB18030 is decoded from its meta charset")
    func htmlCharset() async throws {
        let gbEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let page = "<html><head><meta charset=\"gb2312\"><title>报告</title></head><body><p>收入增长</p></body></html>"
        let result = try await read(file("gb.html", try #require(page.data(using: gbEncoding))))
        #expect(result.text == "报告\n\n收入增长")
    }

    // MARK: Word

    @Test("docx: paragraphs, tabs, breaks, a table as tab-separated rows, a text box once")
    func docx() async throws {
        let data = AttachmentFixtures.docx(
            paragraphs: [AttachmentFixtures.english, AttachmentFixtures.accents, AttachmentFixtures.chinese],
            table: [["Item", "Cost"], ["Rent", "1200"]],
            textBox: "Boxed words"
        )
        let result = try await read(file("report.docx", data))
        let lines = try #require(result.text).components(separatedBy: "\n")
        #expect(lines == [
            AttachmentFixtures.english,
            AttachmentFixtures.accents,
            AttachmentFixtures.chinese,
            "Item\tCost",
            "Rent\t1200",
            "Boxed words",
            "Tab\tafter",
            "Broken line",
        ])
        #expect(result.ref.kind == .word)
        #expect(result.kindLabel == "Word document")
    }

    @Test("A docx written by AppKit reads through the ZIP path")
    func docxFromAppKit() async throws {
        let text = "\(AttachmentFixtures.english)\n\(AttachmentFixtures.accents)\n\(AttachmentFixtures.chinese)"
        let data = AttachmentFixtures.attributed(text, type: .officeOpenXML)
        let result = try await read(file("appkit.docx", data))
        #expect(result.text == text)
    }

    @Test("doc, rtf, and odt read with their explicit type")
    func attributedFormats() async throws {
        let text = "\(AttachmentFixtures.english)\n\(AttachmentFixtures.accents)\n\(AttachmentFixtures.chinese)"
        for (name, type) in [
            ("sample.doc", NSAttributedString.DocumentType.docFormat),
            ("sample.rtf", .rtf),
            ("sample.odt", .openDocument),
        ] {
            let result = try await read(file(name, AttachmentFixtures.attributed(text, type: type)))
            #expect(result.text == text, "\(name)")
            #expect(result.ref.kind == .word, "\(name)")
        }
    }

    @Test("A .doc saved as RTF reads as RTF")
    func docThatIsRTF() async throws {
        let data = AttachmentFixtures.attributed(AttachmentFixtures.english, type: .rtf)
        #expect(try await read(file("old.doc", data)).text == AttachmentFixtures.english)
    }

    // MARK: PowerPoint

    @Test("pptx: slides follow sldIdLst when files are renumbered; notes sit under their slide")
    func pptxOrder() async throws {
        let data = AttachmentFixtures.pptx([
            .init(lines: ["Opening", "Agenda"], notes: ["Say hello"], fileNumber: 3),
            .init(lines: ["中文 slide"], fileNumber: 1),
            .init(lines: ["Close"], notes: ["Thank everyone"], fileNumber: 2),
        ])
        let result = try await read(file("deck.pptx", data))
        #expect(result.text == """
            --- Slide 1 ---
            Opening
            Agenda
            Notes:
            Say hello

            --- Slide 2 ---
            中文 slide

            --- Slide 3 ---
            Close
            Notes:
            Thank everyone
            """)
        #expect(result.ref.pageCount == 3)
        #expect(result.ref.kind == .powerpoint)
    }

    @Test("pptx without presentation.xml orders slides by number: slide10 after slide9")
    func pptxNumericFallback() async throws {
        let slides = (1...10).reversed().map { AttachmentFixtures.Slide(lines: ["Slide file \($0)"], fileNumber: $0) }
        let result = try await read(file("loose.pptx", AttachmentFixtures.pptx(slides, withPresentation: false)))
        let text = try #require(result.text)
        let nine = try #require(text.range(of: "Slide file 9"))
        let ten = try #require(text.range(of: "Slide file 10"))
        #expect(nine.lowerBound < ten.lowerBound)
        #expect(text.hasPrefix("--- Slide 1 ---\nSlide file 1\n"))
    }

    @Test("More slides than the cap: the first 300 are read, and the cut is said")
    func slideCap() async throws {
        let slides = (1...301).map { AttachmentFixtures.Slide(lines: ["S\($0)"], fileNumber: $0) }
        let result = try await read(file("long.pptx", AttachmentFixtures.pptx(slides)))
        #expect(result.ref.truncation == AttachmentTruncation(unit: .slide, keptUnits: 300, totalUnits: 301))
        #expect(result.ref.truncation?.summary == "slides 1-300 of 301")
        #expect(result.text?.contains("S300") == true)
        #expect(result.text?.contains("S301") == false)
    }

    // MARK: Excel

    @Test("xlsx: cells by reference, shared and inline strings, booleans, cached formulas, dates")
    func xlsx() async throws {
        let result = try await read(file("costs.xlsx", AttachmentFixtures.xlsx()))
        #expect(result.text == """
            --- Sheet "Costs" ---
            Item\tCost
            Rent\t1200
            Café\t120
            Inline\tTRUE
            Due\t\t2023-03-15

            --- Sheet "Notes" ---
            45000
            """)
        #expect(result.notes == [.spreadsheetSerialDates])
        #expect(result.notes.first?.modelLine == "[Dates may appear as spreadsheet serial numbers.]")
        #expect(result.ref.pageCount == 2)
        #expect(result.kindLabel == "Excel workbook")
    }

    @Test("A sheet over 5,000 rows keeps the first 5,000 and says so")
    func rowCap() async throws {
        let result = try await read(file("long.xlsx", AttachmentFixtures.xlsx(extraRows: 5_000)))
        let text = try #require(result.text)
        #expect(text.contains("[First 5,000 of 5,005 rows.]"))
        #expect(result.ref.truncation?.summary == "rows 1-5,000 of 5,005")
        let costsRows = text.components(separatedBy: "--- Sheet \"Notes\" ---")[0]
            .split(separator: "\n").filter { !$0.hasPrefix("---") && !$0.hasPrefix("[") }
        #expect(costsRows.count == 5_000)
    }

    @Test("A worksheet cut short mid-row keeps the rows before the cut")
    func cutWorksheet() throws {
        let rows = (1...50).map { "<row r=\"\($0)\"><c r=\"A\($0)\" t=\"inlineStr\"><is><t>Row \($0)</t></is></c></row>" }
        let xml = "<worksheet><dimension ref=\"A1:A50\"/><sheetData>" + rows.joined() + "</sheetData></worksheet>"
        let cut = Data(xml.utf8).prefix(xml.utf8.count / 2)
        let parsed = try SheetParser.parse(cut, sharedStrings: [], styles: .empty, date1904: false)
        #expect(parsed.rows.first == "Row 1")
        #expect(parsed.rows.count > 10 && parsed.rows.count < 50)
        #expect(parsed.totalRows == 50)
    }

    @Test("Serial dates for the built-in formats, in both date systems")
    func serialDates() {
        #expect(SerialDate.string(45_000, format: 14, date1904: false) == "2023-03-15")
        #expect(SerialDate.string(45_000.5, format: 22, date1904: false) == "2023-03-15 12:00")
        #expect(SerialDate.string(0.75, format: 20, date1904: false) == "18:00")
        #expect(SerialDate.string(1, format: 14, date1904: false) == "1900-01-01")
        #expect(SerialDate.string(0, format: 14, date1904: true) == "1904-01-01")
        #expect(StylesParser.isDateFormat("dd/mm/yyyy"))
        #expect(!StylesParser.isDateFormat("#,##0.00"))
        #expect(!StylesParser.isDateFormat("\"day\" 0"))
        #expect(CellReference.column("A1") == 0)
        #expect(CellReference.column("AB12") == 27)
        #expect(CellReference.row("AB12") == 12)
    }

    // MARK: PDF

    @Test("A text PDF reads page by page with markers")
    func textPDF() async throws {
        let data = AttachmentFixtures.textPDF(pages: [
            "\(AttachmentFixtures.english)\n\(AttachmentFixtures.accents)",
            "Second page words, long enough to count as text",
        ])
        let result = try await read(file("report.pdf", data))
        let text = try #require(result.text)
        #expect(text.hasPrefix("--- Page 1 ---\n"))
        #expect(text.contains(AttachmentFixtures.english))
        #expect(text.contains("Café crème"))
        #expect(text.contains("--- Page 2 ---\nSecond page words, long enough"))
        #expect(result.ref.pageCount == 2)
        #expect(result.ref.kind == .pdf)
        #expect(result.notes.isEmpty)
    }

    @Test("A PDF over 300 pages reads the first 300 and says so")
    func pageCap() async throws {
        let pages = (1...305).map { "Page body number \($0) with enough words to be text." }
        let result = try await read(file("long.pdf", AttachmentFixtures.textPDF(pages: pages)))
        #expect(result.ref.pageCount == 305)
        #expect(result.ref.truncation == AttachmentTruncation(unit: .page, keptUnits: 300, totalUnits: 305))
        #expect(result.ref.truncation?.summary == "pages 1-300 of 305")
        #expect(result.text?.contains("number 300 ") == true)
        #expect(result.text?.contains("number 301 ") == false)
    }

    @Test("A locked PDF is refused, not read")
    func lockedPDF() async throws {
        let url = file("locked.pdf", AttachmentFixtures.encryptedPDF())
        #expect(await failure(url) == .passwordProtected)
        #expect(AttachmentFailure.passwordProtected.chipLine == "Password-protected; not read")
    }

    @Test("A scanned PDF runs OCR on at most 10 pages, and the notes say which")
    func scannedPDFOCRCap() async throws {
        let recognizer = FakeRecognizer()
        let pages = (1...12).map { "Scanned page \($0)" }
        let phases = PhaseLog()
        let url = file("scan.pdf", AttachmentFixtures.scannedPDF(pages: pages))
        let result = try await extractor(recognizer: recognizer).extract(fileAt: url, progress: phases.handler)

        #expect(recognizer.count == AttachmentLimits.ocrPages)
        #expect(result.notes == [.ocr(pages: Array(1...10), totalPages: 12)])
        #expect(result.chipNotes == ["OCR · pages 1-10 of 12"])
        #expect(result.notes.first?.modelLine == "[Scanned PDF: text read by OCR on this Mac, pages 1-10 of 12.]")
        #expect(result.text?.contains("--- Page 10 ---\nRecognized text") == true)
        #expect(phases.all.contains(.recognizingText(page: 10, of: 10)))
        #expect(!phases.all.contains(.recognizingText(page: 11, of: 10)))
    }

    @Test("A scanned PDF where OCR finds nothing says so")
    func scannedEmpty() async throws {
        let url = file("blank-scan.pdf", AttachmentFixtures.scannedPDF(pages: ["x"]))
        #expect(await failure(url, with: extractor(recognizer: FakeRecognizer(reply: ""))) == .scannedNoText)
        #expect(AttachmentFailure.scannedNoText.chipLine == "No text found (scanned, OCR empty)")
    }

    @Test("Real OCR reads a scanned page on this Mac")
    func realOCR() async throws {
        let url = file("real-scan.pdf", AttachmentFixtures.scannedPDF(pages: ["Quarterly revenue grew"]))
        let result = try await AttachmentExtractor(linkReader: LinkAttachmentReader(remoteRead: nil))
            .extract(fileAt: url)
        #expect(result.text?.localizedCaseInsensitiveContains("revenue") == true)
        #expect(result.notes == [.ocr(pages: [1], totalPages: 1)])
    }

    // MARK: Images

    @Test("An image is scaled to 2,048 px, re-encoded, and keeps no source")
    func image() async throws {
        let picture = AttachmentFixtures.textImage("Chart", width: 3_000, height: 1_000)
        let result = try await read(file("chart.png", AttachmentFixtures.png(picture)))
        let image = try #require(result.image)
        #expect(image.pixelWidth == 2_048)
        #expect(image.pixelHeight == 683)
        #expect(image.mimeType == "image/png")
        #expect(result.text == nil)
        #expect(result.ref.kind == .image)
        #expect(result.ref.path == nil)
        #expect(result.ref.contentHash == nil)
        #expect(result.ref.pixelWidth == 2_048)
    }

    @Test("A small image keeps its size; a noisy one over 2 MB as PNG goes as JPEG")
    func imageEncoding() async throws {
        let small = AttachmentFixtures.textImage("Hi", width: 400, height: 300)
        let smallResult = try await read(file("small.png", AttachmentFixtures.png(small)))
        #expect(smallResult.image?.pixelWidth == 400)
        #expect(smallResult.image?.mimeType == "image/png")

        let side = 1_600
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in pixels.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let noise = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!.makeImage()!
        }
        let noisy = try await read(file("noise.png", AttachmentFixtures.png(noise)))
        #expect(noisy.image?.mimeType == "image/jpeg")
        #expect(noisy.image?.pixelWidth == side)
    }

    // MARK: Caps and cuts

    @Test("Over 200,000 characters: the head is kept and the cut is said twice")
    func characterCap() async throws {
        let text = String(repeating: "abcdefghij", count: 25_000)
        let result = try await read(file("long.txt", text: text))
        #expect(result.text?.count == AttachmentLimits.charactersPerAttachment)
        #expect(result.text == String(text.prefix(AttachmentLimits.charactersPerAttachment)))
        #expect(result.ref.characterCount == 250_000)
        #expect(result.ref.truncation?.summary == "first 200,000 of 250,000 characters")
        #expect(result.ref.truncation?.modelNote == "[Truncated: the first 200,000 of 250,000 characters.]")
        #expect(result.chipNotes == ["first 200,000 of 250,000 characters"])
    }

    @Test("A cut in a paged document names the pages it kept")
    func sectionCut() throws {
        let document = DocumentText(
            sections: (1...3).map { .init(marker: "--- Page \($0) ---", body: "0123456789") },
            sectionUnit: .page,
            unitCount: 300
        )
        let finished = try document.finished(characterCap: 30)
        #expect(finished.text == String("--- Page 1 ---\n0123456789\n\n--- Page 2 ---\n0123456789".prefix(30)))
        #expect(finished.characterCount == 3 * 25 + 2 * 2)
        #expect(finished.truncation?.summary == "first 30 of 79 characters, pages 1-2 of 300")
        #expect(throws: AttachmentFailure.empty) {
            try DocumentText(sections: [.init(marker: "--- Page 1 ---", body: "  \n")]).finished()
        }
    }

    @Test("Size caps per kind come from the file's metadata")
    func sizeCaps() async throws {
        let big = folder.appending(path: "big.pdf")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(AttachmentLimits.documentBytes + 1))
        try handle.close()
        #expect(await failure(big) == .tooLarge(limit: AttachmentLimits.documentBytes))
        #expect(AttachmentFailure.tooLarge(limit: AttachmentLimits.documentBytes).chipLine == "Larger than 50 MB")

        let text = folder.appending(path: "big.txt")
        FileManager.default.createFile(atPath: text.path, contents: nil)
        let textHandle = try FileHandle(forWritingTo: text)
        try textHandle.truncate(atOffset: UInt64(AttachmentLimits.textFileBytes + 1))
        try textHandle.close()
        #expect(await failure(text) == .tooLarge(limit: AttachmentLimits.textFileBytes))
        #expect(AttachmentFailure.tooLarge(limit: AttachmentLimits.textFileBytes).chipLine == "Larger than 5 MB")
    }

    @Test("A zip bomb named .pptx is refused with its own line")
    func bombFile() async throws {
        #expect(await failure(file("bomb.pptx", AttachmentFixtures.bombPPTX)) == .tooLargeUnpacked)
        #expect(await failure(file("lying.pptx", AttachmentFixtures.lyingBombPPTX)) == .tooLargeUnpacked)
    }

    // MARK: Wrong and unsupported kinds

    @Test("Content that is not what the name says is refused by name")
    func wrongContent() async throws {
        #expect(await failure(file("fake.docx", text: "not a zip at all")) == .wrongContent(.word))
        #expect(AttachmentFailure.wrongContent(.word).chipLine == "Not a Word document")
        #expect(await failure(file("fake.pdf", text: "plain text")) == .wrongContent(.pdf))
        #expect(await failure(file("fake.xlsx", text: "nope")) == .wrongContent(.excel))
        #expect(await failure(file("fake.rtf", text: "no rtf header")) == .wrongContent(.word))
        #expect(await failure(file("fake.png", text: "no pixels")) == .wrongContent(.image))

        var truncated = AttachmentFixtures.docx(paragraphs: ["Cut short"])
        truncated = truncated.prefix(truncated.count / 2)
        #expect(await failure(file("cut.docx", truncated)) == .damaged)
        #expect(AttachmentFailure.damaged.chipLine == "The file is damaged")
    }

    @Test("XML with a document type declaration is refused (no entity expansion)")
    func xmlEntities() async throws {
        let laughs = """
        <?xml version="1.0"?>
        <!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">]>
        <w:document xmlns:w="w"><w:body><w:p><w:r><w:t>&lol2;</w:t></w:r></w:p></w:body></w:document>
        """
        var zip = TestZipWriter()
        zip.add("word/document.xml", laughs)
        #expect(await failure(file("laughs.docx", zip.data())) == .damaged)

        #expect(XMLWalker.prologIsSafe(Data("<?xml version=\"1.0\"?>\n<!-- made by a tool --><root/>".utf8)))
        #expect(!XMLWalker.prologIsSafe(Data("<?xml version=\"1.0\"?><!-- c --><!DOCTYPE x><root/>".utf8)))
        #expect(!XMLWalker.prologIsSafe("<root/>".data(using: .utf16)!))
    }

    @Test("Before AppKit reads a docx, every entry passes the ZIP caps")
    func fallbackChecksWholeArchive() async throws {
        var zip = TestZipWriter()
        zip.add("word/document.xml", "<w:document xmlns:w=\"w\"><w:body/></w:document>")
        zip.addRepeated("word/media/image1.png", byte: 0, count: 40 * 1_024 * 1_024, declaredSize: 1_024)
        #expect(await failure(file("hidden-bomb.docx", zip.data())) == .tooLargeUnpacked)
    }

    @Test("An Office file wrapped in password encryption says it is protected")
    func encryptedOffice() async throws {
        var ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        ole.append(Data(repeating: 0, count: 512))
        #expect(await failure(file("secret.docx", ole)) == .passwordProtected)
        #expect(await failure(file("secret.xlsx", ole)) == .passwordProtected)
    }

    @Test("Keynote, Pages, Numbers, and old Office files are refused with a way out")
    func unsupportedKinds() async throws {
        #expect(await failure(file("talk.key", text: "x")) == .unsupported("Keynote files cannot be read. Export to PowerPoint or PDF."))
        let package = folder.appending(path: "Deck.key", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(await failure(package) == .unsupported("Keynote files cannot be read. Export to PowerPoint or PDF."))
        #expect(await failure(file("doc.pages", text: "x")) == .unsupported("Pages files cannot be read. Export to Word or PDF."))
        #expect(await failure(file("old.ppt", text: "x")) == .unsupported("Old PowerPoint files (.ppt) cannot be read. Save as .pptx or PDF."))
        #expect(await failure(file("bundle.zip", text: "x")) == .unsupported("Zip archives cannot be read. Attach the files inside."))
    }

    // MARK: The file gate

    @Test("A folder is refused; a missing file says so")
    func foldersAndMissing() async throws {
        let sub = folder.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(await failure(sub) == .folder)
        #expect(AttachmentFailure.folder.chipLine == "Folders cannot be attached; drop the files.")
        #expect(await failure(folder.appending(path: "gone.txt")) == .missing)
    }

    @Test("Symbolic links and Finder aliases resolve once, to a regular file")
    func linksAndAliases() async throws {
        let target = file("target.txt", text: "the real file")
        let link = folder.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let viaLink = try await read(link)
        #expect(viaLink.text == "the real file")
        #expect(viaLink.ref.path == target.resolvingSymlinksInPath().path)
        #expect(viaLink.ref.name == "link.txt")

        let alias = folder.appending(path: "alias to target")
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        #expect(try await read(alias).text == "the real file")

        let dangling = folder.appending(path: "dangling.txt")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: folder.appending(path: "nothing.txt"))
        #expect(await failure(dangling) == .missing)

        let dirLink = folder.appending(path: "dirlink")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: folder)
        #expect(await failure(dirLink) == .folder)
    }

    @Test("A file the user cannot read maps to the macOS access line")
    func accessDenied() async throws {
        let url = file("private.txt", text: "hidden")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        #expect(await failure(url) == .accessDenied)
        #expect(AttachmentFailure.accessDenied.chipLine == "macOS blocked access. Drop the file or use File…")
        let tcc = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        #expect(AttachmentFileGate.failure(for: tcc) == .accessDenied)
        #expect(AttachmentFileGate.failure(for: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) == .accessDenied)
    }

    @Test("An iCloud file downloads first; one that never arrives says so")
    func iCloud() async throws {
        let url = file("cloud.txt", text: "from iCloud")
        let polls = Mutex(0)
        let started = Mutex(0)
        let arriving = AttachmentFileGate(
            iCloudWait: .seconds(2),
            iCloudPoll: .milliseconds(10),
            iCloudState: { _ in polls.withLock { $0 += 1; return $0 < 4 ? .needsDownload : .local } },
            startDownload: { _ in started.withLock { $0 += 1 } }
        )
        let phases = PhaseLog()
        let result = try await extractor(gate: arriving).extract(fileAt: url, progress: phases.handler)
        #expect(result.text == "from iCloud")
        #expect(started.withLock { $0 } == 1)
        #expect(phases.all.first == .downloadingFromICloud)
        #expect(phases.all.contains(.reading))
        #expect(AttachmentReadPhase.downloadingFromICloud.chipLine == "Downloading from iCloud…")

        let never = AttachmentFileGate(
            iCloudWait: .milliseconds(80),
            iCloudPoll: .milliseconds(10),
            iCloudState: { _ in .needsDownload },
            startDownload: { _ in }
        )
        #expect(await failure(url, with: extractor(gate: never)) == .notDownloaded)
        #expect(AttachmentFailure.notDownloaded.chipLine == "Not downloaded")
    }

    // MARK: Time and cancellation

    @Test("A read over the time limit stops with its line")
    func timeout() async throws {
        let url = file("slow-scan.pdf", AttachmentFixtures.scannedPDF(pages: ["slow"]))
        let slow = extractor(recognizer: FakeRecognizer(delay: .seconds(5)), timeout: .milliseconds(200))
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await failure(url, with: slow) == .timedOut)
        #expect(start.duration(to: clock.now) < .seconds(3))
        #expect(AttachmentFailure.timedOut.chipLine == "Reading took too long")
    }

    @Test("Cancelling a read throws CancellationError, not a failure line")
    func cancellation() async throws {
        let url = file("cancel-scan.pdf", AttachmentFixtures.scannedPDF(pages: ["cancel"]))
        let slow = extractor(recognizer: FakeRecognizer(delay: .seconds(5)))
        let task = Task { try await slow.extract(fileAt: url) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: Copy

    @Test("Failure and note lines are short and carry no em dash")
    func copyRules() {
        let failures: [AttachmentFailure] = [
            .passwordProtected, .damaged, .scannedNoText, .tooLarge(limit: AttachmentLimits.documentBytes),
            .tooLargeUnpacked, .notDownloaded, .accessDenied, .missing, .wrongContent(.word), .empty, .folder,
            .notRegularFile, .unsupported(AttachmentFileGate.unsupportedLine(for: URL(fileURLWithPath: "/a.key"))),
            .timedOut, .unreadable, .invalidLink, .redirectRefused, .tooManyRedirects, .httpStatus(404),
            .linkContentType("ZIP"), .unreachable,
        ]
        var lines = failures.map(\.chipLine)
        lines += [
            AttachmentNote.ocr(pages: [1, 2], totalPages: 9), .spreadsheetSerialDates, .linkBodyCut(limitBytes: 5_242_880),
        ].flatMap { [$0.chipLine, $0.modelLine].compactMap { $0 } }
        for line in lines {
            #expect(!line.contains("\u{2014}"), "\(line)")
            #expect(line.count <= 80, "\(line)")
        }
        #expect(AttachmentFailure.empty.chipLine == "No readable text")
    }
}

// MARK: - Timing

/// The proof for this package: one extraction per fixture kind, timed, and
/// printed as a table next to the numbers measured on this Mac for the spec
/// (section 2). Each must stay inside that order of magnitude.
@Suite("Attachment extraction timing", .serialized)
struct AttachmentTimingTests {
    private struct Row {
        let kind: String
        let reference: Double
        let measured: Double
    }

    @Test("Timing table per fixture kind")
    func timingTable() async throws {
        let folder = AttachmentFixtures.folder("timing")
        let extractor = AttachmentExtractor(linkReader: LinkAttachmentReader(remoteRead: nil))
        let text = "\(AttachmentFixtures.english)\n\(AttachmentFixtures.accents)\n\(AttachmentFixtures.chinese)"
        let html = "<html><head><title>T</title></head><body><nav>Menu</nav><article><p>\(text)</p><ul><li>Alpha</li></ul></article></body></html>"
        let slides = (1...12).map { AttachmentFixtures.Slide(lines: ["Slide \($0) \(text)"], notes: ["Note \($0)"], fileNumber: $0) }

        // (kind, file name, bytes, reference ms from section 2, runs). Section 2
        // has no row for re-encoding an image; its 50 ms is this test's own.
        let fixtures: [(String, String, Data, Double, Int)] = [
            ("txt", "t.txt", Data(text.utf8), 1.0, 3),
            ("html", "t.html", Data(html.utf8), 1.0, 3),
            ("docx", "t.docx", AttachmentFixtures.docx(paragraphs: [text], table: [["a", "b"]]), 0.1, 3),
            ("docx (AppKit)", "a.docx", AttachmentFixtures.attributed(text, type: .officeOpenXML), 1.7, 3),
            ("doc", "t.doc", AttachmentFixtures.attributed(text, type: .docFormat), 18, 3),
            ("rtf", "t.rtf", AttachmentFixtures.attributed(text, type: .rtf), 18, 3),
            ("odt", "t.odt", AttachmentFixtures.attributed(text, type: .openDocument), 18, 3),
            ("pptx, 12 slides", "t.pptx", AttachmentFixtures.pptx(slides), 0.8, 3),
            ("xlsx", "t.xlsx", AttachmentFixtures.xlsx(), 0.2, 3),
            ("pdf, 1 page", "t.pdf", AttachmentFixtures.textPDF(pages: [text]), 28, 3),
            ("pdf, 300 pages", "big.pdf", AttachmentFixtures.textPDF(pages: (1...300).map { "Page \($0) \(text)" }), 261, 2),
            ("pdf, encrypted", "locked.pdf", AttachmentFixtures.encryptedPDF(), 0.1, 3),
            ("pdf, scanned (OCR)", "scan.pdf", AttachmentFixtures.scannedPDF(pages: ["Quarterly revenue grew"]), 228, 2),
            ("zip bomb", "bomb.pptx", AttachmentFixtures.lyingBombPPTX, 2.6, 3),
            ("png (no spec row)", "shot.png", AttachmentFixtures.png(AttachmentFixtures.textImage("Screen", width: 1_944, height: 1_464)), 50, 3),
        ]

        var rows: [Row] = []
        for (kind, name, data, reference, runs) in fixtures {
            let url = AttachmentFixtures.write(data, named: name, in: folder)
            var best = Double.infinity
            for _ in 0..<runs {
                let clock = ContinuousClock()
                let start = clock.now
                _ = try? await extractor.extract(fileAt: url)
                let elapsed = start.duration(to: clock.now)
                best = min(best, Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
            }
            rows.append(Row(kind: kind, reference: reference, measured: best))
        }

        var table = "Attachment extraction timing (best run, ms)\n"
        table += "kind                   spec    here   bound\n"
        for row in rows {
            let bound = max(row.reference * 10, 50)
            table += row.kind.padding(toLength: 20, withPad: " ", startingAt: 0)
                + String(format: " %7.1f %7.1f %7.0f\n", row.reference, row.measured, bound)
        }
        print(table)
        let proofDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
        try? FileManager.default.createDirectory(at: proofDir, withIntermediateDirectories: true)
        try? table.write(to: proofDir.appending(path: "a-timing-table.txt"), atomically: true, encoding: .utf8)

        for row in rows {
            #expect(row.measured < max(row.reference * 10, 50), "\(row.kind): \(row.measured) ms")
        }
    }
}
