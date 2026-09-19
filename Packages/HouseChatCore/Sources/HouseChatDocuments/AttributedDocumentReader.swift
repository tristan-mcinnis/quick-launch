import AppKit
import Foundation

/// `NSAttributedString` with the explicit document type, never auto-detect:
/// detection "succeeds" on the wrong format with empty or raw output.
enum AttributedDocumentReader {
    /// `packageURL` is the `.rtfd` folder when the file is one; everything
    /// else reads from `data`. `packageByteLimit` is re-checked against the
    /// package immediately before the native package read, which cannot be
    /// capped or interrupted once it starts.
    static func read(
        route: DocumentRoute,
        data: Data,
        packageURL: URL? = nil,
        packageByteLimit: Int = .max
    ) throws -> DocumentText {
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
                // `NSAttributedString(url:)` re-opens the package with no cap
                // of its own, outside the 50 MB limit, and the cooperative
                // deadline cannot interrupt a blocking native read. Re-stat
                // right here and refuse a package that has grown past the cap.
                let size = DocumentFileGate.packageSize(packageURL)
                guard size <= packageByteLimit else {
                    throw DocumentExtractionError.tooLarge(limit: packageByteLimit)
                }
                string = try NSAttributedString(url: packageURL, options: options, documentAttributes: nil)
            } else {
                string = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            }
        } catch let error as DocumentExtractionError {
            throw error
        } catch {
            throw DocumentExtractionError.damaged
        }
        // Attachment characters (U+FFFC) stand for pictures; they are not text.
        let text = string.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        return DocumentText(text: text)
    }
}
