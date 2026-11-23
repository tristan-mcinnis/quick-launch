import Foundation

/// The macOS screen colour picker, reduced to one value.
///
/// A seam like the pasteboard's: the app injects the system eyedropper and a
/// test injects one that answers without touching the screen or the cursor.
@MainActor
protocol ColorSampling: AnyObject {
    /// Shows the system eyedropper and waits for the pick. `nil` means the
    /// user cancelled (Escape, or a click that resolved to nothing), so
    /// nothing was picked and nothing is written.
    func sampleColor() async -> SampledColor?
}
