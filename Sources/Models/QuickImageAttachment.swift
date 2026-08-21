import Foundation

/// An ephemeral image attached to one request. Attachments are never encoded
/// into conversation history or written to disk by Quick Launch.
struct QuickImageAttachment: Sendable, Equatable {
    let data: Data
    let mimeType: String
    let pixelWidth: Int
    let pixelHeight: Int

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}
