import AppKit
import ApplicationServices
import OSLog

/// Borderless panel that can still become key, so the overlay receives
/// keystrokes (same trick as KeyablePanel).
final class TypeToClickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    var keyHandler: ((NSEvent) -> Bool)?

    /// Route keys at the window boundary as well as through first responder.
    /// A newly activated menu-bar app can briefly have no field editor even
    /// after the panel is visible; relying only on NSView.keyDown loses those
    /// first hint characters.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

enum TypeToClickKeyPolicy {
    static func hintCharacter(
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        let normalizedModifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        // Control and Option may still be held from the global hotkey. Command
        // is unrelated and must remain available to normal app/menu shortcuts.
        guard !normalizedModifiers.contains(.command),
              let character = charactersIgnoringModifiers?.lowercased(),
              character.count == 1,
              character.first?.isLetter == true || character.first?.isNumber == true
        else { return nil }
        return character
    }
}

enum TypeToClickCoordinates {
    static func panelRect(
        for accessibilityFrame: CGRect,
        primaryTop: CGFloat,
        panelOrigin: CGPoint
    ) -> NSRect {
        NSRect(
            x: accessibilityFrame.minX - panelOrigin.x,
            y: primaryTop - accessibilityFrame.minY - accessibilityFrame.height - panelOrigin.y,
            width: accessibilityFrame.width,
            height: accessibilityFrame.height
        )
    }
}

/// One display-local overlay surface. A single window spanning mixed-Retina
/// displays is transformed incorrectly by WindowServer, so each screen needs
/// its own panel and local drawing coordinates.
private struct TypeToClickSurface {
    let screenFrame: NSRect
    let panel: TypeToClickPanel
    let view: TypeToClickOverlayView
}

/// Coordinates the type-to-click overlay: transparent panels, hint filtering
/// as the user types, and the click on an exact hint match.
@MainActor
final class TypeToClickController {
    static let defaultAlphabet = "sadfjklewcmpgh"

    private let service: TypeToClickServicing
    private let logger = Logger(
        subsystem: "com.tristanmcinnis.quick-launch",
        category: "TypeToClick"
    )
    private var surfaces: [TypeToClickSurface] = []
    private weak var keyPanel: TypeToClickPanel?
    private var primaryTop: CGFloat = 0

    private var targets: [TypeToClickTarget] = []
    private var typed = ""
    private var activePID: pid_t = 0
    private var applicationObservers: [NSObjectProtocol] = []
    private var focusGeneration = UUID()
    private var loadGeneration = UUID()
    private var scanTask: Task<TypeToClickScanResult, Never>?
    private var loadTask: Task<Void, Never>?
    private var globalMouseMonitor: Any?

    init(service: TypeToClickServicing = TypeToClickService()) {
        self.service = service
        configureSurfaces()
    }

    var isActive: Bool { surfaces.contains { $0.panel.isVisible } }

    func start(in pid: pid_t) {
        guard !isActive else { return }
        preparePresentation(pid: pid)
        logger.info("Starting Type to Click for pid \(pid, privacy: .public) on \(self.surfaces.count, privacy: .public) display(s)")
        setStatus("Finding clickable items…")
        render()
        // Ask for Accessibility before activating Quick Launch. System Settings
        // may come forward for the permission prompt; the overlay must not race
        // that handoff and disappear before its explanation can be read.
        guard service.isAccessibilityTrusted(prompt: true) else {
            targets = []
            setStatus("Allow Quick Launch in Privacy & Security › Accessibility, then press the shortcut again")
            render()
            presentAndCaptureKeyboard()
            return
        }
        presentAndCaptureKeyboard()

        // Accessibility enumeration is IPC-heavy in browsers and Electron
        // apps. Keep it off the main actor so the loading state, Esc, and the
        // global-hotkey toggle remain responsive throughout the scan.
        let generation = UUID()
        loadGeneration = generation
        let service = self.service
        let alphabet = Self.defaultAlphabet
        let scanTask = Task.detached(priority: .userInitiated) {
            service.targets(in: pid, alphabet: alphabet)
        }
        self.scanTask = scanTask
        loadTask = Task { @MainActor [weak self] in
            let scanResult = await scanTask.value
            guard let self,
                  !Task.isCancelled,
                  self.isActive,
                  self.loadGeneration == generation
            else { return }
            self.finishLoading(scanResult)
        }
    }

    /// Gives a failed target lookup a visible, dismissible result instead of
    /// silently making the hotkey look broken.
    func presentMessage(_ message: String) {
        guard !isActive else { return }
        preparePresentation(pid: 0)
        targets = []
        setStatus(message)
        render()
        presentAndCaptureKeyboard()
    }

    func dismiss() {
        guard isActive else { return }
        focusGeneration = UUID()
        loadGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        loadTask?.cancel()
        loadTask = nil
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        applicationObservers = []
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        surfaces.forEach { $0.panel.orderOut(nil) }
        targets = []
        typed = ""
        setStatus(nil)
        let pid = activePID
        activePID = 0
        if pid != 0 {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        }
    }

    private func finishLoading(_ result: TypeToClickScanResult) {
        targets = result.targets.filter { target in
            surfaces.contains { surface in
                surface.view.bounds.intersects(windowRect(for: target.frame, on: surface.panel))
            }
        }
        logger.info("Type to Click loaded \(result.targets.count, privacy: .public) target(s); \(self.targets.count, privacy: .public) are on a visible display; truncated=\(result.wasTruncated, privacy: .public)")
        if targets.isEmpty {
            setStatus("No clickable items found in the front window")
        } else if result.wasTruncated {
            setStatus("Large window: some clickable items are not shown")
        } else {
            setStatus(nil)
        }
        scanTask = nil
        loadTask = nil
        render()
    }

    private func preparePresentation(pid: pid_t) {
        typed = ""
        activePID = pid
        targets = []
        configureSurfaces()
        setStatus(nil)
    }

    /// Rebuild display-local panels on every invocation so connecting,
    /// disconnecting, scaling, or rearranging a display never leaves stale
    /// coordinates. Separate panels are required for mixed scale factors.
    private func configureSurfaces() {
        surfaces.forEach { $0.panel.orderOut(nil) }
        let screens = NSScreen.screens
        primaryTop = screens.first?.frame.maxY ?? 0
        surfaces = screens.map { screen in
            let view = TypeToClickOverlayView()
            let panel = TypeToClickPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isReleasedWhenClosed = false
            panel.contentView = view
            return TypeToClickSurface(screenFrame: screen.frame, panel: panel, view: view)
        }

        let mouseLocation = NSEvent.mouseLocation
        let keySurface = surfaces.first { $0.screenFrame.contains(mouseLocation) }
            ?? surfaces.first
        keyPanel = keySurface?.panel
        let keyHandler: (NSEvent) -> Bool = { [weak self] event in
            self?.handle(event) ?? false
        }
        for surface in surfaces {
            surface.panel.keyHandler = keyHandler
            surface.view.keyHandler = keyHandler
        }
    }

    private func setStatus(_ text: String?) {
        for surface in surfaces {
            surface.view.statusText = surface.panel === keyPanel ? text : nil
            surface.view.statusAnchor = nil
        }
    }

    private func presentAndCaptureKeyboard() {
        let center = NotificationCenter.default
        applicationObservers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.assertKeyboardFocus() }
        })
        // Do not dismiss on didResignActive. Accessory apps can briefly resign
        // while activation settles, and permission prompts intentionally bring
        // System Settings forward. The mode stays open until a click, Esc, or
        // the same global shortcut, matching Homerow's toggle behaviour.
        NSApp.activate(ignoringOtherApps: true)
        surfaces.forEach { $0.panel.orderFrontRegardless() }
        // A physical click changes the underlying UI and makes its hints stale.
        // Let the click pass through, then leave the mode like Homerow.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
        let generation = UUID()
        focusGeneration = generation
        assertKeyboardFocus(generation: generation, attempt: 0)
    }

    /// Activation from a Carbon hotkey is asynchronous. Keep asserting focus
    /// for a short bounded window instead of betting on one run-loop turn.
    private func assertKeyboardFocus(generation: UUID? = nil, attempt: Int = 0) {
        guard let keyPanel,
              keyPanel.isVisible,
              generation == nil || generation == focusGeneration else { return }
        keyPanel.makeKey()
        _ = keyPanel.makeFirstResponder(keyPanel.contentView)
        // Accessory-app activation can take longer than a few run-loop turns
        // when the previous app is busy. Keep trying for two seconds.
        guard (!NSApp.isActive || !keyPanel.isKeyWindow), attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.assertKeyboardFocus(generation: generation, attempt: attempt + 1)
        }
    }

    // MARK: - Key handling

    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:                                   // Esc
            dismiss()
            return true
        case 51:                                   // Delete / Backspace
            typed = String(typed.dropLast())
            render()
            return true
        default:
            guard let character = TypeToClickKeyPolicy.hintCharacter(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
            ) else { return false }
            type(character)
            return true
        }
    }

    private func type(_ character: String) {
        guard !targets.isEmpty else { return }
        typed += character
        setStatus(nil)
        render()
        if let exact = targets.first(where: { $0.hint == typed }) {
            if service.press(exact) {
                dismiss()
            } else {
                typed = ""
                setStatus("That item could not be clicked. Try another hint.")
                render()
            }
        }
    }

    // MARK: - Rendering

    private func render() {
        // Labels-only mode, like Homerow: typing narrows the visible labels
        // instead of repainting non-matches in a second attention-grabbing
        // colour. Backspace restores the previous set.
        var boxes = Array(repeating: [TypeToClickBox](), count: surfaces.count)
        for target in targets where target.hint.hasPrefix(typed) {
            for (index, surface) in surfaces.enumerated() {
                let rect = windowRect(for: target.frame, on: surface.panel)
                if surface.view.bounds.intersects(rect) {
                    boxes[index].append(TypeToClickBox(rect: rect, hint: target.hint))
                }
            }
        }
        for (index, surface) in surfaces.enumerated() {
            surface.view.boxes = boxes[index]
        }
    }

    /// Converts an AX frame (global top-left origin, y down) to one display
    /// panel's local AppKit coordinates (bottom-left origin, y up).
    private func windowRect(for axFrame: CGRect, on panel: NSPanel) -> NSRect {
        TypeToClickCoordinates.panelRect(
            for: axFrame,
            primaryTop: primaryTop,
            panelOrigin: panel.frame.origin
        )
    }
}
