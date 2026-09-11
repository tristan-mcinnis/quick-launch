import Foundation

/// Turns the bytes of a text, Markdown, code, or HTML file into a string.
///
/// Order: a byte-order mark (UTF-8, UTF-16, UTF-32), then the binary check
/// (a NUL byte in the first 8 KB means "not a text file"), then strict
/// UTF-8, then the encoding macOS recorded for the file, then detection
/// over the common Chinese, Japanese, and Korean encodings, then
/// Windows-1252. The text is returned as decoded; NFKC is the extractor's
/// choice, since code keeps its text exactly.
enum PlainTextReader {
    enum DecodeError: Error, Equatable, Sendable {
        /// A NUL byte near the start: this is not a text file.
        case binary
    }

    /// Decodes a text file. `fileURL`, when given, lets macOS's recorded
    /// encoding for that file take part.
    static func decode(_ data: Data, fileURL: URL? = nil) throws -> String {
        if let (encoding, bomLength) = byteOrderMark(of: data) {
            let body = data.dropFirst(bomLength)
            if let text = String(data: body, encoding: encoding) { return text }
        }
        if hasNULByte(data, within: AttachmentLimits.binaryCheckBytes) {
            throw DecodeError.binary
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let fileURL {
            var used: String.Encoding = .utf8
            if let text = try? String(contentsOf: fileURL, usedEncoding: &used) { return text }
        }
        if let text = detected(data) { return text }
        return windows1252(data)
    }

    /// Decodes an HTML document: the charset the server declared, else a
    /// byte-order mark, else `<meta charset>`, else UTF-8, else
    /// Windows-1252.
    static func decodeHTML(_ data: Data, declaredCharset: String? = nil) -> String {
        if let declaredCharset, let encoding = encoding(forCharset: declaredCharset),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let (encoding, bomLength) = byteOrderMark(of: data),
           let text = String(data: data.dropFirst(bomLength), encoding: encoding) {
            return text
        }
        if let meta = metaCharset(in: data), let encoding = encoding(forCharset: meta),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return windows1252(data)
    }

    /// The encoding an IANA charset name stands for ("utf-8", "gb2312",
    /// "windows-1252", "shift_jis").
    static func encoding(forCharset name: String) -> String.Encoding? {
        let trimmed = name
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespacesAndNewlines))
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        // GB2312 and GBK pages are served as such but hold GB18030 text.
        let lookup = ["gb2312", "gbk", "x-gbk"].contains(trimmed) ? "gb18030" : trimmed
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(lookup as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    static func hasNULByte(_ data: Data, within limit: Int) -> Bool {
        data.prefix(limit).contains(0)
    }

    // MARK: - Private

    /// The encoding a leading byte-order mark names, and the mark's length.
    /// UTF-32 is checked before UTF-16, whose little-endian mark it starts
    /// with.
    private static func byteOrderMark(of data: Data) -> (String.Encoding, Int)? {
        let head = [UInt8](data.prefix(4))
        if head.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if head.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if head.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if head.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }

    private static func cfEncoding(_ value: CFStringEncodings) -> UInt {
        CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue))
    }

    /// Foundation's detector over the encodings a non-UTF-8 text file on
    /// this Mac is most likely in. Only a lossless result counts.
    private static func detected(_ data: Data) -> String? {
        let suggestions: [UInt] = [
            cfEncoding(.GB_18030_2000),
            cfEncoding(.big5),
            String.Encoding.shiftJIS.rawValue,
            String.Encoding.japaneseEUC.rawValue,
            cfEncoding(.EUC_KR),
            String.Encoding.windowsCP1252.rawValue,
        ]
        var converted: NSString?
        var lossy: ObjCBool = false
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: suggestions,
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        guard encoding != 0, !lossy.boolValue, let converted else { return nil }
        return converted as String
    }

    /// Windows-1252 leaves five bytes undefined; Latin-1 maps every byte,
    /// so the last resort never fails.
    private static func windows1252(_ data: Data) -> String {
        String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    private static let metaCharsetPattern = try! NSRegularExpression(
        pattern: #"<meta[^>]+charset\s*=\s*["']?\s*([A-Za-z0-9._:\-]+)"#,
        options: [.caseInsensitive]
    )

    /// `<meta charset="…">` or the `http-equiv` form, from the first 4 KB
    /// read as ASCII.
    private static func metaCharset(in data: Data) -> String? {
        let head = String(decoding: data.prefix(4_096), as: UTF8.self)
        let range = NSRange(head.startIndex..., in: head)
        guard let match = metaCharsetPattern.firstMatch(in: head, range: range),
              let found = Range(match.range(at: 1), in: head)
        else { return nil }
        return String(head[found])
    }
}
