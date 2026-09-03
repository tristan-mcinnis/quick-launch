import SwiftUI
import AppKit

/// A control that shows the current hotkey as key caps and, when clicked,
/// captures the next key combo as the new one. Inside a `SettingsRow` the
/// row carries the title, so `showsLabel` turns the built-in label off.
struct HotkeyRecorderView: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt
    @State private var isRecording = false
    @State private var validationError: String?
    var label: String = "Hotkey"
    /// False when the surrounding row already names the control.
    var showsLabel: Bool = true
    var changeNotification: Notification.Name = .hotkeyChanged

    var body: some View {
        VStack(alignment: .trailing, spacing: AQDesign.Space.compact) {
            HStack(spacing: AQDesign.Space.standard) {
                if showsLabel && !label.isEmpty {
                    Text(label)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    Spacer(minLength: AQDesign.Space.standard)
                }
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
                    .frame(width: 160, height: House.Control.compact)
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: AQDesign.fieldCornerRadius,
                            style: .continuous
                        )
                        .strokeBorder(
                            AQDesign.ColorToken.panelStrokeStrong,
                            lineWidth: AQDesign.hairline
                        )
                    )
                } else {
                    Button {
                        validationError = nil
                        isRecording = true
                    } label: {
                        KeyCapGroup(keys: keyCaps)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(displayName)
                    .help("Click, then press the keys")
                }
            }
            if let error = validationError {
                Text(error)
                    .font(AQDesign.TypeToken.hint)
                    .foregroundStyle(AQDesign.ColorToken.danger)
            }
        }
    }

    private var keyCaps: [String] {
        ActionHotkey(keyCode: keyCode, modifiers: modifiers).keyCaps
    }

    private var displayName: String {
        var s = QuickSettings()
        s.hotkeyKeyCode = keyCode
        s.hotkeyModifiers = modifiers
        return s.hotkeyDisplayName
    }
}

/// The same control for an optional action hotkey: key caps when set, a
/// plain "Set hotkey…" when not.
struct ActionHotkeyRecorderView: View {
    @Binding var hotkey: ActionHotkey?
    @State private var isRecording = false
    @State private var validationError: String?
    var label: String = "Global hotkey"
    /// False when the surrounding row already names the control.
    var showsLabel: Bool = true
    var changeNotification: Notification.Name = .actionHotkeysChanged

    var body: some View {
        VStack(alignment: .trailing, spacing: AQDesign.Space.compact) {
            HStack(spacing: AQDesign.Space.standard) {
                if showsLabel && !label.isEmpty {
                    Text(label)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    Spacer(minLength: AQDesign.Space.standard)
                }
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
                    .frame(width: 180, height: House.Control.compact)
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: AQDesign.fieldCornerRadius,
                            style: .continuous
                        )
                        .strokeBorder(
                            AQDesign.ColorToken.panelStrokeStrong,
                            lineWidth: AQDesign.hairline
                        )
                    )
                } else if let hotkey {
                    Button {
                        isRecording = true
                    } label: {
                        KeyCapGroup(keys: hotkey.keyCaps)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(displayName(hotkey))
                    .help("Click, then press the keys")
                    Button("Clear") {
                        self.hotkey = nil
                        notifyChanged()
                    }
                    .buttonStyle(.plain)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                } else {
                    Button("Set hotkey…") { isRecording = true }
                        .buttonStyle(.plain)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textSecondary)
                }
            }
            if let validationError {
                Text(validationError)
                    .font(AQDesign.TypeToken.hint)
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
        if VirtualKey(event: event) == .escape {
            onCancel?()
        } else {
            onCapture?(event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        House.NSColorToken.surfaceTint.setFill()
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: House.Radius.sm,
            yRadius: House.Radius.sm
        )
        path.fill()
        let label = "Press a key combo..."
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: House.TypeToken.Size.code,
                weight: .medium
            ),
            .foregroundColor: House.NSColorToken.textTertiary,
        ]
        let size = label.size(withAttributes: attrs)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        label.draw(at: point, withAttributes: attrs)
    }
}
