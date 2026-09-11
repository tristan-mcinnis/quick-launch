import AppKit
import Compression
import CoreText
import Foundation
import PDFKit
@testable import QuickLaunch

/// A tiny ZIP writer for tests: stored and deflated entries, and the knobs
/// a hostile archive needs (a lying size, the encryption flag, any name).
/// No binary fixture is committed; every archive is built here.
struct TestZipWriter {
    enum Method {
        case stored
        case deflated
    }

    private struct Written {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let offset: Int
    }

    private var body = Data()
    private var written: [Written] = []

    /// Adds one entry. `declaredSize` overrides the uncompressed size the
    /// headers claim; `encrypted` sets general-purpose flag bit 0.
    mutating func add(
        _ name: String,
        _ data: Data,
        method: Method = .deflated,
        declaredSize: Int? = nil,
        encrypted: Bool = false
    ) {
        let payload = method == .deflated ? Self.deflate(data) : data
        append(
            name: name,
            payload: payload,
            method: method == .deflated ? 8 : 0,
            crc: Self.crc32(data),
            uncompressedSize: declaredSize ?? data.count,
            flags: encrypted ? 0x0001 : 0
        )
    }

    mutating func add(_ name: String, _ text: String, method: Method = .deflated) {
        add(name, Data(text.utf8), method: method)
    }

    /// Adds a deflated entry of `count` copies of `byte`, compressed as a
    /// stream so the plain bytes never sit in memory. No CRC (the reader
    /// under test does not check it).
    mutating func addRepeated(_ name: String, byte: UInt8, count: Int, declaredSize: Int? = nil) {
        let chunk = Data(repeating: byte, count: 1_024 * 1_024)
        var compressed = Data()
        let filter = try! OutputFilter(.compress, using: .zlib) { output in
            if let output { compressed.append(output) }
        }
        var remaining = count
        while remaining > 0 {
            let size = min(remaining, chunk.count)
            try! filter.write(chunk.prefix(size))
            remaining -= size
        }
        try! filter.finalize()
        append(name: name, payload: compressed, method: 8, crc: 0, uncompressedSize: declaredSize ?? count, flags: 0)
    }

    private mutating func append(
        name: String,
        payload: Data,
        method: UInt16,
        crc: UInt32,
        uncompressedSize: Int,
        flags: UInt16
    ) {
        let nameBytes = Data(name.utf8)
        let offset = body.count
        var header = Data()
        header.le32(0x0403_4B50)
        header.le16(20)
        header.le16(flags | 0x0800)
        header.le16(method)
        header.le16(0)
        header.le16(0)
        header.le32(crc)
        header.le32(UInt32(payload.count))
        header.le32(UInt32(truncatingIfNeeded: uncompressedSize))
        header.le16(UInt16(nameBytes.count))
        header.le16(0)
        body.append(header)
        body.append(nameBytes)
        body.append(payload)
        written.append(Written(
            name: name,
            method: method,
            flags: flags | 0x0800,
            crc: crc,
            compressedSize: payload.count,
            uncompressedSize: uncompressedSize,
            offset: offset
        ))
    }

    /// The archive: local entries, central directory, end record.
    func data() -> Data {
        var output = body
        let directoryOffset = output.count
        for entry in written {
            let nameBytes = Data(entry.name.utf8)
            var record = Data()
            record.le32(0x0201_4B50)
            record.le16(20)
            record.le16(20)
            record.le16(entry.flags)
            record.le16(entry.method)
            record.le16(0)
            record.le16(0)
            record.le32(entry.crc)
            record.le32(UInt32(entry.compressedSize))
            record.le32(UInt32(truncatingIfNeeded: entry.uncompressedSize))
            record.le16(UInt16(nameBytes.count))
            record.le16(0)
            record.le16(0)
            record.le16(0)
            record.le16(0)
            record.le32(0)
            record.le32(UInt32(entry.offset))
            output.append(record)
            output.append(nameBytes)
        }
        let directorySize = output.count - directoryOffset
        var end = Data()
        end.le32(0x0605_4B50)
        end.le16(0)
        end.le16(0)
        end.le16(UInt16(truncatingIfNeeded: written.count))
        end.le16(UInt16(truncatingIfNeeded: written.count))
        end.le32(UInt32(directorySize))
        end.le32(UInt32(directoryOffset))
        end.le16(0)
        output.append(end)
        return output
    }

    /// Raw DEFLATE, as a ZIP entry holds it.
    static func deflate(_ data: Data) -> Data {
        var compressed = Data()
        let filter = try! OutputFilter(.compress, using: .zlib) { output in
            if let output { compressed.append(output) }
        }
        try! filter.write(data)
        try! filter.finalize()
        return compressed
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        guard data.count <= 1_024 * 1_024 else { return 0 }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func le32(_ value: UInt32) {
        le16(UInt16(value & 0xFFFF))
        le16(UInt16(value >> 16))
    }
}

// MARK: - Fixtures

/// Office, PDF, and image fixtures built in the test, never committed.
enum AttachmentFixtures {
    static let english = "Quarterly revenue grew in every region."
    static let accents = "Café crème, naïve résumé, Ærø."
    static let chinese = "中文测试 季度收入增长。"

    /// A folder of its own under the temporary directory.
    static func folder(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "quick-launch-attach-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ data: Data, named name: String, in folder: URL) -> URL {
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        try! data.write(to: url)
        return url
    }

    // MARK: Word

    static func docx(paragraphs: [String], table: [[String]] = [], textBox: String? = nil) -> Data {
        func run(_ text: String) -> String {
            "<w:r><w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r>"
        }
        var body = paragraphs.map { "<w:p><w:pPr><w:tabs><w:tab w:val=\"left\" w:pos=\"720\"/></w:tabs></w:pPr>\(run($0))</w:p>" }
            .joined()
        if !table.isEmpty {
            body += "<w:tbl>" + table.map { row in
                "<w:tr>" + row.map { "<w:tc><w:p>\(run($0))</w:p></w:tc>" }.joined() + "</w:tr>"
            }.joined() + "</w:tbl>"
        }
        if let textBox {
            body += """
            <w:p><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><w:txbxContent>\
            <w:p>\(run(textBox))</w:p></w:txbxContent></w:drawing></mc:Choice><mc:Fallback><w:pict>\
            <w:txbxContent><w:p>\(run(textBox))</w:p></w:txbxContent></w:pict></mc:Fallback>\
            </mc:AlternateContent></w:r></w:p>
            """
        }
        body += "<w:p><w:r><w:t>Tab</w:t><w:tab/><w:t>after</w:t><w:br/><w:t>Broken line</w:t></w:r></w:p>"
        var zip = TestZipWriter()
        zip.add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
        zip.add("_rels/.rels", """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
            </Relationships>
            """)
        zip.add("word/document.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
            xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><w:body>\(body)</w:body></w:document>
            """)
        return zip.data()
    }

    // MARK: PowerPoint

    struct Slide {
        var lines: [String]
        var notes: [String] = []
        /// The file number, so a test can renumber files against the order.
        var fileNumber: Int
    }

    /// A deck whose `sldIdLst` lists slides in array order, whatever their
    /// file numbers.
    static func pptx(_ slides: [Slide], withPresentation: Bool = true) -> Data {
        var zip = TestZipWriter()
        let p = "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\" "
            + "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        let relsNS = "xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\""
        let slideType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
        let notesType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide"
        if withPresentation {
            let ids = slides.enumerated().map { index, _ in
                "<p:sldId id=\"\(256 + index)\" r:id=\"rId\(index + 10)\"/>"
            }.joined()
            zip.add("ppt/presentation.xml", "<p:presentation \(p)><p:sldIdLst>\(ids)</p:sldIdLst></p:presentation>")
            let rels = slides.enumerated().map { index, slide in
                "<Relationship Id=\"rId\(index + 10)\" Type=\"\(slideType)\" Target=\"slides/slide\(slide.fileNumber).xml\"/>"
            }.joined()
            zip.add("ppt/_rels/presentation.xml.rels", "<Relationships \(relsNS)>\(rels)</Relationships>")
        }
        for slide in slides {
            let shapes = shape(slide.lines, placeholder: "title")
                + shape(["\(slide.fileNumber)"], placeholder: "sldNum")
            zip.add("ppt/slides/slide\(slide.fileNumber).xml", "<p:sld \(p)><p:cSld><p:spTree>\(shapes)</p:spTree></p:cSld></p:sld>")
            if !slide.notes.isEmpty {
                zip.add(
                    "ppt/slides/_rels/slide\(slide.fileNumber).xml.rels",
                    "<Relationships \(relsNS)><Relationship Id=\"rId2\" Type=\"\(notesType)\" Target=\"../notesSlides/notesSlide\(slide.fileNumber).xml\"/></Relationships>"
                )
                let notesShapes = shape([], placeholder: "sldImg")
                    + shape(slide.notes, placeholder: "body")
                    + shape(["\(slide.fileNumber)"], placeholder: "sldNum")
                zip.add(
                    "ppt/notesSlides/notesSlide\(slide.fileNumber).xml",
                    "<p:notes \(p)><p:cSld><p:spTree>\(notesShapes)</p:spTree></p:cSld></p:notes>"
                )
            }
        }
        return zip.data()
    }

    private static func shape(_ lines: [String], placeholder: String) -> String {
        let paragraphs = lines.map { "<a:p><a:r><a:t>\(escape($0))</a:t></a:r></a:p>" }.joined()
        return "<p:sp><p:nvSpPr><p:nvPr><p:ph type=\"\(placeholder)\"/></p:nvPr></p:nvSpPr><p:txBody>\(paragraphs)</p:txBody></p:sp>"
    }

    // MARK: Excel

    /// Two sheets: "Costs" with shared strings, an inline string, a
    /// formula's cached value, a boolean, a gap column, and a built-in date;
    /// "Notes" with one custom-date cell.
    static func xlsx(extraRows: Int = 0) -> Data {
        var zip = TestZipWriter()
        let ns = "xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        zip.add("xl/workbook.xml", """
            <workbook \(ns)><workbookPr/><sheets>\
            <sheet name="Costs" sheetId="1" r:id="rId1"/><sheet name="Notes" sheetId="2" r:id="rId2"/>\
            </sheets></workbook>
            """)
        zip.add("xl/_rels/workbook.xml.rels", """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rId2" Type="worksheet" Target="/xl/worksheets/sheet2.xml"/>\
            </Relationships>
            """)
        zip.add("xl/sharedStrings.xml", """
            <sst \(ns) count="4" uniqueCount="4"><si><t>Item</t></si><si><t>Cost</t></si>\
            <si><r><t>Re</t></r><r><t>nt</t></r></si><si><t>Café</t><rPh><t>カフェ</t></rPh></si></sst>
            """)
        zip.add("xl/styles.xml", """
            <styleSheet \(ns)><numFmts count="1"><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/></numFmts>\
            <cellStyleXfs count="1"><xf numFmtId="0"/></cellStyleXfs>\
            <cellXfs count="3"><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/></cellXfs></styleSheet>
            """)
        var rows = """
            <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>\
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>1200</v></c></row>\
            <row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3"><f>B2/10</f><v>120</v></c></row>\
            <row r="4"><c r="A4" t="inlineStr"><is><t>Inline</t></is></c><c r="B4" t="b"><v>1</v></c></row>\
            <row r="5"><c r="A5" t="str"><v>Due</v></c><c r="C5" s="1"><v>45000</v></c></row>
            """
        for index in 0..<extraRows {
            rows += "<row r=\"\(index + 6)\"><c r=\"A\(index + 6)\"><v>\(index)</v></c></row>"
        }
        let lastRow = 5 + extraRows
        zip.add("xl/worksheets/sheet1.xml", "<worksheet \(ns)><dimension ref=\"A1:C\(lastRow)\"/><sheetData>\(rows)</sheetData></worksheet>")
        zip.add("xl/worksheets/sheet2.xml", """
            <worksheet \(ns)><sheetData><row r="1"><c r="A1" s="2"><v>45000</v></c></row></sheetData></worksheet>
            """)
        return zip.data()
    }

    // MARK: Bombs

    /// One 200 MB entry of one byte, deflated to about 200 KB, with honest
    /// headers: refused before inflation by its declared size and ratio.
    static let bombPPTX: Data = {
        var zip = TestZipWriter()
        zip.addRepeated("ppt/slides/slide1.xml", byte: 0x41, count: 200 * 1_024 * 1_024)
        return zip.data()
    }()

    /// The same bomb whose headers claim 1 KB: only the inflate cap stops it.
    static let lyingBombPPTX: Data = {
        var zip = TestZipWriter()
        zip.addRepeated("ppt/slides/slide1.xml", byte: 0x41, count: 200 * 1_024 * 1_024, declaredSize: 1_024)
        return zip.data()
    }()

    // MARK: Attributed documents (doc, rtf, odt, docx through AppKit)

    static func attributed(_ text: String, type: NSAttributedString.DocumentType) -> Data {
        let string = NSAttributedString(string: text)
        return try! string.data(
            from: NSRange(location: 0, length: string.length),
            documentAttributes: [.documentType: type]
        )
    }

    // MARK: PDFs

    /// A PDF with a real text layer, one string per page (lines split on
    /// "\n").
    static func textPDF(pages: [String]) -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: output as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for page in pages {
            context.beginPDFPage(nil)
            var y: CGFloat = 740
            for line in page.split(separator: "\n", omittingEmptySubsequences: false) {
                draw(String(line), font: font, at: CGPoint(x: 54, y: y), in: context)
                y -= 14
            }
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    /// A PDF with a user password: it opens locked.
    static func encryptedPDF() -> Data {
        let document = PDFDocument(data: textPDF(pages: [english]))!
        let url = folder("encrypted").appending(path: "locked.pdf")
        document.write(to: url, withOptions: [
            PDFDocumentWriteOption.userPasswordOption: "secret",
            PDFDocumentWriteOption.ownerPasswordOption: "owner",
        ])
        return try! Data(contentsOf: url)
    }

    /// Pages that are pictures of text, with no text layer: a scan.
    static func scannedPDF(pages: [String]) -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: output as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for page in pages {
            context.beginPDFPage(nil)
            let image = textImage(page, width: 1_224, height: 400)
            context.draw(image, in: CGRect(x: 0, y: 792 - 200, width: 612, height: 200))
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    // MARK: Images

    /// Black text on white, large enough for OCR.
    static func textImage(_ text: String, width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(height) / 6, nil)
        var y = CGFloat(height) * 0.65
        for line in text.split(separator: "\n") {
            draw(String(line), font: font, at: CGPoint(x: CGFloat(width) * 0.05, y: y), in: context)
            y -= CGFloat(height) / 4
        }
        return context.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func draw(_ text: String, font: CTFont, at point: CGPoint, in context: CGContext) {
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
