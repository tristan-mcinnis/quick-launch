/// Actions on the Quick AI window itself rather than on an answer. They sit
/// in the `⌘K` palette while the surface is up, after the answer actions,
/// and have no direct key.
enum QuickAISurfaceAction: String, CaseIterable, Identifiable, Sendable {
    /// Back to the standard 750 × 475 after the user dragged the window
    /// larger. Offered only when the size is not the standard one.
    case resetSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resetSize: "Reset Quick AI Size"
        }
    }

    var detail: String {
        switch self {
        case .resetSize:
            "Back to \(Int(QuickAISize.standard.width)) × \(Int(QuickAISize.standard.height))"
        }
    }

    var systemImage: String {
        switch self {
        case .resetSize: "arrow.down.right.and.arrow.up.left"
        }
    }
}
