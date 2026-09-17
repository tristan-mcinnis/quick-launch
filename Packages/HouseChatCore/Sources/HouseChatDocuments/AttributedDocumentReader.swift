import AppKit
import Foundation

/// `NSAttributedString` with the explicit document type, never auto-detect:
/// detection "succeeds" on the wrong format with empty or raw output.
enum AttributedDocumentReader {
    /// `packageURL` is the `.rtfd` folder when the file is one; everything
    /// else reads from `data`.
    static func read(route: DocumentRoute, data: Data, packageURL: URL? = nil) throws -> DocumentText {
        let isPackage = route == .rtfd
            && packageURL.map { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } == true
        let type: NSAttributedString.DocumentType
        switch route {
        case .doc: type = .docFormat
        case .rtf: type = .rtf
        // A flat RTFD file is an RTF file (attachments and all); only a real
        // `.rtfd` folder is read as a package.
        case .rtfd: type = isPackage ? .rtfd : .rtf
        case .odt: type = .openDocument
        case .docx: type = .officeOpenXML
        default: throw DocumentExtractionError.wrongContent(route.kind)
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        let string: NSAttributedString
        do {
            if isPackage, let packageURL {
                string = try NSAttributedString(url: packageURL, options: options, documentAttributes: nil)
            } else {
                string = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            }
        } catch {
            throw DocumentExtractionError.damaged
        }
        // Attachment characters (U+FFFC) stand for pictures; they are not text.
        let text = string.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        return DocumentText(text: text)
    }
}
