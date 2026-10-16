import Foundation

extension AttachmentSource {
    /// Literal text chosen by the user, never a file or image representation.
    var transformText: String? {
        switch self {
        case .selection(let text, _), .clipboard(let text, _): text
        default: nil
        }
    }
}

extension AttachmentContent {
    /// Clipboard text keeps its own provenance instead of pretending to be
    /// the current selection. Both explicit text sources support transforms.
    var isTransformTextSource: Bool {
        ref.kind == .selection || (ref.kind == .text && kindLabel == "Clipboard")
    }
}
