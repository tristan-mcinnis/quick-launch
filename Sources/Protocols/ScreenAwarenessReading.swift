import Foundation

@MainActor
protocol ScreenAwarenessReading: AnyObject {
    /// Reads the focused window of `target` through Accessibility.
    func readContext(for target: SelectionTarget) -> CaptureContext
    /// Lets the user drag out a screen area; returns the image or nil when cancelled.
    func captureArea() async -> QuickImageAttachment?
}
