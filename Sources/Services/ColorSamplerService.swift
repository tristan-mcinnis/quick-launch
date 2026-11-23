import AppKit

/// `NSColorSampler`: the system eyedropper, the loupe that follows the cursor
/// and answers with the pixel under it. macOS draws it, so there is no
/// permission to ask for and no screen capture of this app's own.
@MainActor
final class SystemColorSampler: ColorSampling {
    /// Held while the picker is up. `NSColorSampler` is a window controller
    /// under the hood: dropping the last reference would close the loupe in
    /// the middle of a pick.
    private var sampler: NSColorSampler?
    private var continuation: CheckedContinuation<SampledColor?, Never>?

    func sampleColor() async -> SampledColor? {
        // One loupe at a time. A second ask while the first is up would
        // replace the waiting continuation and leave it hanging forever, so
        // it reads as a cancelled pick.
        guard continuation == nil else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let sampler = NSColorSampler()
            self.sampler = sampler
            sampler.show { [weak self] color in
                // AppKit calls the handler on the main thread, and the picker
                // is main-actor state. The isolation is the AppKit contract,
                // so it is asserted here rather than hopped to.
                MainActor.assumeIsolated {
                    self?.finish(color)
                }
            }
        }
    }

    /// Answer the waiting pick exactly once. Escape arrives as `nil`.
    private func finish(_ color: NSColor?) {
        sampler = nil
        let picked = color.flatMap(SampledColor.init(color:))
        let waiting = continuation
        continuation = nil
        // Resumed last: the waiting task runs on a later turn and may start
        // another pick immediately.
        waiting?.resume(returning: picked)
    }
}
