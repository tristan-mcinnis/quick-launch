import CoreGraphics
import CryptoKit
import Foundation
import HouseChatCore
import Testing
@testable import HouseChatDocuments

/// Counts OCR calls, optionally slowly, and answers with canned text.
actor FakeOCR {
    private(set) var count = 0
    private let reply: String
    private let delay: Duration

    init(reply: String = "Recognized text from a scanned page of the report.", delay: Duration = .zero) {
        self.reply = reply
        self.delay = delay
    }

    func recognize(_ image: CGImage) async -> String {
        count += 1
        if delay > .zero { try? await Task.sleep(for: delay) }
        return reply
    }

    nonisolated var recognizer: DocumentTextRecognizer {
        { [self] image in await recognize(image) }
    }
}

/// A thread-safe log for the synchronous progress handler.
final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [DocumentReadPhase] = []

    var all: [DocumentReadPhase] {
        lock.lock(); defer { lock.unlock() }
        return phases
    }

    var handler: DocumentProgressHandler {
        { [self] phase in
            lock.lock(); defer { lock.unlock() }
            phases.append(phase)
        }
    }
}

@Suite("HouseChatDocuments extraction")
struct DocumentExtractorTests {
    private let folder = Fixtures.folder("extract")

    private func extractor(
        configuration: DocumentExtractionConfiguration = .standard,
        recognizer: FakeOCR = FakeOCR()
    ) -> DocumentExtractor {
        DocumentExtractor(configuration: configuration, recognizeText: recognizer.recognizer)
    }

    private func file(_ name: String, _ data: Data) -> URL {
        Fixtures.write(data, named: name, in: folder)
    }

    private func file(_ name: String, text: String) -> URL {
        file(name, Data(text.utf8))
    }

    private func read(
        _ url: URL,
        with extractor: DocumentExtractor? = nil
    ) async throws -> DocumentExtraction {
        try await (extractor ?? self.extractor()).extract(fileURL: url)
    }

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

    // MARK: Text, Markdown, code

    @Test("A text file keeps English, accents, and Chinese, with a schema record")
    func plainText() async throws {
        let text = [Fixtures.english, Fixtures.accents, Fixtures.chinese].joined(separator: "\n")
        let bytes = Data(text.utf8)
        let url = file("notes.txt", bytes)
        let result = try await read(url)

        #expect(result.document.text == text)
        #expect(result.document.kindLabel == "Text")
        #expect(result.document.kind == .text)
        #expect(result.document.name == "notes.txt")
        #expect(result.document.path == url.resolvingSymlinksInPath().path)
        #expect(result.document.characterCount == text.count)
        #expect(result.document.byteCount == bytes.count)
        #expect(result.document.extractorVersion == DocumentExtractor.version)
        #expect(result.document.sections.count == 1)
        #expect(result.document.truncation == nil)
        #expect(result.isComplete)

        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(result.document.contentHash == expected)
        #expect(result.originalBytes == bytes)
        #expect(result.source.kind == .file)
        #expect(result.source.fileURL == url.resolvingSymlinksInPath())
        #expect(result.normalizedImage == nil)
    }

    @Test("NFKC turns the Kangxi radical U+2F42 into 文 in text, never in code")
    func nfkc() async throws {
        let raw = "中\u{2F42} ｗｉｄｅ ﬁle"
        let text = try await read(file("kangxi.md", text: raw))
        #expect(text.document.text == "中文 wide file")
        #expect(text.document.kind == .markdown)

        let code = try await read(file("kangxi.swift", text: "let s = \"\(raw)\"\r\n"))
        #expect(code.document.text == "let s = \"\(raw)\"")
        #expect(code.document.kind == .code)
        #expect(code.document.kindLabel == "Swift source")
    }

    @Test("A NUL byte near the start means not a text file")
    func binaryText() async throws {
        var binary = Data("looks like text".utf8)
        binary.append(0)
        binary.append(contentsOf: Data("then a NUL".utf8))
        #expect(await failure { try await read(self.file("nul.txt", binary)) } == .wrongContent(.text))
        #expect(DocumentExtractionError.wrongContent(.text).message == "Not a text file")
    }

    @Test("A file of unknown type is read only when it looks like text")
    func unknownType() async throws {
        let text = try await read(file("notes.zzq", text: "plain words in an odd file"))
        #expect(text.document.text == "plain words in an odd file")

        var binary = Data([0x00, 0x01, 0x02, 0xFF])
        binary.append(contentsOf: Data(repeating: 0, count: 64))
        #expect(await failure { try await read(self.file("blob.zzq", binary)) } == .unsupported(".zzq files cannot be read."))
    }

    // MARK: HTML and fetched bodies

    @Test("HTML drops nav, script, and style, and leads with its title")
    func html() async throws {
        let page = """
        <html><head><title>Sample Page &amp; Title</title><style>body { color: black }</style>
        <script>var secret = 1;</script></head><body><nav>Menu Home About</nav>
        <article><h1>Heading</h1><p>Paragraph with café 中文.</p><ul><li>Alpha</li><li>Beta</li></ul></article>
        </body></html>
        """
        let result = try await read(file("page.html", text: page))
        let text = try #require(result.document.text)
        #expect(text.hasPrefix("Sample Page & Title\n\n"))
        #expect(text.contains("Heading"))
        #expect(text.contains("Paragraph with café 中文."))
        #expect(text.contains("- Alpha"))
        #expect(!text.contains("Menu Home About"))
        #expect(!text.contains("secret"))
        #expect(result.document.kind == .html)
        #expect(result.document.kindLabel == "HTML file")
    }

    @Test("A fetched body keeps its bytes and records the source URL")
    func fetchedBody() async throws {
        let body = Data("<html><head><title>Fetched</title></head><body><p>Remote words.</p></body></html>".utf8)
        let url = URL(string: "https://example.com/article")!
        let result = try await extractor().extract(data: body, name: "article.html", sourceURL: url)

        #expect(result.source.kind == .fetchedBody)
        #expect(result.source.url == url)
        #expect(result.document.kind == .link)
        #expect(result.document.kindLabel == "Web page")
        #expect(result.document.url == url)
        #expect(result.document.path == nil)
        #expect(result.originalBytes == body)
        #expect(result.isComplete)
    }

    @Test("A fetched body the caller cut says the page was partial")
    func partialFetchedBody() async throws {
        let body = Data("<html><body><p>Head of a long page.</p></body></html>".utf8)
        let result = try await extractor().extract(
            data: body,
            name: "article.html",
            sourceURL: URL(string: "https://example.com/big")!,
            bodyWasTruncated: true
        )
        #expect(result.document.notes.contains { $0.kind == .linkBodyCut })
        #expect(result.isComplete == false)
    }

    // MARK: Word

    @Test("docx: paragraphs, tabs, breaks, and a table as tab-separated rows")
    func docx() async throws {
        let data = Fixtures.docx(
            paragraphs: [Fixtures.english, Fixtures.accents, Fixtures.chinese],
            table: [["Item", "Cost"], ["Rent", "1200"]],
            textBox: "Boxed words"
        )
        let result = try await read(file("report.docx", data))
        let lines = try #require(result.document.text).components(separatedBy: "\n")
        #expect(lines == [
            Fixtures.english,
            Fixtures.accents,
            Fixtures.chinese,
            "Item\tCost",
            "Rent\t1200",
            "Boxed words",
            "Tab\tafter",
            "Broken line",
        ])
        #expect(result.document.kind == .word)
        #expect(result.document.kindLabel == "Word document")
        #expect(result.originalBytes == data)
    }

    // MARK: PowerPoint

    @Test("pptx: slides carry a label, unit, index, and range, notes under their slide")
    func pptx() async throws {
        let data = Fixtures.pptx([
            .init(lines: ["Opening", "Agenda"], notes: ["Say hello"], fileNumber: 3),
            .init(lines: ["中文 slide"], fileNumber: 1),
            .init(lines: ["Close"], notes: ["Thank everyone"], fileNumber: 2),
        ])
        let result = try await read(file("deck.pptx", data))
        #expect(result.document.text == """
            Opening
            Agenda
            Notes:
            Say hello

            中文 slide

            Close
            Notes:
            Thank everyone
            """)
        #expect(result.document.sectionUnit == .slide)
        #expect(result.document.unitCount == 3)
        #expect(result.document.sections.map(\.label) == ["Slide 1", "Slide 2", "Slide 3"])
        #expect(result.document.sections.allSatisfy { $0.unit == .slide })
        #expect(result.document.sections.first?.index == 1)
        #expect(result.document.sections.first?.range == DocumentRange(start: 1, end: 1))
        #expect(result.document.kind == .powerpoint)
    }

    @Test("More slides than the cap: the first are read and the cut is said")
    func slideCap() async throws {
        let slides = (1...4).map { Fixtures.Slide(lines: ["S\($0)"], fileNumber: $0) }
        var configuration = DocumentExtractionConfiguration.standard
        configuration.slideLimit = 2
        let result = try await read(file("long.pptx", Fixtures.pptx(slides)), with: extractor(configuration: configuration))

        #expect(result.document.truncation == TextTruncation(unit: .slide, keptUnits: 2, totalUnits: 4))
        #expect(result.document.truncation?.summary == "slides 1-2 of 4")
        #expect(result.document.unitCut == DocumentUnitCut(unit: .slide, kept: 2, total: 4))
        #expect(result.isComplete == false)
        #expect(result.document.text?.contains("S2") == true)
        #expect(result.document.text?.contains("S3") == false)
    }

    // MARK: Excel

    @Test("xlsx: cells by reference, shared and inline strings, booleans, cached formulas, dates")
    func xlsx() async throws {
        let result = try await read(file("costs.xlsx", Fixtures.xlsx()))
        #expect(result.document.text == """
            Item\tCost
            Rent\t1200
            Café\t120
            Inline\tTRUE
            Due\t\t2023-03-15

            45000
            """)
        #expect(result.document.sections.map(\.label) == ["Sheet \"Costs\"", "Sheet \"Notes\""])
        #expect(result.document.sections.allSatisfy { $0.unit == .sheet })
        #expect(result.document.unitCount == 2)
        #expect(result.document.notes == [.spreadsheetSerialDates])
        #expect(result.document.kindLabel == "Excel workbook")
    }

    @Test("A sheet over the row cap keeps the first rows and says so")
    func rowCap() async throws {
        var configuration = DocumentExtractionConfiguration.standard
        configuration.rowLimit = 3
        let result = try await read(file("long.xlsx", Fixtures.xlsx()), with: extractor(configuration: configuration))
        let text = try #require(result.document.text)
        #expect(text.contains("[First 3 of 5 rows.]"))
        #expect(result.document.truncation?.summary == "rows 1-3 of 5")
        #expect(result.isComplete == false)
    }

    // MARK: PDF

    @Test("A text PDF reads page by page with a location per page")
    func textPDF() async throws {
        let data = Fixtures.textPDF(pages: [
            "\(Fixtures.english)\n\(Fixtures.accents)",
            "Second page words, long enough to count as text",
        ])
        let result = try await read(file("report.pdf", data))
        let text = try #require(result.document.text)
        #expect(text.hasPrefix(Fixtures.english))
        #expect(text.contains("Second page words, long enough"))
        #expect(result.document.sections.count == 2)
        #expect(result.document.sections.map(\.label) == ["Page 1", "Page 2"])
        #expect(result.document.sections.allSatisfy { $0.unit == .page })
        #expect(result.document.unitCount == 2)
        #expect(result.document.kind == .pdf)
        #expect(result.document.notes.isEmpty)
    }

    @Test("A PDF over the page cap reads the first pages and says so")
    func pageCap() async throws {
        let pages = (1...3).map { "Page body number \($0) with enough words to be text." }
        var configuration = DocumentExtractionConfiguration.standard
        configuration.pdfPageLimit = 1
        let result = try await read(file("long.pdf", Fixtures.textPDF(pages: pages)), with: extractor(configuration: configuration))
        #expect(result.document.unitCount == 3)
        #expect(result.document.truncation == TextTruncation(unit: .page, keptUnits: 1, totalUnits: 3))
        #expect(result.document.text?.contains("number 1 ") == true)
        #expect(result.document.text?.contains("number 2 ") == false)
    }

    @Test("A locked PDF is refused, not read")
    func lockedPDF() async throws {
        let url = file("locked.pdf", Fixtures.encryptedPDF())
        #expect(await failure { try await self.read(url) } == .passwordProtected)
        #expect(DocumentExtractionError.passwordProtected.message == "Password-protected; not read")
    }

    @Test("A scanned PDF runs OCR on at most the page cap, and the notes say which")
    func scannedPDFOCRCap() async throws {
        let recognizer = FakeOCR()
        let pages = (1...4).map { "Scanned page \($0)" }
        let phases = PhaseLog()
        var configuration = DocumentExtractionConfiguration.standard
        configuration.ocrPageLimit = 2
        let url = file("scan.pdf", Fixtures.scannedPDF(pages: pages))
        let result = try await extractor(configuration: configuration, recognizer: recognizer)
            .extract(fileURL: url, progress: phases.handler)

        #expect(await recognizer.count == 2)
        #expect(result.document.notes == [.ocr(pages: [1, 2], totalPages: 4)])
        #expect(result.document.notes.first?.modelLine == "[Scanned PDF: text read by OCR on this Mac, pages 1-2 of 4.]")
        #expect(result.document.text?.hasPrefix("Recognized text") == true)
        #expect(phases.all.contains(.recognizingText(page: 2, of: 2)))
        #expect(!phases.all.contains(.recognizingText(page: 3, of: 2)))

        // Pages 3-4 were skipped by the OCR cap: the record reports it instead
        // of claiming the whole scan was read.
        #expect(result.document.sections.count == 2)
        #expect(result.document.unitCut == nil)
        #expect(result.document.truncation?.coveredUnits == [1, 2])
        #expect(result.document.truncation?.totalUnits == 4)
        #expect(result.document.truncation?.summary == "pages 1-2 of 4")
        #expect(result.limitSummary == "pages 1-2 of 4")
        #expect(result.isComplete == false)
    }

    @Test("A scanned PDF where OCR finds nothing says so")
    func scannedEmpty() async throws {
        let url = file("blank-scan.pdf", Fixtures.scannedPDF(pages: ["x"]))
        let empty = extractor(recognizer: FakeOCR(reply: ""))
        #expect(await failure { try await empty.extract(fileURL: url) } == .scannedNoText)
        #expect(DocumentExtractionError.scannedNoText.message == "No text found (scanned, OCR empty)")
    }

    @Test("Real on-device OCR reads a scanned page through the macOS 14 Vision path")
    func realOCR() async throws {
        let url = file("real-scan.pdf", Fixtures.scannedPDF(pages: ["Quarterly revenue grew"]))
        let result = try await DocumentExtractor().extract(fileURL: url)
        #expect(result.document.text?.localizedCaseInsensitiveContains("revenue") == true)
        #expect(result.document.notes == [.ocr(pages: [1], totalPages: 1)])
    }

    // MARK: Caps and corrupt input

    @Test("Over the character cap: the head is kept and the cut is said")
    func characterCap() async throws {
        let text = String(repeating: "abcdefghij", count: 25)
        var configuration = DocumentExtractionConfiguration.standard
        configuration.maximumCharacters = 100
        let result = try await read(file("long.txt", text: text), with: extractor(configuration: configuration))

        #expect(result.document.text?.count == 100)
        #expect(result.document.text == String(text.prefix(100)))
        #expect(result.document.characterCount == 250)
        #expect(result.document.truncation?.summary == "first 100 of 250 characters")
        #expect(result.document.truncation?.modelNote == "[Truncated: the first 100 of 250 characters.]")
        #expect(result.isComplete == false)
        #expect(result.limitSummary == "first 100 of 250 characters")
    }

    @Test("Under the cap, a fact at the very end of a document is kept")
    func tailContent() async throws {
        let head = String(repeating: "filler ", count: 20)
        let text = head + "THE-TAIL-FACT"
        let result = try await read(file("tail.txt", text: text))
        #expect(result.document.text?.hasSuffix("THE-TAIL-FACT") == true)
        #expect(result.document.text?.contains("THE-TAIL-FACT") == true)
        #expect(result.document.truncation == nil)
    }

    @Test("A zip bomb named .pptx is refused with its own line")
    func zipBomb() async throws {
        #expect(await failure { try await self.read(self.file("bomb.pptx", Fixtures.bombPPTX)) } == .tooLargeUnpacked)
        let lying = file("lying.pptx", Fixtures.lyingBombPPTX)
        #expect(await failure { try await self.read(lying) } == .tooLargeUnpacked)
    }

    @Test("Content that is not what the name says is refused by name")
    func wrongContent() async throws {
        #expect(await failure { try await self.read(self.file("fake.docx", text: "not a zip at all")) } == .wrongContent(.word))
        #expect(await failure { try await self.read(self.file("fake.pdf", text: "plain text")) } == .wrongContent(.pdf))
        #expect(await failure { try await self.read(self.file("fake.xlsx", text: "nope")) } == .wrongContent(.excel))
        #expect(await failure { try await self.read(self.file("fake.rtf", text: "no rtf header")) } == .wrongContent(.word))
        #expect(await failure { try await self.read(self.file("fake.png", text: "no pixels")) } == .wrongContent(.image))

        var truncated = Fixtures.docx(paragraphs: ["Cut short"])
        truncated = truncated.prefix(truncated.count / 2)
        #expect(await failure { try await self.read(self.file("cut.docx", truncated)) } == .damaged)
    }

    @Test("An Office file wrapped in password encryption says it is protected")
    func encryptedOffice() async throws {
        var ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        ole.append(Data(repeating: 0, count: 512))
        #expect(await failure { try await self.read(self.file("secret.docx", ole)) } == .passwordProtected)
    }

    @Test("Unsupported kinds are refused with a way out")
    func unsupportedKinds() async throws {
        let expected = DocumentExtractionError.unsupported("Keynote files cannot be read. Export to PowerPoint or PDF.")
        #expect(await failure { try await self.read(self.file("talk.key", text: "x")) } == expected)
        #expect(await failure { try await self.read(self.file("bundle.zip", text: "x")) } == .unsupported("Zip archives cannot be read. Attach the files inside."))
    }

    // MARK: The file gate

    @Test("A folder is refused; a missing file says so")
    func foldersAndMissing() async throws {
        let sub = folder.appending(path: "sub", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(await failure { try await self.read(sub) } == .folder)
        #expect(await failure { try await self.read(self.folder.appending(path: "gone.txt")) } == .missing)
    }

    @Test("Size caps per kind come from the file's metadata")
    func sizeCaps() async throws {
        var configuration = DocumentExtractionConfiguration.standard
        configuration.maximumTextFileBytes = 64
        let big = file("big.txt", text: String(repeating: "x", count: 200))
        #expect(await failure { try await self.extractor(configuration: configuration).extract(fileURL: big) }
            == .tooLarge(limit: 64))
        #expect(DocumentExtractionError.tooLarge(limit: 64).message == "Larger than 0 MB")
    }

    // MARK: Time and cancellation

    @Test("A read over the time limit stops with its line")
    func timeout() async throws {
        var configuration = DocumentExtractionConfiguration.standard
        configuration.timeout = .milliseconds(60)
        let slow = extractor(configuration: configuration, recognizer: FakeOCR(delay: .seconds(5)))
        let url = file("slow-scan.pdf", Fixtures.scannedPDF(pages: ["slow"]))
        #expect(await failure { try await slow.extract(fileURL: url) } == .timedOut)
        #expect(DocumentExtractionError.timedOut.message == "Reading took too long")
    }

    @Test("Cancelling a read throws CancellationError, not a failure line")
    func cancellation() async throws {
        let slow = extractor(recognizer: FakeOCR(delay: .seconds(5)))
        let url = file("cancel-scan.pdf", Fixtures.scannedPDF(pages: ["cancel"]))
        let task = Task { try await slow.extract(fileURL: url) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: Progress

    @Test("A read reports its phases")
    func phases() async throws {
        let log = PhaseLog()
        let url = file("phases.txt", text: "hello phases")
        _ = try await extractor().extract(fileURL: url, progress: log.handler)
        #expect(log.all.contains(.reading))
        #expect(DocumentReadPhase.reading.message == "Reading…")
    }
}
