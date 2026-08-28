import SwiftUI
import AppKit

/// A button that, when clicked, captures the next key combo as the new hotkey.
struct HotkeyRecorderView: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt
    @State private var isRecording = false
    @State private var validationError: String?
    var label: String = "Hotkey"
    var changeNotification: Notification.Name = .hotkeyChanged

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                Spacer()
                if isRecording {
                    HotkeyCapture { captured in
                        let rawMods = captured.modifierFlags
                            .intersection(.deviceIndependentFlagsMask).rawValue
                        guard QuickSettings.isValidHotkey(
                            keyCode: captured.keyCode, modifiers: rawMods
                        ) else {
                            validationError = "Must include Ctrl, Option, or Cmd"
                            isRecording = false
                            return
                        }
                        keyCode = captured.keyCode
                        modifiers = rawMods
                        validationError = nil
                        isRecording = false
                        NotificationCenter.default.post(
                            name: changeNotification, object: nil)
                    } onCancel: {
                        isRecording = false
                    }
                    .frame(width: 160, height: 28)
                } else {
                    Button {
                        validationError = nil
                        isRecording = true
                    } label: {
                        Text(displayName)
                            .font(.system(size: 13, weight: .medium,
                                          design: .monospaced))
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let error = validationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(AQDesign.ColorToken.danger)
            }
        }
    }

    private var displayName: String {
        var s = QuickSettings()
        s.hotkeyKeyCode = keyCode
        s.hotkeyModifiers = modifiers
        return s.hotkeyDisplayName
    }
}

struct ActionHotkeyRecorderView: View {
    @Binding var hotkey: ActionHotkey?
    @State private var isRecording = false
    @State private var validationError: String?
    var label: String = "Global hotkey"
    var changeNotification: Notification.Name = .actionHotkeysChanged

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                Spacer()
                if isRecording {
                    HotkeyCapture { event in
                        let modifiers = event.modifierFlags
                            .intersection(.deviceIndependentFlagsMask).rawValue
                        guard QuickSettings.isValidHotkey(
                            keyCode: event.keyCode,
                            modifiers: modifiers
                        ) else {
                            validationError = "Must include Ctrl, Option, or Cmd"
                            isRecording = false
                            return
                        }
                        hotkey = ActionHotkey(keyCode: event.keyCode, modifiers: modifiers)
                        validationError = nil
                        isRecording = false
                        notifyChanged()
                    } onCancel: {
                        isRecording = false
                    }
                    .frame(width: 180, height: 28)
                } else if let hotkey {
                    Button(displayName(hotkey)) { isRecording = true }
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .buttonStyle(.bordered)
                    Button("Clear") {
                        self.hotkey = nil
                        notifyChanged()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Button("Set hotkey…") { isRecording = true }
                        .buttonStyle(.bordered)
                }
            }
            if let validationError {
                Text(validationError)
                    .font(.system(size: 11))
                    .foregroundStyle(AQDesign.ColorToken.danger)
            }
        }
    }

    private func displayName(_ hotkey: ActionHotkey) -> String {
        var settings = QuickSettings()
        settings.hotkeyKeyCode = hotkey.keyCode
        settings.hotkeyModifiers = hotkey.modifiers
        return settings.hotkeyDisplayName
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: changeNotification, object: nil)
    }
}

// MARK: - NSViewRepresentable key capture field

/// An invisible, first-responder NSView that grabs exactly one key-down event
/// and reports it back. Press Escape to cancel without changing the hotkey.
struct HotkeyCapture: NSViewRepresentable {
    var onCapture: (NSEvent) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyCaptureView {
        let view = HotkeyCaptureView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.requestFirstResponder()
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.requestFirstResponder()
    }
}

final class HotkeyCaptureView: NSView {
    var onCapture: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFirstResponder()
    }

    /// SwiftUI can create the representable one turn before attaching it to
    /// the Settings panel. Reassert focus after attachment and updates so the
    /// next combo cannot fall through and leave the old shortcut unchanged.
    func requestFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            onCancel?()
        } else {
            onCapture?(event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.fill()
        let label = "Press a key combo..."
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let size = label.size(withAttributes: attrs)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        label.draw(at: point, withAttributes: attrs)
    }
}
