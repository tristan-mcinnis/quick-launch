import Foundation

@MainActor
protocol ScreenshotCapturing: AnyObject {
    var isScreenRecordingAuthorized: Bool { get }
    /// Captures `kind`. `target` is the app behind Quick Launch; `ownProcess`
    /// is excluded from display captures so the overlay never appears in its
    /// own screenshot.
    func capture(
        _ kind: ScreenshotKind,
        target: SelectionTarget?,
        ownProcess: pid_t
    ) async throws -> QuickImageAttachment
}
