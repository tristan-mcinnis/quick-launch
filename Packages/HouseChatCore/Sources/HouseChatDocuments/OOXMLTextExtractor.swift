import AppKit
import Foundation
import HouseChatCore

/// Text from Word (docx), PowerPoint (pptx), and Excel (xlsx) files, through
/// `OOXMLArchive` and `XMLParser`, plus the ZIP checks an OpenDocument text
/// file passes before `NSAttributedString` reads it.
enum OOXMLTextExtractor {
    // MARK: Word

    /// `word/document.xml`: `w:p` and `w:br` start a line, `w:tab` is a tab,
    /// table cells are tab-separated and rows end a line. When that yields
    /// nothing, `NSAttributedString` reads the file, after the archive passed
    /// the ZIP limits.
    static func word(data: Data, configuration: DocumentExtractionConfiguration) throws -> DocumentText {
        let archive = try openArchive(data, configuration: configuration)
        let part = mainPart(archive, relationshipSuffix: "/officeDocument") ?? "word/document.xml"
        guard let xml = try readPart(archive, part) else {
            throw DocumentExtractionError.wrongContent(.word)
        }
        let text = try WordDocumentParser.text(from: xml)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return DocumentText(text: text)
        }
        try inflateAll(archive)
        return try AttributedDocumentReader.read(route: .docx, data: data)
    }

    // MARK: OpenDocument

    /// Checks the archive against the ZIP limits, and inflates its every entry
    /// through the capped reader, before `NSAttributedString` (which has no
    /// caps of its own) opens it.
    static func openDocument(data: Data, configuration: DocumentExtractionConfiguration) throws -> DocumentText {
        let archive = try openArchive(data, configuration: configuration)
        guard archive.contains("content.xml") else { throw DocumentExtractionError.wrongContent(.word) }
        try inflateAll(archive)
        return try AttributedDocumentReader.read(route: .odt, data: data)
    }

    /// Inflates every entry through the caps and throws the archive's failure
    /// if one breaks them. Run before `NSAttributedString` opens an archive,
    /// since it inflates with no caps of its own.
    static func inflateAll(_ archive: OOXMLArchive) throws {
        for entry in archive.entries {
            try Task.checkCancellation()
            do {
                _ = try archive.read(entry)
            } catch {
                throw failure(for: error)
            }
        }
    }

    // MARK: PowerPoint

    /// Slides in the order `ppt/presentation.xml` lists them (numeric file
    /// order when it cannot be read), one section each, with the speaker
    /// notes under `Notes:`.
    static func powerPoint(data: Data, configuration: DocumentExtractionConfiguration) throws -> DocumentText {
        let archive = try openArchive(data, configuration: configuration)
        let slides = try slideParts(archive)
        guard !slides.isEmpty else { throw DocumentExtractionError.wrongContent(.powerpoint) }

        let readCount = min(slides.count, configuration.slideLimit)
        var sections: [DocumentText.Section] = []
        for (index, part) in slides.prefix(readCount).enumerated() {
            try Task.checkCancellation()
            var lines: [String] = []
            if let xml = try readPart(archive, part) {
                lines = try SlideTextParser.lines(from: xml)
            }
            if let notesPart = try notesPart(archive, forSlide: part),
               let notesXML = try readPart(archive, notesPart) {
                let notes = try SlideTextParser.lines(from: notesXML)
                if !notes.isEmpty { lines += ["Notes:"] + notes }
            }
            sections.append(.init(
                label: "Slide \(index + 1)",
                unit: .slide,
                index: index + 1,
                range: DocumentRange(start: index + 1, end: index + 1),
                body: lines.joined(separator: "\n")
            ))
        }
        let cut = slides.count > readCount
            ? DocumentText.UnitCut(unit: .slide, kept: readCount, total: slides.count)
            : nil
        return DocumentText(
            sections: sections,
            sectionUnit: .slide,
            unitCount: slides.count,
            unitCut: cut
        )
    }

    /// Slide part names in presentation order.
    static func slideParts(_ archive: OOXMLArchive) throws -> [String] {
        let fallback = numericallySorted(archive.names.filter {
            $0.lowercased().hasPrefix("ppt/slides/slide") && $0.lowercased().hasSuffix(".xml")
        })
        guard let presentation = try readPart(archive, "ppt/presentation.xml"),
              let relsData = try readPart(archive, "ppt/_rels/presentation.xml.rels")
        else { return fallback }
        let ids = try XMLWalker.collect(presentation) { name, attributes in
            name == "sldId" ? XMLWalker.attribute("id", in: attributes, prefixed: true) : nil
        }
        let targets = try relationships(relsData)
        let ordered = ids.compactMap { targets[$0].map { resolve($0.target, from: "ppt/") } }
            .filter { archive.contains($0) }
        return ordered.isEmpty ? fallback : ordered
    }

    private static func notesPart(_ archive: OOXMLArchive, forSlide part: String) throws -> String? {
        let folder = (part as NSString).deletingLastPathComponent
        let file = (part as NSString).lastPathComponent
        guard let rels = try readPart(archive, "\(folder)/_rels/\(file).rels") else { return nil }
        let target = try relationships(rels).values.first { $0.type.hasSuffix("/notesSlide") }
        return target.map { resolve($0.target, from: folder + "/") }
    }

    // MARK: Excel

    /// Each sheet (at most the configured cap) as a section and
    /// tab-separated rows (at most the row cap, column cap), cells placed by
    /// their reference.
    static func excel(data: Data, configuration: DocumentExtractionConfiguration) throws -> DocumentText {
        let archive = try openArchive(data, configuration: configuration)
        guard let workbookXML = try readPart(archive, "xl/workbook.xml") else {
            throw DocumentExtractionError.wrongContent(.excel)
        }
        let workbook = try WorkbookParser.parse(workbookXML)
        let targets = try readPart(archive, "xl/_rels/workbook.xml.rels").map(relationships) ?? [:]
        let sharedStrings = try readPart(archive, "xl/sharedStrings.xml").map(SharedStringsParser.strings) ?? []
        let styles = try readPart(archive, "xl/styles.xml").map(StylesParser.parse) ?? .empty

        let readCount = min(workbook.sheets.count, configuration.sheetLimit)
        var sections: [DocumentText.Section] = []
        var rowCut: DocumentText.UnitCut?
        var usesSerialDates = false
        for (index, sheet) in workbook.sheets.prefix(readCount).enumerated() {
            try Task.checkCancellation()
            let part = targets[sheet.relationshipID].map { resolve($0.target, from: "xl/") }
                ?? "xl/worksheets/sheet\(index + 1).xml"
            guard let entry = archive.entry(named: part) else { continue }
            let head = try readHead(archive, entry)
            var parsed = try SheetParser.parse(
                head.data,
                sharedStrings: sharedStrings,
                styles: styles,
                date1904: workbook.date1904,
                rowLimit: configuration.rowLimit,
                columnLimit: configuration.columnLimit
            )
            if head.isCut { parsed.rowsCut = true }
            usesSerialDates = usesSerialDates || parsed.usesCustomDateFormat
            var lines = parsed.rows
            if parsed.rowsCut {
                let kept = parsed.rows.count
                let total = parsed.totalRows.flatMap { $0 > kept ? " of \(TextTruncation.count($0))" : nil } ?? ""
                lines.append("[First \(TextTruncation.count(kept))\(total) rows.]")
                if rowCut == nil {
                    rowCut = .init(unit: .row, kept: kept, total: parsed.totalRows.flatMap { $0 > kept ? $0 : nil })
                }
            }
            if parsed.columnsCut {
                lines.append("[Columns after \(configuration.columnLimit) left out.]")
            }
            let name = sheet.name.replacingOccurrences(of: "\"", with: "'")
            sections.append(.init(
                label: "Sheet \"\(name)\"",
                unit: .sheet,
                index: index + 1,
                range: DocumentRange(start: index + 1, end: index + 1),
                body: lines.joined(separator: "\n")
            ))
        }
        guard !sections.isEmpty else { throw DocumentExtractionError.wrongContent(.excel) }
        let sheetCut = workbook.sheets.count > readCount
            ? DocumentText.UnitCut(unit: .sheet, kept: readCount, total: workbook.sheets.count)
            : nil
        return DocumentText(
            sections: sections,
            sectionUnit: .sheet,
            unitCount: workbook.sheets.count,
            unitCut: sheetCut ?? rowCut,
            notes: usesSerialDates ? [.spreadsheetSerialDates] : []
        )
    }

    // MARK: Archive helpers

    static func openArchive(_ data: Data, configuration: DocumentExtractionConfiguration) throws -> OOXMLArchive {
        do {
            return try OOXMLArchive(data: data, configuration: configuration)
        } catch {
            throw failure(for: error)
        }
    }

    /// One part, inflated in full through the caps.
    static func readPart(_ archive: OOXMLArchive, _ name: String) throws -> Data? {
        do {
            return try archive.data(for: name)
        } catch {
            throw failure(for: error)
        }
    }

    /// A worksheet may be larger than the per-entry cap while its first rows
    /// are not: the head up to the cap is parsed, and the parser reads what it
    /// can of a cut document.
    private static func readHead(
        _ archive: OOXMLArchive,
        _ entry: OOXMLArchive.Entry
    ) throws -> (data: Data, isCut: Bool) {
        do {
            return try archive.readHead(entry)
        } catch {
            throw failure(for: error)
        }
    }

    static func failure(for error: Error) -> Error {
        if error is CancellationError || error is DocumentExtractionError { return error }
        guard let archiveError = error as? OOXMLArchiveError else { return DocumentExtractionError.damaged }
        switch archiveError {
        case .notZip, .damaged, .unsupportedMethod: return DocumentExtractionError.damaged
        case .encrypted: return DocumentExtractionError.passwordProtected
        case .tooManyEntries, .tooBig: return DocumentExtractionError.tooLargeUnpacked
        }
    }

    /// The main part named in `_rels/.rels` by a relationship type ending in
    /// `suffix`.
    private static func mainPart(_ archive: OOXMLArchive, relationshipSuffix suffix: String) -> String? {
        guard let rels = try? archive.data(for: "_rels/.rels"),
              let relations = try? relationships(rels),
              let main = relations.values.first(where: { $0.type.hasSuffix(suffix) })
        else { return nil }
        let part = resolve(main.target, from: "")
        return archive.contains(part) ? part : nil
    }

    struct Relationship: Equatable, Sendable {
        let target: String
        let type: String
    }

    /// `Id` to target and type, from a `.rels` part.
    static func relationships(_ data: Data) throws -> [String: Relationship] {
        var result: [String: Relationship] = [:]
        try XMLWalker.walk(data) { name, attributes in
            guard name == "Relationship",
                  let id = attributes["Id"],
                  let target = attributes["Target"],
                  attributes["TargetMode"]?.lowercased() != "external"
            else { return }
            result[id] = Relationship(target: target, type: attributes["Type"] ?? "")
        }
        return result
    }

    /// A relationship target as a part name: absolute ("/ppt/slides/…") or
    /// relative to the source part's folder, with `..` applied. The result is
    /// only ever looked up in the archive, never used as a path.
    static func resolve(_ target: String, from folder: String) -> String {
        let decoded = target.removingPercentEncoding ?? target
        let joined = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : folder + decoded
        var parts: [Substring] = []
        for part in joined.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }

    /// `slide10` after `slide9`: names ordered by the number they end in.
    static func numericallySorted(_ names: [String]) -> [String] {
        func number(_ name: String) -> Int {
            let stem = (name as NSString).deletingPathExtension
            let digits = stem.reversed().prefix { $0.isNumber }
            return Int(String(digits.reversed())) ?? Int.max
        }
        return names.sorted { (number($0), $0) < (number($1), $1) }
    }
}

// MARK: - XML

/// `XMLParser` with external entities off and any document type declaration
/// refused (no XXE, no entity expansion), element names without their
/// namespace prefix, and cancellation checks while it runs.
final class XMLWalker: NSObject, XMLParserDelegate {
    typealias Start = (_ name: String, _ attributes: [String: String]) -> Void
    typealias End = (_ name: String) -> Void
    typealias Characters = (_ text: String) -> Void

    private let onStart: Start
    private let onEnd: End?
    private let onCharacters: Characters?
    private var elements = 0
    private var cancelled = false
    /// Set by a callback to stop the parse early (a row cap).
    var stop = false

    private init(start: @escaping Start, end: End?, characters: Characters?) {
        self.onStart = start
        self.onEnd = end
        self.onCharacters = characters
    }

    /// Parses `data`, calling back per element. A document that ends early (a
    /// cut worksheet) keeps what was read. Throws `damaged` for a document
    /// type declaration and `CancellationError` when cancelled.
    static func walk(
        _ data: Data,
        start: @escaping Start,
        end: End? = nil,
        characters: Characters? = nil,
        control: ((XMLWalker) -> Void)? = nil
    ) throws {
        guard prologIsSafe(data) else { throw DocumentExtractionError.damaged }
        let walker = XMLWalker(start: start, end: end, characters: characters)
        control?(walker)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = walker
        parser.parse()
        if walker.cancelled { throw CancellationError() }
    }

    /// True when the bytes before the root element hold only the XML
    /// declaration, processing instructions, comments, and white space: no
    /// `<!DOCTYPE`, so no entity can be declared. Office parts are UTF-8;
    /// UTF-16 and UTF-32 parts are refused rather than scanned.
    static func prologIsSafe(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) || bytes.contains(0) {
            return false
        }
        var index = data.startIndex
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { index += 3 }
        while index < data.endIndex {
            let byte = data[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
                continue
            }
            guard byte == 0x3C, index + 1 < data.endIndex else { return true }
            let next = data[index + 1]
            if next == 0x3F {
                // <? ... ?>
                guard let end = data[index...].firstRange(of: [0x3F, 0x3E]) else { return false }
                index = end.upperBound
            } else if next == 0x21 {
                // Only a comment may come before the root; <!DOCTYPE may not.
                guard data[index...].starts(with: [0x3C, 0x21, 0x2D, 0x2D]),
                      let end = data[(index + 4)...].firstRange(of: [0x2D, 0x2D, 0x3E])
                else { return false }
                index = end.upperBound
            } else {
                return true
            }
        }
        return true
    }

    /// Collects one value per element that `pick` names.
    static func collect(_ data: Data, pick: @escaping (String, [String: String]) -> String?) throws -> [String] {
        var values: [String] = []
        try walk(data) { name, attributes in
            if let value = pick(name, attributes) { values.append(value) }
        }
        return values
    }

    /// An attribute by local name; `prefixed` also accepts `r:id` and the like.
    static func attribute(_ local: String, in attributes: [String: String], prefixed: Bool = false) -> String? {
        if !prefixed, let value = attributes[local] { return value }
        return attributes.first { key, _ in
            prefixed ? key.hasSuffix(":" + local) : (key == local || key.hasSuffix(":" + local))
        }?.value
    }

    static func localName(_ qualified: String) -> String {
        guard let colon = qualified.lastIndex(of: ":") else { return qualified }
        return String(qualified[qualified.index(after: colon)...])
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        elements += 1
        if elements % 2_000 == 0, Task.isCancelled {
            cancelled = true
            parser.abortParsing()
            return
        }
        onStart(Self.localName(elementName), attributes)
        if stop { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        onEnd?(Self.localName(elementName))
        if stop { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        onCharacters?(string)
    }
}

/// `word/document.xml` to lines.
enum WordDocumentParser {
    static func text(from data: Data) throws -> String {
        var output = ""
        var runDepth = 0
        var textDepth = 0
        var cellDepth = 0
        var skipDepth = 0
        // A text box is a paragraph inside a paragraph: the outer one adds no
        // second line break after the inner one's.
        var paragraphDepth = 0
        var innerParagraphEnded = false
        try XMLWalker.walk(
            data,
            start: { name, _ in
                if skipDepth > 0 || name == "Fallback" { skipDepth += 1; return }
                switch name {
                case "p": paragraphDepth += 1
                case "r": runDepth += 1
                case "t": textDepth += 1
                case "tab": if runDepth > 0 { output += "\t" }
                case "br", "cr": if runDepth > 0 { output += cellDepth > 0 ? " " : "\n" }
                case "noBreakHyphen": output += "-"
                case "tc": cellDepth += 1
                default: break
                }
            },
            end: { name in
                if skipDepth > 0 { skipDepth -= 1; return }
                switch name {
                case "r": runDepth = max(0, runDepth - 1)
                case "t": textDepth = max(0, textDepth - 1)
                case "p":
                    paragraphDepth = max(0, paragraphDepth - 1)
                    if paragraphDepth > 0 {
                        innerParagraphEnded = true
                        output += cellDepth > 0 ? " " : "\n"
                    } else if innerParagraphEnded, output.hasSuffix("\n") {
                        innerParagraphEnded = false
                    } else {
                        innerParagraphEnded = false
                        output += cellDepth > 0 ? " " : "\n"
                    }
                case "tc":
                    cellDepth = max(0, cellDepth - 1)
                    trimTrailing(&output, " ")
                    output += "\t"
                case "tr":
                    trimTrailing(&output, "\t")
                    output += "\n"
                default: break
                }
            },
            characters: { text in
                if skipDepth == 0, textDepth > 0 { output += text }
            }
        )
        return output
    }

    private static func trimTrailing(_ text: inout String, _ character: Character) {
        while text.last == character { text.removeLast() }
    }
}

/// One slide or notes page to lines: the text of each paragraph, shape by
/// shape. Slide-number, date, footer, header, and slide-image placeholders are
/// left out, so notes carry only what the speaker wrote.
enum SlideTextParser {
    private static let skippedPlaceholders: Set<String> = ["sldNum", "dt", "ftr", "hdr", "sldImg"]

    static func lines(from data: Data) throws -> [String] {
        var lines: [String] = []
        var shapeLines: [String] = []
        var shapeDepth = 0
        var placeholder: String?
        var paragraph = ""
        var inText = 0
        var skipDepth = 0
        try XMLWalker.walk(
            data,
            start: { name, attributes in
                if skipDepth > 0 || name == "Fallback" { skipDepth += 1; return }
                switch name {
                case "sp":
                    shapeDepth += 1
                    if shapeDepth == 1 { shapeLines = []; placeholder = nil }
                case "ph": if shapeDepth > 0 { placeholder = attributes["type"] ?? "body" }
                case "p": paragraph = ""
                case "t": inText += 1
                case "br": paragraph += "\n"
                default: break
                }
            },
            end: { name in
                if skipDepth > 0 { skipDepth -= 1; return }
                switch name {
                case "t": inText = max(0, inText - 1)
                case "p":
                    let line = paragraph.trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty {
                        if shapeDepth > 0 { shapeLines.append(line) } else { lines.append(line) }
                    }
                    paragraph = ""
                case "sp":
                    shapeDepth = max(0, shapeDepth - 1)
                    if shapeDepth == 0 {
                        if !skippedPlaceholders.contains(placeholder ?? "") { lines += shapeLines }
                        shapeLines = []
                    }
                default: break
                }
            },
            characters: { text in
                if skipDepth == 0, inText > 0 { paragraph += text }
            }
        )
        return lines
    }
}

/// `xl/workbook.xml`: sheet names and relationship ids, in tab order, and the
/// 1904 date system flag.
enum WorkbookParser {
    struct Sheet: Equatable, Sendable {
        let name: String
        let relationshipID: String
    }

    struct Workbook: Equatable, Sendable {
        var sheets: [Sheet] = []
        var date1904 = false
    }

    static func parse(_ data: Data) throws -> Workbook {
        var workbook = Workbook()
        try XMLWalker.walk(data) { name, attributes in
            switch name {
            case "sheet":
                guard let sheetName = attributes["name"],
                      let id = XMLWalker.attribute("id", in: attributes, prefixed: true)
                else { return }
                workbook.sheets.append(Sheet(name: sheetName, relationshipID: id))
            case "workbookPr":
                let flag = attributes["date1904"]?.lowercased()
                workbook.date1904 = flag == "1" || flag == "true"
            default: break
            }
        }
        return workbook
    }
}

/// `xl/sharedStrings.xml`: one string per `<si>`, phonetic runs left out.
enum SharedStringsParser {
    static func strings(_ data: Data) throws -> [String] {
        var strings: [String] = []
        var current = ""
        var inItem = false
        var inText = 0
        var phoneticDepth = 0
        try XMLWalker.walk(
            data,
            start: { name, _ in
                switch name {
                case "si": inItem = true; current = ""
                case "rPh": phoneticDepth += 1
                case "t": inText += 1
                default: break
                }
            },
            end: { name in
                switch name {
                case "si": strings.append(current); inItem = false
                case "rPh": phoneticDepth = max(0, phoneticDepth - 1)
                case "t": inText = max(0, inText - 1)
                default: break
                }
            },
            characters: { text in
                if inItem, inText > 0, phoneticDepth == 0 { current += text }
            }
        )
        return strings
    }
}

/// `xl/styles.xml`: each cell format's number format, and which custom number
/// formats are dates.
enum StylesParser {
    struct Styles: Equatable, Sendable {
        /// Number format id per `cellXfs` index (a cell's `s`).
        var formatIDs: [Int]
        /// Custom format ids whose code reads as a date or time.
        var customDateFormats: Set<Int>

        static let empty = Styles(formatIDs: [], customDateFormats: [])
    }

    static func parse(_ data: Data) throws -> Styles {
        var styles = Styles.empty
        var inCellFormats = false
        try XMLWalker.walk(
            data,
            start: { name, attributes in
                switch name {
                case "numFmt":
                    if let id = attributes["numFmtId"].flatMap(Int.init),
                       let code = attributes["formatCode"], isDateFormat(code) {
                        styles.customDateFormats.insert(id)
                    }
                case "cellXfs": inCellFormats = true
                case "xf":
                    if inCellFormats {
                        styles.formatIDs.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
                    }
                default: break
                }
            },
            end: { name in
                if name == "cellXfs" { inCellFormats = false }
            }
        )
        return styles
    }

    /// A format code with day, month-with-year, or hour parts outside quoted
    /// text and `[…]` sections.
    static func isDateFormat(_ code: String) -> Bool {
        var plain = ""
        var inQuote = false
        var inBracket = false
        var escaped = false
        for character in code {
            if escaped { escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "\"": inQuote.toggle()
            case "[": if !inQuote { inBracket = true }
            case "]": if !inQuote { inBracket = false }
            default: if !inQuote && !inBracket { plain.append(character) }
            }
        }
        let lower = plain.lowercased()
        return lower.contains("y") || lower.contains("d") || lower.contains("h")
            || (lower.contains("m") && lower.contains("s"))
    }
}

/// One worksheet to tab-separated rows, cells placed by their `r` reference,
/// values as stored (a formula gives its cached value).
enum SheetParser {
    struct Parsed: Equatable, Sendable {
        var rows: [String] = []
        var rowsCut = false
        var columnsCut = false
        /// From `<dimension ref="A1:D9000">`, when present.
        var totalRows: Int?
        var usesCustomDateFormat = false
    }

    static func parse(
        _ data: Data,
        sharedStrings: [String],
        styles: StylesParser.Styles,
        date1904: Bool,
        rowLimit: Int,
        columnLimit: Int
    ) throws -> Parsed {
        var parsed = Parsed()
        var cells: [Int: String] = [:]
        var nextColumn = 0
        var cellType = ""
        var cellStyle: Int?
        var cellColumn = 0
        var value = ""
        var inValue = 0
        var inInline = 0
        var inPhonetic = 0
        var inCell = false
        var rowsKept = 0
        var walker: XMLWalker?

        func finishRow() {
            guard !cells.isEmpty else { return }
            let last = cells.keys.max() ?? 0
            let line = (0...last).map { cells[$0] ?? "" }.joined(separator: "\t")
            parsed.rows.append(line)
            rowsKept += 1
            cells = [:]
        }

        try XMLWalker.walk(
            data,
            start: { name, attributes in
                switch name {
                case "dimension":
                    if let ref = attributes["ref"], let end = ref.split(separator: ":").last {
                        parsed.totalRows = CellReference.row(String(end))
                    }
                case "row":
                    nextColumn = 0
                    cells = [:]
                case "c":
                    inCell = true
                    cellType = attributes["t"] ?? "n"
                    cellStyle = attributes["s"].flatMap(Int.init)
                    cellColumn = attributes["r"].flatMap(CellReference.column) ?? nextColumn
                    nextColumn = cellColumn + 1
                    value = ""
                case "v": if inCell { inValue += 1 }
                case "is": if inCell { inInline += 1 }
                case "rPh": inPhonetic += 1
                default: break
                }
            },
            end: { name in
                switch name {
                case "v": inValue = max(0, inValue - 1)
                case "is": inInline = max(0, inInline - 1)
                case "rPh": inPhonetic = max(0, inPhonetic - 1)
                case "c":
                    inCell = false
                    guard cellColumn < columnLimit else {
                        parsed.columnsCut = true
                        return
                    }
                    let text = cellText(
                        value,
                        type: cellType,
                        style: cellStyle,
                        sharedStrings: sharedStrings,
                        styles: styles,
                        date1904: date1904,
                        usesCustomDate: &parsed.usesCustomDateFormat
                    )
                    if !text.isEmpty { cells[cellColumn] = text }
                case "row":
                    if rowsKept >= rowLimit, !cells.isEmpty {
                        parsed.rowsCut = true
                        cells = [:]
                        walker?.stop = true
                    } else {
                        finishRow()
                    }
                default: break
                }
            },
            characters: { text in
                if inValue > 0 || (inInline > 0 && inPhonetic == 0) { value += text }
            },
            control: { walker = $0 }
        )
        return parsed
    }

    static func cellText(
        _ raw: String,
        type: String,
        style: Int?,
        sharedStrings: [String],
        styles: StylesParser.Styles,
        date1904: Bool,
        usesCustomDate: inout Bool
    ) -> String {
        let text: String
        switch type {
        case "s":
            text = Int(raw).flatMap { sharedStrings.indices.contains($0) ? sharedStrings[$0] : nil } ?? ""
        case "b":
            text = raw == "1" ? "TRUE" : (raw == "0" ? "FALSE" : raw)
        case "inlineStr", "str", "e", "d":
            text = raw
        default:
            let formatID = style.flatMap { styles.formatIDs.indices.contains($0) ? styles.formatIDs[$0] : nil }
            if let formatID, (14...22).contains(formatID), let serial = Double(raw),
               let date = SerialDate.string(serial, format: formatID, date1904: date1904) {
                text = date
            } else {
                if let formatID, styles.customDateFormats.contains(formatID) { usesCustomDate = true }
                text = raw
            }
        }
        // A tab or a line break inside a cell would break the row's shape.
        return text
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// "B12" to column 1 and row 12.
enum CellReference {
    static func column(_ reference: String) -> Int? {
        var column = 0
        var letters = 0
        for byte in reference.utf8 {
            switch byte {
            case 65...90: column = column * 26 + Int(byte - 64)
            case 97...122: column = column * 26 + Int(byte - 96)
            default: return letters > 0 ? column - 1 : nil
            }
            letters += 1
            if column > 16_384 { return nil }
        }
        return letters > 0 ? column - 1 : nil
    }

    static func row(_ reference: String) -> Int? {
        Int(String(reference.drop { !$0.isNumber }))
    }
}

/// Spreadsheet serial numbers for the built-in date formats 14 to 22.
enum SerialDate {
    static func string(_ serial: Double, format: Int, date1904: Bool) -> String? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
        // The 1900 system counts a 29 February 1900 that never was, so from
        // serial 61 on its day zero is 30 December 1899.
        var components = DateComponents()
        if date1904 {
            components.year = 1904; components.month = 1; components.day = 1
        } else if serial < 61 {
            components.year = 1899; components.month = 12; components.day = 31
        } else {
            components.year = 1899; components.month = 12; components.day = 30
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let base = calendar.date(from: components) else { return nil }
        let seconds = (serial * 86_400).rounded()
        let date = base.addingTimeInterval(seconds)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch format {
        case 14, 15, 16, 17: formatter.dateFormat = "yyyy-MM-dd"
        case 18, 20: formatter.dateFormat = "HH:mm"
        case 19, 21: formatter.dateFormat = "HH:mm:ss"
        case 22: formatter.dateFormat = "yyyy-MM-dd HH:mm"
        default: return nil
        }
        return formatter.string(from: date)
    }
}
