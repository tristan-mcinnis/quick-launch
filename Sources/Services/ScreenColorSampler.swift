import AppKit
import Foundation

/// AppKit's own eyedropper. `NSColorSampler` draws the magnified loupe, works
/// across every connected display, and needs no screen-recording permission,
/// so the picker stays inside the sandboxed, no-capture part of the product.
@MainActor
final class ScreenColorSampler: ScreenColorSampling {
    private var isSampling = false

    func sample() async -> PickedColor? {
        // A second loupe while one is open would strand the first continuation.
        guard !isSampling else { return nil }
        isSampling = true
        defer { isSampling = false }
        let sampler = NSColorSampler()
        let picked: NSColor? = await withCheckedContinuation { continuation in
            sampler.show { color in
                continuation.resume(returning: color)
            }
        }
        return picked.flatMap(PickedColor.init(nsColor:))
    }
}

extension PickedColor {
    /// Converted through sRGB so the stored numbers match what CSS, Figma,
    /// and the rest of the world call this color.
    init?(nsColor: NSColor) {
        guard let converted = nsColor.usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: Double(converted.alphaComponent)
        )
    }
}
