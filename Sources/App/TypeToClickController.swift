import AppKit
import ApplicationServices
import OSLog

private func typeToClickKeyEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<TypeToClickController>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    // This tap's run-loop source is installed only on CFRunLoopGetMain().
    dispatchPrecondition(condition: .onQueue(.main))
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.recaptureKeyboard() }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown, let keyEvent = NSEvent(cgEvent: event) else {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = keyEvent.keyCode
    let characters = keyEvent.charactersIgnoringModifiers
    let modifierRawValue = keyEvent.modifierFlags.rawValue
    let handled = MainActor.assumeIsolated {
        controller.handle(
            keyCode: keyCode,
            charactersIgnoringModifiers: characters,
            modifierRawValue: modifierRawValue
        )
    }
    return handled ? nil : Unmanaged.passUnretained(event)
}

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
    static func matchesHotkey(
        _ hotkey: ActionHotkey?,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard let hotkey, hotkey.keyCode == keyCode else { return false }
        let ignoredFlags: NSEvent.ModifierFlags = [.capsLock, .function, .numericPad]
        let normalizedEvent = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(ignoredFlags)
        let normalizedHotkey = NSEvent.ModifierFlags(rawValue: hotkey.modifiers)
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(ignoredFlags)
        return normalizedEvent == normalizedHotkey
    }

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
    /// AppKit places the primary display at the global zero origin. Do not
    /// depend on NSScreen array order when deriving the AX y-axis flip.
    static func primaryTop(screenFrames: [CGRect]) -> CGFloat {
        screenFrames.first(where: { $0.origin == .zero })?.maxY
            ?? screenFrames.first?.maxY
            ?? 0
    }

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

enum TypeToClickOverlayPolicy {
    /// Before typing, expose every visible target. Once a query exists, keep
    /// only its fuzzy matches so the on-screen map narrows with the search.
    static func displayedTargets<T>(query: String, all: [T], matches: [T]) -> [T] {
        TypeToClickSearch.normalize(query).isEmpty ? all : matches
    }

    /// An open native menu already supplies its path context. Keep its badge
    /// compact and aligned with the visible leaf command while search/status
    /// continue to use the full path.
    static func badgeLabel(for target: TypeToClickTarget) -> String {
        guard target.kind == .menuItem else { return target.label }
        return target.label.components(separatedBy: " › ").last ?? target.label
    }

    static func mergeBadge(
        _ badge: TypeToClickBadge,
        for kind: TypeToClickTargetKind,
        into badges: inout [TypeToClickBadge]
    ) {
        guard kind == .menuItem,
              let collision = badges.firstIndex(where: { $0.rect == badge.rect })
        else {
            badges.append(badge)
            return
        }
        if badge.isSelected || badge.isPulsing {
            badges[collision] = badge
        }
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

private struct PendingTypeToClickAction {
    let action: TypeToClickAction
    /// The exact item selected when Return was pressed. A refreshed scan must
    /// preserve this identity rather than silently falling back to rank zero.
    let target: TypeToClickTarget?
    /// Distinguishes intentional type-ahead from Return pressed with no query
    /// or selection during the initial scan.
    let queryWasEmpty: Bool
}

/// A status line and the tone its dot carries. The controller names both, so
/// the view never has to infer a tone by matching the wording.
private struct TypeToClickNotice {
    let text: String
    let tone: TypeToClickStatusTone
}

/// Key codes the overlay handles that `VirtualKey` does not name. One place
/// for the numbers, each matched with the modifier that gives it meaning.
private enum TypeToClickShortcutKey {
    static let controlN: UInt16 = 45
    static let controlP: UInt16 = 35
    static let commandR: UInt16 = 15
}

/// The time Type to Click's budgets and delays run on: the wall clock in the
/// app. A test passes a clock whose `now` moves only by the delays slept, so
/// the retry budget and staleness never depend on how busy the machine is.
struct TypeToClickClock: Sendable {
    var now: @Sendable () -> Date
    /// Returns early when the task is cancelled, as `try? Task.sleep` does.
    var sleep: @Sendable (Duration) async -> Void

    static let system = TypeToClickClock(now: { Date() }, sleep: { try? await Task.sleep(for: $0) })
}

/// Coordinates the Type to Click search overlay. Input fuzzy-searches labels,
/// roles, and the active application's menu hierarchy. Return acts on the best
/// match, then rescans and stays open so several UI steps can be chained.
@MainActor
final class TypeToClickController {
    private static let staleTreeInterval: TimeInterval = 2
    private static let postActionRefreshDelay = Duration.milliseconds(180)
    private static let openedMenuRetryDelay = Duration.milliseconds(140)
    private static let openedMenuRetryBudget: TimeInterval = 1.2
    private static let activationPulseLeadDelay = Duration.milliseconds(120)
    private static let activationPulseTailDelay = Duration.milliseconds(500)
    private static let syntheticClickSuppressionInterval: TimeInterval = 0.7

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
    private var keyboardEventTap: CFMachPort?
    private var keyboardEventTapSource: CFRunLoopSource?
    private var loadGeneration = UUID()
    private var actionGeneration = UUID()
    private var scanTask: Task<TypeToClickScanResult, Never>?
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var postActionRefreshTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var globalEventMonitor: Any?
    private var ignoreMouseEventsUntil = Date.distantPast
    private var lastScanFinishedAt: Date?
    private var pendingAction: PendingTypeToClickAction?
    private var pulsingTarget: TypeToClickTarget?
    private var bufferedPostActionQuery = ""
    private var bufferedPostActionAction: TypeToClickAction?
    private var exitHotkey: ActionHotkey?
    private var continuation: TypeToClickContinuation = .continuous
    private var awaitingOpenedMenuLabel: String?
    private var openedMenuRetryDeadline: Date?
    private var wasTruncated = false
    private var accessibilityTrusted = false
    private var notice: TypeToClickNotice?

    private let clock: TypeToClickClock

    init(service: TypeToClickServicing = TypeToClickService(), clock: TypeToClickClock = .system) {
        self.service = service
        self.clock = clock
        configureSurfaces()
    }

    var isActive: Bool { surfaces.contains { $0.panel.isVisible } }
    /// The panel that takes the keys: a test sends its events here, never
    /// to whichever overlay window happens to be first on screen.
    var inputPanel: TypeToClickPanel? { keyPanel }
    var isCapturingKeyboard: Bool {
        if let keyboardEventTap { return CGEvent.tapIsEnabled(tap: keyboardEventTap) }
        return keyPanel?.isKeyWindow == true
    }
    private(set) var isAwaitingAccessibilityPermission = false

    func configureExitHotkey(_ hotkey: ActionHotkey?) {
        exitHotkey = hotkey
    }

    func configureContinuation(_ continuation: TypeToClickContinuation) {
        self.continuation = continuation
    }

    func start(in pid: pid_t) {
        guard !isActive else { return }
        preparePresentation(pid: pid)
        logger.info("Starting Type to Click for pid \(pid, privacy: .public) on \(self.surfaces.count, privacy: .public) display(s)")
        notice = TypeToClickNotice(text: "Finding controls and menu commands…", tone: .busy)
        render()
        accessibilityTrusted = service.isAccessibilityTrusted(prompt: true)
        guard accessibilityTrusted else {
            isAwaitingAccessibilityPermission = true
            notice = TypeToClickNotice(
                text: "Allow Quick Launch in Privacy & Security › Accessibility, then press the shortcut again",
                tone: .alert
            )
            render()
            presentAndCaptureKeyboard()
            return
        }
        presentAndCaptureKeyboard()
        requestScan(force: true)
    }

    /// Rechecks Accessibility on the same app when the permission message is
    /// visible. The hotkey remains a normal toggle in every other state.
    func retryAccessibilityPermission() {
        guard isActive, isAwaitingAccessibilityPermission, activePID != 0 else { return }
        let pid = activePID
        dismiss()
        start(in: pid)
    }

    /// Keep the global key interceptor live without reactivating Quick Launch.
    /// The controlled app therefore retains menus and field focus between steps.
    func recaptureKeyboard() {
        guard isActive else { return }
        surfaces.forEach { $0.panel.orderFrontRegardless() }
        if let keyboardEventTap {
            CGEvent.tapEnable(tap: keyboardEventTap, enable: true)
        } else {
            capturePanelKeyboard()
        }
    }

    /// Gives a failed target lookup a visible, dismissible result instead of
    /// silently making the hotkey look broken.
    func presentMessage(_ message: String) {
        guard !isActive else { return }
        preparePresentation(pid: 0)
        notice = TypeToClickNotice(text: message, tone: .alert)
        render()
        presentAndCaptureKeyboard()
    }

    func dismiss(reactivateTarget: Bool = true) {
        guard isActive else { return }
        loadGeneration = UUID()
        actionGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        loadTask?.cancel()
        loadTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        postActionRefreshTask?.cancel()
        postActionRefreshTask = nil
        actionTask?.cancel()
        actionTask = nil
        applicationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        applicationObservers = []
        uninstallKeyboardEventTap()
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
        pulsingTarget = nil
        bufferedPostActionQuery = ""
        bufferedPostActionAction = nil
        awaitingOpenedMenuLabel = nil
        openedMenuRetryDeadline = nil
        lastScanFinishedAt = nil
        wasTruncated = false
        accessibilityTrusted = false
        isAwaitingAccessibilityPermission = false
        ignoreMouseEventsUntil = .distantPast
        notice = nil
        setStatus(nil)
        let pid = activePID
        activePID = 0
        if reactivateTarget, pid != 0 {
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
        if targets.isEmpty { notice = findingNotice }
        render()

        let task = Task.detached(priority: .userInitiated) {
            service.targets(in: pid)
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
        let previousSelection = selectedTarget
        targets = result.targets.filter { target in
            guard let frame = target.frame else { return true }
            return surfaces.contains { surface in
                surface.view.bounds.intersects(windowRect(for: frame, on: surface.panel))
            }
        }
        rebuildSearchIndex()
        wasTruncated = result.wasTruncated
        lastScanFinishedAt = clock.now()
        scanTask = nil
        loadTask = nil
        notice = targets.isEmpty
            ? TypeToClickNotice(
                text: "No controls or menu commands found in the active app",
                tone: .alert
            )
            : nil
        updateMatches(resetSelection: true)
        if let previousSelection,
           let refreshedIndex = matches.firstIndex(where: {
               CFEqual($0.element, previousSelection.element)
           }) {
            selectedIndex = refreshedIndex
        }
        logger.info("Type to Click loaded \(result.targets.count, privacy: .public) target(s); \(self.targets.count, privacy: .public) are usable; truncated=\(result.wasTruncated, privacy: .public)")

        if retryOpenedMenuIfNeeded() {
            render()
            return
        }
        if let pending = pendingAction {
            pendingAction = nil
            if pending.target == nil, pending.queryWasEmpty {
                if notice == nil {
                    notice = TypeToClickNotice(
                        text: "Type a control or menu command",
                        tone: .ready
                    )
                }
                render()
            } else {
                performSelected(pending.action, preferredTarget: pending.target)
            }
        } else {
            render()
        }
    }

    /// Some apps publish a menu's AX geometry a beat after the native menu
    /// becomes visible. Retry briefly so an opened dropdown reliably becomes
    /// the next named target map instead of remaining search-only.
    private func retryOpenedMenuIfNeeded() -> Bool {
        guard let menuLabel = awaitingOpenedMenuLabel else { return false }
        let pathPrefix = "\(menuLabel) › "
        if targets.contains(where: {
            $0.kind == .menuItem
                && $0.frame != nil
                && $0.label.hasPrefix(pathPrefix)
        }) {
            awaitingOpenedMenuLabel = nil
            openedMenuRetryDeadline = nil
            return false
        }
        guard let deadline = openedMenuRetryDeadline, clock.now() < deadline else {
            awaitingOpenedMenuLabel = nil
            openedMenuRetryDeadline = nil
            notice = TypeToClickNotice(
                text: "\(menuLabel) commands are not visible yet · ⌘R refresh",
                tone: .alert
            )
            return false
        }

        notice = TypeToClickNotice(
            text: "Waiting for \(menuLabel) menu commands…",
            tone: .busy
        )
        postActionRefreshTask?.cancel()
        postActionRefreshTask = Task { @MainActor [weak self, clock] in
            await clock.sleep(Self.openedMenuRetryDelay)
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.postActionRefreshTask = nil
            self.requestScan(force: true)
        }
        return true
    }

    private var treeIsStale: Bool {
        guard let lastScanFinishedAt else { return true }
        return clock.now().timeIntervalSince(lastScanFinishedAt) > Self.staleTreeInterval
    }

    private func refreshIfStale() {
        if treeIsStale { requestScan(force: false) }
    }

    private func scheduleRefreshAfterScroll() {
        guard activePID != 0, isActive else { return }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self, clock] in
            await clock.sleep(.milliseconds(180))
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.requestScan(force: true)
        }
    }

    private func reconfigureForDisplayChange() {
        guard isActive else { return }
        configureSurfaces()
        surfaces.forEach { $0.panel.orderFrontRegardless() }
        recaptureKeyboard()
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
        pulsingTarget = nil
        bufferedPostActionQuery = ""
        bufferedPostActionAction = nil
        awaitingOpenedMenuLabel = nil
        openedMenuRetryDeadline = nil
        lastScanFinishedAt = nil
        wasTruncated = false
        accessibilityTrusted = false
        isAwaitingAccessibilityPermission = false
        ignoreMouseEventsUntil = .distantPast
        notice = nil
        configureSurfaces()
        setStatus(nil)
    }

    private func configureSurfaces() {
        surfaces.forEach { $0.panel.orderOut(nil) }
        let screens = NSScreen.screens
        primaryTop = TypeToClickCoordinates.primaryTop(
            screenFrames: screens.map(\.frame)
        )
        surfaces = screens.map { screen in
            let view = TypeToClickOverlayView()
            let panel = TypeToClickPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            // The HUD reads the same in both appearances (its tokens do not
            // branch), but the window still needs one so its layer resolves.
            panel.appearance = NSAppearance(named: .darkAqua)
            // Native macOS dropdown menus sit above `.statusBar`. Badges for
            // their commands must be one layer higher or the menu hides them.
            panel.level = NSWindow.Level(
                rawValue: NSWindow.Level.popUpMenu.rawValue + 1
            )
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

    private func setStatus(_ status: TypeToClickNotice?) {
        for surface in surfaces {
            surface.view.statusText = surface.panel === keyPanel ? status?.text : nil
            surface.view.statusTone = status?.tone ?? .ready
            if surface.panel === keyPanel {
                // Native app and File menus occupy the top edge. Keep status
                // at the bottom so it never hides the newly exposed commands.
                surface.view.statusAnchor = NSPoint(
                    x: surface.view.bounds.midX,
                    y: 28
                )
            } else {
                surface.view.statusAnchor = nil
            }
        }
    }

    private func presentAndCaptureKeyboard() {
        let center = NotificationCenter.default
        applicationObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconfigureForDisplayChange() }
        })
        surfaces.forEach { $0.panel.orderFrontRegardless() }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if event.type == .scrollWheel {
                    self.scheduleRefreshAfterScroll()
                } else if clock.now() >= self.ignoreMouseEventsUntil {
                    // Let the physical click choose its own app. Reactivating
                    // the original target here would steal focus back.
                    self.dismiss(reactivateTarget: false)
                }
            }
        }
        if accessibilityTrusted {
            if !installKeyboardEventTap() { capturePanelKeyboard() }
        } else {
            // The permission message appears before an event tap is allowed.
            capturePanelKeyboard()
        }
    }

    /// Accessibility permission lets Type to Click intercept keys without
    /// becoming the active application. Menus and field focus therefore stay
    /// owned by the controlled app while the overlay remains keyboard-driven.
    private func installKeyboardEventTap() -> Bool {
        if let keyboardEventTap {
            CGEvent.tapEnable(tap: keyboardEventTap, enable: true)
            return true
        }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: typeToClickKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        keyboardEventTap = tap
        keyboardEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func uninstallKeyboardEventTap() {
        if let keyboardEventTap {
            CGEvent.tapEnable(tap: keyboardEventTap, enable: false)
            CFMachPortInvalidate(keyboardEventTap)
        }
        if let keyboardEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), keyboardEventTapSource, .commonModes)
        }
        keyboardEventTap = nil
        keyboardEventTapSource = nil
    }

    /// Fallback used only for messages shown before Accessibility permission
    /// exists, or if macOS refuses to create the event tap.
    private func capturePanelKeyboard(attempt: Int = 0) {
        guard let keyPanel, keyPanel.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        keyPanel.makeKey()
        _ = keyPanel.makeFirstResponder(keyPanel.contentView)
        guard !keyPanel.isKeyWindow, attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.capturePanelKeyboard(attempt: attempt + 1)
        }
    }

    // MARK: - Key handling

    fileprivate func handle(_ event: NSEvent) -> Bool {
        handle(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifierRawValue: event.modifierFlags.rawValue
        )
    }

    func handle(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifierRawValue: UInt
    ) -> Bool {
        let modifiers = NSEvent.ModifierFlags(rawValue: modifierRawValue)
            .intersection(.deviceIndependentFlagsMask)
        // The registered Carbon shortcut owns toggling the mode. It is the
        // sole keyDown allowed through to the system while capture is active.
        if TypeToClickKeyPolicy.matchesHotkey(
            exitHotkey,
            keyCode: keyCode,
            modifiers: modifiers
        ) {
            return false
        }
        if VirtualKey(rawValue: keyCode) == .escape { // Esc always exits, including during a pulse.
            dismiss()
            return true
        }
        if actionTask != nil {
            // Type-ahead belongs to the next chained step. Keep it out of the
            // controlled app, then apply it as soon as this pulse completes.
            if VirtualKey(rawValue: keyCode) == .delete {
                bufferedPostActionQuery = String(bufferedPostActionQuery.dropLast())
            } else if VirtualKey.isReturn(keyCode: keyCode) {
                bufferedPostActionAction = TypeToClickKeyPolicy.action(for: modifiers)
            } else if let character = TypeToClickKeyPolicy.queryCharacter(
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                modifiers: modifiers
            ) {
                bufferedPostActionQuery += character
            }
            return true
        }
        switch VirtualKey(rawValue: keyCode) {
        case .return, .keypadEnter:
            requestAction(TypeToClickKeyPolicy.action(for: modifiers))
            return true
        case .delete:
            query = String(query.dropLast())
            notice = targets.isEmpty ? findingNotice : nil
            updateMatches(resetSelection: true)
            refreshIfStale()
            render()
            return true
        case .downArrow:
            moveSelection(by: 1)
            return true
        case .upArrow:
            moveSelection(by: -1)
            return true
        case .tab where !modifiers.contains(.command):
            moveSelection(by: modifiers.contains(.shift) ? -1 : 1)
            return true
        case _ where keyCode == TypeToClickShortcutKey.controlN && modifiers.contains(.control): // Ctrl-N
            moveSelection(by: 1)
            return true
        case _ where keyCode == TypeToClickShortcutKey.controlP && modifiers.contains(.control): // Ctrl-P
            moveSelection(by: -1)
            return true
        case _ where keyCode == TypeToClickShortcutKey.commandR && modifiers.contains(.command): // Cmd-R
            pendingAction = nil
            notice = TypeToClickNotice(text: "Refreshing controls and menu commands…", tone: .busy)
            requestScan(force: true)
            return true
        default:
            guard let character = TypeToClickKeyPolicy.queryCharacter(
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                modifiers: modifiers
            ) else {
                // Type to Click is modal. Never leak unhandled shortcuts such
                // as ⌘Q or ⌘W into the controlled application.
                return true
            }
            query += character
            notice = targets.isEmpty ? findingNotice : nil
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
        if scanTask != nil || postActionRefreshTask != nil {
            pendingAction = PendingTypeToClickAction(
                action: action,
                target: selectedTarget,
                queryWasEmpty: TypeToClickSearch.normalize(query).isEmpty
            )
            notice = TypeToClickNotice(text: "Waiting for the active app…", tone: .busy)
            render()
            return
        }
        if treeIsStale {
            pendingAction = PendingTypeToClickAction(
                action: action,
                target: selectedTarget,
                queryWasEmpty: TypeToClickSearch.normalize(query).isEmpty
            )
            notice = TypeToClickNotice(text: "Refreshing before acting…", tone: .busy)
            requestScan(force: true)
            return
        }
        performSelected(action)
    }

    private func performSelected(
        _ action: TypeToClickAction,
        preferredTarget: TypeToClickTarget? = nil
    ) {
        guard !matches.isEmpty else {
            notice = query.isEmpty
                ? TypeToClickNotice(text: "Type a control or menu command", tone: .ready)
                : TypeToClickNotice(text: "No match for “\(query)”", tone: .alert)
            render()
            return
        }
        let target: TypeToClickTarget
        if let preferredTarget {
            guard let refreshedTarget = matches.first(where: {
                CFEqual($0.element, preferredTarget.element)
            }) else {
                notice = TypeToClickNotice(
                    text: "The selected target changed. Choose it again or press ⌘R to refresh.",
                    tone: .alert
                )
                lastScanFinishedAt = nil
                render()
                return
            }
            target = refreshedTarget
            selectedIndex = matches.firstIndex(where: {
                CFEqual($0.element, refreshedTarget.element)
            }) ?? selectedIndex
        } else {
            target = matches[min(selectedIndex, matches.count - 1)]
        }
        let effectiveAction = target.kind.isMenuTarget ? .activate : action
        let service = self.service
        let generation = UUID()
        actionGeneration = generation
        bufferedPostActionQuery = ""
        bufferedPostActionAction = nil
        ignoreMouseEventsUntil = clock.now().addingTimeInterval(
            Self.syntheticClickSuppressionInterval
        )
        pulsingTarget = target
        notice = TypeToClickNotice(text: "Clicking \(target.label)…", tone: .busy)
        render()
        actionTask = Task { @MainActor [weak self, clock] in
            // Keep the bright pulse visible for one beat before dispatching the
            // Accessibility action, so Return has tangible click feedback.
            await clock.sleep(Self.activationPulseLeadDelay)
            guard let self,
                  !Task.isCancelled,
                  self.isActive,
                  self.actionGeneration == generation
            else { return }
            let task = Task.detached(priority: .userInitiated) {
                service.perform(effectiveAction, on: target)
            }
            let succeeded = await task.value
            // AX focus and coordinate-click attempts can activate the target
            // app even when they fail. Reclaim the key panel immediately so
            // typing never leaks out of Type to Click.
            self.recaptureKeyboard()
            // Hold the pulse after dispatch long enough to read as feedback,
            // while the underlying interface begins its transition.
            await clock.sleep(Self.activationPulseTailDelay)
            guard !Task.isCancelled,
                  self.isActive,
                  self.actionGeneration == generation
            else { return }
            self.actionTask = nil
            self.pulsingTarget = nil
            if succeeded {
                if self.continuation == .continuous {
                    self.continueAfterSuccessfulAction(
                        openedMenuLabel: target.kind == .menuBarItem ? target.label : nil
                    )
                } else {
                    self.dismiss(reactivateTarget: false)
                }
            } else {
                self.notice = TypeToClickNotice(
                    text: "That target changed or could not be actioned. Press ⌘R to refresh.",
                    tone: .alert
                )
                self.lastScanFinishedAt = nil
                self.render()
            }
        }
    }

    private func continueAfterSuccessfulAction(openedMenuLabel: String?) {
        let nextQuery = bufferedPostActionQuery
        let nextAction = bufferedPostActionAction
        bufferedPostActionQuery = ""
        bufferedPostActionAction = nil
        query = nextQuery
        selectedIndex = 0
        targets = []
        matches = []
        searchIndex = TypeToClickSearch.Index(candidates: [])
        pulsingTarget = nil
        awaitingOpenedMenuLabel = openedMenuLabel
        openedMenuRetryDeadline = openedMenuLabel == nil
            ? nil
            : clock.now().addingTimeInterval(Self.openedMenuRetryBudget)
        if let nextAction {
            pendingAction = PendingTypeToClickAction(
                action: nextAction,
                target: nil,
                queryWasEmpty: TypeToClickSearch.normalize(nextQuery).isEmpty
            )
        }
        lastScanFinishedAt = nil
        wasTruncated = false
        notice = TypeToClickNotice(
            text: nextQuery.isEmpty
                ? "Updating controls and menu commands…"
                : "“\(nextQuery)” · updating matches…",
            tone: .busy
        )
        render()
        recaptureKeyboard()

        postActionRefreshTask?.cancel()
        postActionRefreshTask = Task { @MainActor [weak self, clock] in
            await clock.sleep(Self.postActionRefreshDelay)
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.postActionRefreshTask = nil
            self.requestScan(force: true)
        }
    }

    // MARK: - Search and rendering

    private var findingNotice: TypeToClickNotice {
        TypeToClickNotice(
            text: query.isEmpty
                ? "Finding controls and menu commands…"
                : "“\(query)” · finding matches…",
            tone: .busy
        )
    }

    private func rebuildSearchIndex() {
        let candidates = targets.enumerated().map { index, target in
            TypeToClickSearchCandidate(
                id: "\(index):\(target.kind.rawValue):\(target.label)",
                label: target.label,
                searchText: target.searchText,
                role: target.role
            )
        }
        searchIndex = TypeToClickSearch.Index(candidates: candidates)
    }

    private var selectedTarget: TypeToClickTarget? {
        matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil
    }

    private func updateMatches(resetSelection: Bool) {
        matches = searchIndex.rankedIndices(query: query).map { targets[$0] }
        if resetSelection { selectedIndex = 0 }
        if selectedIndex >= matches.count { selectedIndex = max(0, matches.count - 1) }
    }

    private func render() {
        let selected = matches.indices.contains(selectedIndex) ? matches[selectedIndex] : nil
        let displayed = TypeToClickOverlayPolicy.displayedTargets(
            query: query,
            all: targets,
            matches: matches
        )
        var badges = Array(repeating: [TypeToClickBadge](), count: surfaces.count)
        for target in displayed {
            guard let frame = target.frame else { continue }
            for (index, surface) in surfaces.enumerated() {
                let rect = windowRect(for: frame, on: surface.panel)
                guard surface.view.bounds.intersects(rect) else { continue }
                let badge = TypeToClickBadge(
                    rect: rect,
                    label: TypeToClickOverlayPolicy.badgeLabel(for: target),
                    isSelected: selected.map {
                        CFEqual($0.element, target.element)
                    } ?? false,
                    isPulsing: pulsingTarget.map {
                        CFEqual($0.element, target.element)
                    } ?? false,
                    placement: target.kind == .menuItem ? .inside : .above
                )
                // AppKit may expose alternate Option-key commands at one
                // frame. Keep one spatial badge, but let the active fuzzy
                // selection or pulse replace the default visible command.
                TypeToClickOverlayPolicy.mergeBadge(
                    badge,
                    for: target.kind,
                    into: &badges[index]
                )
            }
        }
        for (index, surface) in surfaces.enumerated() {
            surface.view.badges = badges[index]
        }
        setStatus(interactionStatus(selected: selected))
    }

    private func interactionStatus(selected: TypeToClickTarget?) -> TypeToClickNotice? {
        if let notice { return notice }
        guard !targets.isEmpty else {
            return TypeToClickNotice(text: "Finding controls and menu commands…", tone: .busy)
        }
        guard !matches.isEmpty else {
            let warning = wasTruncated ? " · partial scan" : ""
            if query.isEmpty {
                let visibleCount = targets.count(where: { $0.frame != nil })
                return TypeToClickNotice(
                    text: "\(visibleCount) named targets · type to narrow · Esc exits\(warning)",
                    tone: .ready
                )
            }
            return TypeToClickNotice(
                text: "No match for “\(query)” · Delete to edit · ⌘R refresh",
                tone: .alert
            )
        }
        let warning = wasTruncated ? " · partial scan" : ""
        let label = selected?.label ?? ""
        let clipped = label.count > 72 ? String(label.prefix(69)) + "…" : label
        let returnHint = continuation == .continuous
            ? "Return acts and continues"
            : "Return acts once and closes"
        return TypeToClickNotice(
            text: "“\(query)” · \(matches.count) match\(matches.count == 1 ? "" : "es") · Selected: \(clipped) · \(returnHint)\(warning)",
            tone: .ready
        )
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
