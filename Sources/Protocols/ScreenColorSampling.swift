import Foundation

/// The screen eyedropper. One call shows the system loupe over every display
/// and returns the color the user clicks, or nil when they press Escape.
@MainActor
protocol ScreenColorSampling: AnyObject {
    func sample() async -> PickedColor?
}
