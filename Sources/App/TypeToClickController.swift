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
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

enum TypeToClickKeyPolicy {
    static func queryCharacter(
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> String? {
        let normalizedModifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        // Control and Option may still be held from the global hotkey. Command
        // remains reserved for refresh and normal app/menu shortcuts.
        guard !normalizedModifiers.contains(.command),
              let character = charactersIgnoringModifiers?.lowercased(),
              character.count == 1,
              let scalar = character.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar)
        else { return nil }
        return character
    }

    static func action(for modifiers: NSEvent.ModifierFlags) -> TypeToClickAction {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        if flags.contains(.control) { return .secondaryClick }
        let clickModifiers = flags.intersection([.command, .shift, .option])
        return clickModifiers.isEmpty
            ? .activate
            : .click(modifiers: clickModifiers.rawValue)
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

/// Coordinates the Type to Click overlay. Gold hints remain the low-keystroke
/// path, while the same input also fuzzy-searches labels, roles, and the active
/// application's menu hierarchy. A selected target is actioned only on Enter,
/// enabling right-click and modifier-click without ambiguous auto-activation.
@MainActor
final class TypeToClickController {
    static let defaultAlphabet = "sadfjklewcmpgh"
    private static let staleTreeInterval: TimeInterval = 2

    private let service: TypeToClickServicing
    private let logger = Logger(
        subsystem: "com.tristanmcinnis.quick-launch",
        category: "TypeToClick"
    )
    private var surfaces: [TypeToClickSurface] = []
    private weak var keyPanel: TypeToClickPanel?
    private var primaryTop: CGFloat = 0

    private var targets: [TypeToClickTarget] = []
    private var matches: [TypeToClickTarget] = []
    private var searchIndex = TypeToClickSearch.Index(candidates: [])
    private var query = ""
    private var selectedIndex = 0
    private var activePID: pid_t = 0
    private var applicationObservers: [NSObjectProtocol] = []
    private var focusGeneration = UUID()
    private var loadGeneration = UUID()
    private var actionGeneration = UUID()
    private var scanTask: Task<TypeToClickScanResult, Never>?
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var globalEventMonitor: Any?
    private var lastScanFinishedAt: Date?
    private var pendingAction: TypeToClickAction?
    private var wasTruncated = false
    private var accessibilityTrusted = false
    private var notice: String?

    init(service: TypeToClickServicing = TypeToClickService()) {
        self.service = service
        configureSurfaces()
    }

    var isActive: Bool { surfaces.contains { $0.panel.isVisible } }

    func start(in pid: pid_t) {
        guard !isActive else { return }
        preparePresentation(pid: pid)
        logger.info("Starting Type to Click for pid \(pid, privacy: .public) on \(self.surfaces.count, privacy: .public) display(s)")
        notice = "Finding controls and menu commands…"
        render()
        accessibilityTrusted = service.isAccessibilityTrusted(prompt: true)
        guard accessibilityTrusted else {
            notice = "Allow Quick Launch in Privacy & Security › Accessibility, then press the shortcut again"
            render()
            presentAndCaptureKeyboard()
            return
        }
        presentAndCaptureKeyboard()
        requestScan(force: true)
    }

    /// Gives a failed target lookup a visible, dismissible result instead of
    /// silently making the hotkey look broken.
    func presentMessage(_ message: String) {
        guard !isActive else { return }
        preparePresentation(pid: 0)
        notice = message
        render()
        presentAndCaptureKeyboard()
    }

    func dismiss() {
        guard isActive else { return }
        focusGeneration = UUID()
        loadGeneration = UUID()
        actionGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        loadTask?.cancel()
        loadTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        actionTask?.cancel()
        actionTask = nil
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        applicationObservers = []
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        surfaces.forEach { $0.panel.orderOut(nil) }
        targets = []
        matches = []
        searchIndex = TypeToClickSearch.Index(candidates: [])
        query = ""
        selectedIndex = 0
        pendingAction = nil
        lastScanFinishedAt = nil
        wasTruncated = false
        accessibilityTrusted = false
        notice = nil
        setStatus(nil)
        let pid = activePID
        activePID = 0
        if pid != 0 {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        }
    }

    // MARK: - Enumeration and freshness

    private func requestScan(force: Bool) {
        guard accessibilityTrusted, activePID != 0, isActive else { return }
        if scanTask != nil, !force { return }

        let generation = UUID()
        loadGeneration = generation
        scanTask?.cancel()
        loadTask?.cancel()
        let service = self.service
        let pid = activePID
        let alphabet = Self.defaultAlphabet
        if targets.isEmpty { notice = "Finding controls and menu commands…" }
        render()

        let task = Task.detached(priority: .userInitiated) {
            service.targets(in: pid, alphabet: alphabet)
        }
        scanTask = task
        loadTask = Task { @MainActor [weak self] in
            let result = await task.value
            guard let self,
                  !Task.isCancelled,
                  self.isActive,
                  self.loadGeneration == generation
            else { return }
            self.finishLoading(result)
        }
    }

    private func finishLoading(_ result: TypeToClickScanResult) {
        targets = result.targets.filter { target in
            guard let frame = target.frame else { return true }
            return surfaces.contains { surface in
                surface.view.bounds.intersects(windowRect(for: frame, on: surface.panel))
            }
        }
        rebuildSearchIndex()
        wasTruncated = result.wasTruncated
        lastScanFinishedAt = Date()
        scanTask = nil
        loadTask = nil
        notice = targets.isEmpty
            ? "No controls or menu commands found in the active app"
            : nil
        updateMatches(resetSelection: true)
        logger.info("Type to Click loaded \(result.targets.count, privacy: .public) target(s); \(self.targets.count, privacy: .public) are usable; truncated=\(result.wasTruncated, privacy: .public)")

        if let action = pendingAction {
            pendingAction = nil
            performSelected(action)
        } else {
            render()
        }
    }

    private var treeIsStale: Bool {
        guard let lastScanFinishedAt else { return true }
        return Date().timeIntervalSince(lastScanFinishedAt) > Self.staleTreeInterval
    }

    private func refreshIfStale() {
        if treeIsStale { requestScan(force: false) }
    }

    private func scheduleRefreshAfterScroll() {
        guard activePID != 0, isActive else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.requestScan(force: true)
        }
    }

    private func reconfigureForDisplayChange() {
        guard isActive else { return }
        configureSurfaces()
        surfaces.forEach { $0.panel.orderFrontRegardless() }
        assertKeyboardFocus()
        requestScan(force: true)
    }

    // MARK: - Presentation

    private func preparePresentation(pid: pid_t) {
        query = ""
        selectedIndex = 0
        activePID = pid
        targets = []
        matches = []
        searchIndex = TypeToClickSearch.Index(candidates: [])
        pendingAction = nil
        lastScanFinishedAt = nil
        wasTruncated = false
        accessibilityTrusted = false
        notice = nil
        configureSurfaces()
        setStatus(nil)
    }

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
            if surface.panel === keyPanel {
                let local = surface.panel.convertPoint(fromScreen: NSEvent.mouseLocation)
                surface.view.statusAnchor = NSPoint(
                    x: min(max(local.x, 180), max(180, surface.view.bounds.maxX - 180)),
                    y: min(max(local.y - 72, 32), max(32, surface.view.bounds.maxY - 32))
                )
            } else {
                surface.view.statusAnchor = nil
            }
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
        applicationObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconfigureForDisplayChange() }
        })
        NSApp.activate(ignoringOtherApps: true)
        surfaces.forEach { $0.panel.orderFrontRegardless() }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                if event.type == .scrollWheel {
                    self?.scheduleRefreshAfterScroll()
                } else {
                    self?.dismiss()
                }
            }
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
        guard (!NSApp.isActive || !keyPanel.isKeyWindow), attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.assertKeyboardFocus(generation: generation, attempt: attempt + 1)
        }
    }

    // MARK: - Key handling

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: // Esc
            dismiss()
            return true
        case 36, 76: // Return / keypad Enter
            requestAction(TypeToClickKeyPolicy.action(for: modifiers))
            return true
        case 51: // Delete / Backspace
            query = String(query.dropLast())
            if !targets.isEmpty { notice = nil }
            updateMatches(resetSelection: true)
            refreshIfStale()
            render()
            return true
        case 125: // Down
            moveSelection(by: 1)
            return true
        case 126: // Up
            moveSelection(by: -1)
            return true
        case 48: // Tab / Shift-Tab
            moveSelection(by: modifiers.contains(.shift) ? -1 : 1)
            return true
        case 45 where modifiers.contains(.control): // Ctrl-N
            moveSelection(by: 1)
            return true
        case 35 where modifiers.contains(.control): // Ctrl-P
            moveSelection(by: -1)
            return true
        case 15 where modifiers.contains(.command): // Cmd-R
            pendingAction = nil
            notice = "Refreshing controls and menu commands…"
            requestScan(force: true)
            return true
        default:
            guard let character = TypeToClickKeyPolicy.queryCharacter(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                modifiers: modifiers
            ) else { return false }
            query += character
            if !targets.isEmpty { notice = nil }
            updateMatches(resetSelection: true)
            refreshIfStale()
            render()
            return true
        }
    }

    private func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + matches.count) % matches.count
        render()
    }

    private func requestAction(_ action: TypeToClickAction) {
        guard actionTask == nil else { return }
        guard accessibilityTrusted else {
            render()
            return
        }
        if scanTask != nil {
            pendingAction = action
            notice = "Waiting for the active app…"
            render()
            return
        }
        if treeIsStale {
            pendingAction = action
            notice = "Refreshing before acting…"
            requestScan(force: true)
            return
        }
        performSelected(action)
    }

    private func performSelected(_ action: TypeToClickAction) {
        guard !matches.isEmpty else {
            notice = query.isEmpty
                ? "Type a gold hint, control name, or menu command"
                : "No match for “\(query)”"
            render()
            return
        }
        let target = matches[min(selectedIndex, matches.count - 1)]
        let effectiveAction = target.kind == .menuItem ? .activate : action
        let service = self.service
        let generation = UUID()
        actionGeneration = generation
        notice = "Acting on \(target.label)…"
        render()
        let task = Task.detached(priority: .userInitiated) {
            service.perform(effectiveAction, on: target)
        }
        actionTask = Task { @MainActor [weak self] in
            let succeeded = await task.value
            guard let self,
                  !Task.isCancelled,
                  self.isActive,
                  self.actionGeneration == generation
            else { return }
            self.actionTask = nil
            if succeeded {
                self.dismiss()
            } else {
                self.notice = "That target changed or could not be actioned. Press ⌘R to refresh."
                self.lastScanFinishedAt = nil
                self.render()
            }
        }
    }

    // MARK: - Search and rendering

    private func rebuildSearchIndex() {
        let candidates = targets.enumerated().map { index, target in
            TypeToClickSearchCandidate(
                id: "\(index):\(target.kind.rawValue):\(target.hint ?? ""):\(target.label)",
                hint: target.hint,
                label: target.label,
                searchText: target.searchText,
                role: target.role,
                isSpatial: target.frame != nil
            )
        }
        searchIndex = TypeToClickSearch.Index(candidates: candidates)
    }

    private func updateMatches(resetSelection: Bool) {
        matches = searchIndex.rankedIndices(query: query).map { targets[$0] }
        if resetSelection { selectedIndex = 0 }
        if selectedIndex >= matches.count { selectedIndex = max(0, matches.count - 1) }
    }

    private func render() {
        var boxes = Array(repeating: [TypeToClickBox](), count: surfaces.count)
        let selected = matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil
        for target in matches {
            guard let frame = target.frame, let hint = target.hint else { continue }
            for (index, surface) in surfaces.enumerated() {
                let rect = windowRect(for: frame, on: surface.panel)
                if surface.view.bounds.intersects(rect) {
                    boxes[index].append(TypeToClickBox(
                        rect: rect,
                        hint: hint,
                        isSelected: selected.map { CFEqual($0.element, target.element) } ?? false
                    ))
                }
            }
        }
        for (index, surface) in surfaces.enumerated() {
            surface.view.boxes = boxes[index]
        }
        setStatus(interactionStatus(selected: selected))
    }

    private func interactionStatus(selected: TypeToClickTarget?) -> String? {
        if let notice { return notice }
        guard !targets.isEmpty else { return "Finding controls and menu commands…" }
        guard !matches.isEmpty else {
            return query.isEmpty
                ? "No visible controls. Type a menu command or press ⌘R to refresh."
                : "No match for “\(query)” · Delete to edit · ⌘R refresh"
        }
        let warning = wasTruncated ? " · partial scan" : ""
        if query.isEmpty {
            let visibleCount = targets.count(where: { $0.frame != nil })
            return "\(visibleCount) controls · type a gold hint, name, or menu command · Return to act\(warning)"
        }
        let label = selected?.label ?? ""
        let clipped = label.count > 72 ? String(label.prefix(69)) + "…" : label
        return "“\(query)” · \(matches.count) match\(matches.count == 1 ? "" : "es") · \(clipped) · Return to act\(warning)"
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
