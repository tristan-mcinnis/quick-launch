import Foundation

/// Pick Color from Screen: the system eyedropper, and the picked pixel on the
/// clipboard as `#RRGGBB`. No model, no file, and no permission.
extension QuickViewModel {
    /// The command row's value, and what Return on it runs.
    static let pickColorCommandID = "color.pick"

    /// Hides the launcher so the loupe has the whole screen, waits for the
    /// pick, then puts the hex on the clipboard and stops there. The copy is
    /// the whole action, as it is for Copy Text from Screen Area: no answer,
    /// no last question, no Copied flash, and the panel stays closed.
    ///
    /// A cancelled pick writes nothing and also leaves the panel closed; the
    /// clipboard, the answer and the last question are left exactly as they
    /// were.
    func pickColorFromScreen() async {
        guard let colorSampler else {
            errorMessage = "The color picker is not available in this build."
            requestInputFocus()
            return
        }
        input = ""
        prepareForExternalAction?()
        guard let picked = await colorSampler.sampleColor() else { return }
        // A copy the user keeps, so Clipboard History records it, exactly as
        // a snippet copy does.
        pasteboard.writeString(picked.hexString)
        overlayPresenter.dismissOverlay()
    }
}
