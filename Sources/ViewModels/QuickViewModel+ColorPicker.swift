import Foundation

/// Pick Color from Screen: the system eyedropper, and the picked pixel on the
/// clipboard as `#RRGGBB`. No model, no file, and no permission.
extension QuickViewModel {
    /// The command row's value, and what Return on it runs.
    static let pickColorCommandID = "color.pick"

    /// Hides the launcher so the loupe has the whole screen, waits for the
    /// pick, then puts the hex on the clipboard and shows it.
    ///
    /// A cancelled pick writes nothing: the clipboard, the answer and the
    /// last question are left exactly as they were, and the panel comes back
    /// so the user is not stranded outside it.
    func pickColorFromScreen() async {
        guard let colorSampler else {
            errorMessage = "The color picker is not available in this build."
            requestInputFocus()
            return
        }
        input = ""
        prepareForExternalAction?()
        guard let picked = await colorSampler.sampleColor() else {
            overlayPresenter.presentOverlay()
            requestInputFocus()
            return
        }
        let hex = picked.hexString
        // A copy the user keeps, so Clipboard History records it, exactly as
        // a snippet copy does.
        pasteboard.writeString(hex)
        errorMessage = nil
        answerSource = .command("Pick Color")
        output = hex
        lastQuestion = "Picked from the screen"
        markJustCopied()
        overlayPresenter.presentOverlay()
        requestInputFocus()
    }
}
