import AppKit
import ApplicationServices
import Synchronization
import XCTest
@testable import QuickLaunch

/// Test time for Type to Click: `now` moves only by the delays the controller
/// sleeps (each sleep still waits for real), so the menu-retry budget and the
/// staleness window count the controller's own steps, never how long a busy
/// machine took to run them.
final class StepClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_000_000))

    var clock: TypeToClickClock {
        TypeToClickClock(
            now: { [self] in current.withLock { $0 } },
            sleep: { [self] duration in
                let start = current.withLock { $0 }
                try? await Task.sleep(for: duration)
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                current.withLock { $0 = max($0, start.addingTimeInterval(seconds)) }
            }
        )
    }
}

/// How long a test waits before calling a hang a failure. Generous: a busy
/// machine may run the controller's steps many times slower, and waiting
/// longer costs a passing test nothing.
private let hangGuard: TimeInterval = 120

final class TypeToClickTests: XCTestCase {

    func testNamedOverlayStartsWithAllTargetsThenNarrowsToFuzzyMatches() {
        let all = ["Save", "Cancel", "File"]
        let matches = ["Save"]

        XCTAssertEqual(
            TypeToClickOverlayPolicy.displayedTargets(
                query: "",
                all: all,
                matches: matches
            ),
            all
        )
        XCTAssertEqual(
            TypeToClickOverlayPolicy.displayedTargets(
                query: "sav",
                all: all,
                matches: matches
            ),
            matches
        )
    }

    func testBadgeCarriesActualNameSelectionAndPulseState() {
        let badge = TypeToClickBadge(
            rect: NSRect(x: 10, y: 20, width: 80, height: 24),
            label: "Save Document",
            isSelected: true,
            isPulsing: true
        )

        XCTAssertEqual(badge.label, "Save Document")
        XCTAssertTrue(badge.isSelected)
        XCTAssertTrue(badge.isPulsing)
    }

    func testIgnoredBranchesKeepTheirVisibleTopLevelMenuItem() {
        XCTAssertTrue(TypeToClickMenuPolicy.shouldCollectResult(
            isMenuBarItem: true,
            isIgnoredBranch: true
        ))
        XCTAssertFalse(TypeToClickMenuPolicy.shouldCollectResult(
            isMenuBarItem: false,
            isIgnoredBranch: true
        ))
        XCTAssertTrue(TypeToClickMenuPolicy.shouldCollectResult(
            isMenuBarItem: false,
            isIgnoredBranch: false
        ))
    }

    func testTopRowAndOpenMenuItemsExposeFramesButClosedCommandsDoNot() {
        let position = CGPoint(x: 72, y: 0)
        let size = CGSize(width: 144, height: 24)
        let expected = CGRect(origin: position, size: size)

        for role in [kAXMenuBarItemRole as String, kAXMenuItemRole as String] {
            XCTAssertEqual(
                TypeToClickMenuPolicy.visibleFrame(
                    role: role,
                    position: position,
                    size: size,
                    hidden: false
                ),
                expected
            )
        }
        XCTAssertNil(TypeToClickMenuPolicy.visibleFrame(
            role: kAXMenuItemRole as String,
            position: CGPoint(x: 0, y: 982),
            size: .zero,
            hidden: false
        ))
        XCTAssertNil(TypeToClickMenuPolicy.visibleFrame(
            role: kAXMenuBarItemRole as String,
            position: position,
            size: size,
            hidden: true
        ))
        XCTAssertNil(TypeToClickMenuPolicy.visibleFrame(
            role: kAXMenuBarItemRole as String,
            position: nil,
            size: size,
            hidden: false
        ))
    }

    func testQueryKeysAllowLingeringHotkeyModifiersButRejectCommandChords() {
        XCTAssertEqual(
            TypeToClickKeyPolicy.queryCharacter(
                charactersIgnoringModifiers: "S",
                modifiers: [.control, .option, .shift]
            ),
            "s"
        )
        XCTAssertNil(TypeToClickKeyPolicy.queryCharacter(
            charactersIgnoringModifiers: "q",
            modifiers: [.command]
        ))
        XCTAssertEqual(TypeToClickKeyPolicy.queryCharacter(
            charactersIgnoringModifiers: " ",
            modifiers: []
        ), " ")
    }

    @MainActor
    func testGlobalCaptureSwallowsAppShortcutsButPassesOnlyItsExitHotkey() {
        let controller = TypeToClickController()
        let exitHotkey = ActionHotkey(
            keyCode: 8,
            modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue
        )
        controller.configureExitHotkey(exitHotkey)

        XCTAssertTrue(controller.handle(
            keyCode: 12,
            charactersIgnoringModifiers: "q",
            modifierRawValue: NSEvent.ModifierFlags.command.rawValue
        ))
        XCTAssertTrue(controller.handle(
            keyCode: 13,
            charactersIgnoringModifiers: "w",
            modifierRawValue: NSEvent.ModifierFlags.command.rawValue
        ))
        XCTAssertFalse(controller.handle(
            keyCode: 8,
            charactersIgnoringModifiers: "c",
            modifierRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue
        ))

        controller.configureExitHotkey(ActionHotkey(
            keyCode: 8,
            modifiers: NSEvent.ModifierFlags([.control, .option, .capsLock]).rawValue
        ))
        XCTAssertFalse(controller.handle(
            keyCode: 8,
            charactersIgnoringModifiers: "c",
            modifierRawValue: NSEvent.ModifierFlags([.control, .option]).rawValue
        ))
    }

    func testEnterModifiersMapToClickActions() {
        XCTAssertEqual(TypeToClickKeyPolicy.action(for: []), .activate)
        XCTAssertEqual(TypeToClickKeyPolicy.action(for: [.control]), .secondaryClick)
        let modifiers: NSEvent.ModifierFlags = [.command, .shift]
        XCTAssertEqual(
            TypeToClickKeyPolicy.action(for: modifiers),
            .click(modifiers: modifiers.rawValue)
        )
    }

    func testAccessibilityFramesConvertToUnionPanelCoordinates() {
        XCTAssertEqual(
            TypeToClickCoordinates.panelRect(
                for: CGRect(x: 100, y: 200, width: 80, height: 30),
                primaryTop: 900,
                panelOrigin: .zero
            ),
            NSRect(x: 100, y: 670, width: 80, height: 30)
        )
        XCTAssertEqual(
            TypeToClickCoordinates.panelRect(
                for: CGRect(x: -1_400, y: 100, width: 100, height: 50),
                primaryTop: 900,
                panelOrigin: CGPoint(x: -1_440, y: 0)
            ),
            NSRect(x: 40, y: 750, width: 100, height: 50)
        )
        // AX uses one global top-left coordinate space anchored to the primary
        // display. Subtracting the AppKit panel origin correctly handles a
        // display mounted above or below the primary; a per-screen top would not.
        XCTAssertEqual(
            TypeToClickCoordinates.panelRect(
                for: CGRect(x: 100, y: -800, width: 100, height: 50),
                primaryTop: 900,
                panelOrigin: CGPoint(x: 0, y: 900)
            ),
            NSRect(x: 100, y: 750, width: 100, height: 50)
        )
        XCTAssertEqual(
            TypeToClickCoordinates.panelRect(
                for: CGRect(x: 100, y: 1_000, width: 100, height: 50),
                primaryTop: 900,
                panelOrigin: CGPoint(x: 0, y: -900)
            ),
            NSRect(x: 100, y: 750, width: 100, height: 50)
        )
    }

    func testPrimaryTopUsesTheZeroOriginDisplayRegardlessOfScreenOrder() {
        let ultrawideAbove = CGRect(x: -932, y: 982, width: 3_440, height: 1_440)
        let builtInPrimary = CGRect(x: 0, y: 0, width: 1_512, height: 982)

        XCTAssertEqual(
            TypeToClickCoordinates.primaryTop(
                screenFrames: [ultrawideAbove, builtInPrimary]
            ),
            982
        )
    }

    func testAccessibilityFramesMapOntoCurrentStackedMixedScaleDisplayLayout() {
        // Tristan's ultrawide is above the built-in primary display. AppKit's
        // screen origin is (-932, 982), while AX reports its menu bar at a
        // negative global y. Scale does not enter this point-space transform.
        XCTAssertEqual(
            TypeToClickCoordinates.panelRect(
                for: CGRect(x: -826, y: -1_440, width: 42, height: 24),
                primaryTop: 982,
                panelOrigin: CGPoint(x: -932, y: 982)
            ),
            NSRect(x: 106, y: 1_416, width: 42, height: 24)
        )

        // A target on the Retina primary remains in that panel's local point
        // space; WindowServer applies each panel's own backing scale.
        XCTAssertEqual(
            TypeToClickCoordinates.panelRect(
                for: CGRect(x: 100, y: 120, width: 80, height: 30),
                primaryTop: 982,
                panelOrigin: .zero
            ),
            NSRect(x: 100, y: 832, width: 80, height: 30)
        )
    }

    func testOpenMenuBadgesUseCompactLeafCommandNames() {
        let element = AXUIElementCreateSystemWide()
        let menuCommand = TypeToClickTarget(
            element: element,
            frame: CGRect(x: 10, y: 10, width: 100, height: 24),
            label: "Ghostty › Check for Updates…",
            searchText: "Ghostty Check for Updates",
            role: kAXMenuItemRole as String,
            actionNames: [kAXPressAction as String],
            kind: .menuItem
        )
        let control = TypeToClickTarget(
            element: element,
            frame: CGRect(x: 10, y: 40, width: 100, height: 24),
            label: "Terminal content area",
            searchText: "Terminal content area",
            role: kAXGroupRole as String,
            actionNames: [kAXPressAction as String],
            kind: .element
        )

        XCTAssertEqual(
            TypeToClickOverlayPolicy.badgeLabel(for: menuCommand),
            "Check for Updates…"
        )
        XCTAssertEqual(
            TypeToClickOverlayPolicy.badgeLabel(for: control),
            "Terminal content area"
        )
    }

    func testSelectedAlternateMenuCommandReplacesSameFrameBadge() {
        let rect = NSRect(x: 10, y: 20, width: 200, height: 24)
        var badges: [TypeToClickBadge] = []
        TypeToClickOverlayPolicy.mergeBadge(
            TypeToClickBadge(
                rect: rect,
                label: "Quit Ghostty",
                isSelected: false,
                isPulsing: false,
                placement: .inside
            ),
            for: .menuItem,
            into: &badges
        )
        TypeToClickOverlayPolicy.mergeBadge(
            TypeToClickBadge(
                rect: rect,
                label: "Quit and Keep Windows",
                isSelected: true,
                isPulsing: false,
                placement: .inside
            ),
            for: .menuItem,
            into: &badges
        )

        XCTAssertEqual(badges.count, 1)
        XCTAssertEqual(badges.first?.label, "Quit and Keep Windows")
        XCTAssertEqual(badges.first?.isSelected, true)
    }

    func testOnlyVisibleEnabledElementsWithPressActionsAreTargets() {
        let size = CGSize(width: 40, height: 20)
        XCTAssertTrue(TypeToClickElementPolicy.isActionable(
            actionNames: [kAXPressAction as String],
            enabled: true,
            hidden: false,
            size: size
        ))
        XCTAssertFalse(TypeToClickElementPolicy.isActionable(
            actionNames: [], enabled: true, hidden: false, size: size
        ))
        XCTAssertTrue(TypeToClickElementPolicy.isActionable(
            actionNames: [],
            role: kAXTextFieldRole as String,
            enabled: true,
            hidden: false,
            size: size
        ))
        XCTAssertFalse(TypeToClickElementPolicy.isActionable(
            actionNames: [kAXPressAction as String], enabled: false, hidden: false, size: size
        ))
        XCTAssertFalse(TypeToClickElementPolicy.isActionable(
            actionNames: [kAXPressAction as String], enabled: true, hidden: true, size: size
        ))
        XCTAssertFalse(TypeToClickElementPolicy.isActionable(
            actionNames: [kAXPressAction as String],
            enabled: true,
            hidden: false,
            size: CGSize(width: 2, height: 20)
        ))
    }

    @MainActor
    func testUntrustedPermissionMessageStaysOpenAndNeverScans() throws {
        _ = NSApplication.shared
        let service = UntrustedTypeToClickService()
        let controller = TypeToClickController(service: service, clock: StepClock().clock)

        controller.start(in: 123)
        // A test that stops early never leaves its overlay for the next one.
        addTeardownBlock { @MainActor in controller.dismiss() }
        let panel = try XCTUnwrap(controller.inputPanel)
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 36, characters: "\r"))

        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(controller.isAwaitingAccessibilityPermission)
        XCTAssertEqual(service.targetCalls, 0)
        controller.retryAccessibilityPermission()
        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(controller.isAwaitingAccessibilityPermission)
        XCTAssertEqual(service.targetCalls, 0)
        controller.dismiss()
        XCTAssertFalse(controller.isActive)
    }

    @MainActor
    func testOneOverlaySurfacePerScreenSurvivesDisplayReconfiguration() throws {
        _ = NSApplication.shared
        let controller = TypeToClickController(service: UntrustedTypeToClickService(), clock: StepClock().clock)
        controller.start(in: 123)
        // A test that stops early never leaves its overlay for the next one.
        addTeardownBlock { @MainActor in controller.dismiss() }

        func visibleSurfaceCount() -> Int {
            NSApp.windows.count { $0 is TypeToClickPanel && $0.isVisible }
        }

        XCTAssertEqual(visibleSurfaceCount(), NSScreen.screens.count)
        let visiblePanels = NSApp.windows.compactMap { window -> TypeToClickPanel? in
            guard let panel = window as? TypeToClickPanel, panel.isVisible else { return nil }
            return panel
        }
        XCTAssertTrue(visiblePanels.allSatisfy {
            $0.level.rawValue > NSWindow.Level.popUpMenu.rawValue
        })
        let statusView = try XCTUnwrap(visiblePanels
            .compactMap { $0.contentView as? TypeToClickOverlayView }
            .first { $0.statusText != nil })
        XCTAssertEqual(statusView.statusAnchor?.x, statusView.bounds.midX)
        XCTAssertEqual(statusView.statusAnchor?.y, 28)
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: NSApp
        )
        XCTAssertEqual(visibleSurfaceCount(), NSScreen.screens.count)
        let reconfiguredPanels = NSApp.windows.compactMap { window -> TypeToClickPanel? in
            guard let panel = window as? TypeToClickPanel, panel.isVisible else { return nil }
            return panel
        }
        XCTAssertTrue(reconfiguredPanels.allSatisfy {
            $0.level.rawValue > NSWindow.Level.popUpMenu.rawValue
        })
        controller.dismiss()
    }

    @MainActor
    func testEscapeAlwaysExitsTheOverlay() throws {
        _ = NSApplication.shared
        let controller = TypeToClickController(service: UntrustedTypeToClickService(), clock: StepClock().clock)
        controller.start(in: 123)
        // A test that stops early never leaves its overlay for the next one.
        addTeardownBlock { @MainActor in controller.dismiss() }
        let panel = try XCTUnwrap(controller.inputPanel)

        panel.sendEvent(try keyEvent(panel: panel, keyCode: 53, characters: "\u{1b}"))

        XCTAssertFalse(controller.isActive)
    }

    @MainActor
    func testReturnDuringInitialScanWithoutAQueryDoesNotAct() async throws {
        _ = NSApplication.shared
        let performed = expectation(description: "no action without a query")
        performed.isInverted = true
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let service = BufferedTypeToClickService(
            frame: CGRect(
                x: screen.frame.minX + 100,
                y: screen.frame.maxY - screen.frame.minY - 130,
                width: 120,
                height: 30
            ),
            performed: performed
        )
        let controller = TypeToClickController(service: service, clock: StepClock().clock)
        controller.start(in: 123)
        // A test that stops early never leaves its overlay for the next one.
        addTeardownBlock { @MainActor in controller.dismiss() }
        let panel = try XCTUnwrap(controller.inputPanel)
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 36, characters: "\r"))

        await fulfillment(of: [performed], timeout: 0.5)
        XCTAssertNil(service.performedAction)
        XCTAssertTrue(controller.isActive)
        controller.dismiss()
    }

    @MainActor
    func testQueryAndEnterAreBufferedWhileAccessibilityScanFinishes() async throws {
        _ = NSApplication.shared
        let performed = expectation(description: "buffered action performed")
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let frame = CGRect(
            x: screen.frame.minX + 100,
            y: screen.frame.maxY - screen.frame.minY - 130,
            width: 120,
            height: 30
        )
        let service = BufferedTypeToClickService(frame: frame, performed: performed)
        let controller = TypeToClickController(service: service, clock: StepClock().clock)
        controller.start(in: 123)
        // A test that stops early never leaves its overlay for the next one.
        addTeardownBlock { @MainActor in controller.dismiss() }
        let panel = try XCTUnwrap(controller.inputPanel)

        for (keyCode, character) in [(1, "s"), (0, "a"), (9, "v"), (14, "e")] {
            panel.sendEvent(try keyEvent(
                panel: panel,
                keyCode: UInt16(keyCode),
                characters: character
            ))
        }
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 36, characters: "\r"))

        await fulfillment(of: [performed], timeout: hangGuard)
        XCTAssertEqual(service.performedAction, .activate)
        controller.dismiss()
    }

    @MainActor
    func testBufferedRefreshActsOnTheItemSelectedBeforeTheRefresh() async throws {
        _ = NSApplication.shared
        let firstScanReturned = expectation(description: "first scan returned")
        let refreshStarted = expectation(description: "refresh started")
        let performed = expectation(description: "selected target performed")
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let service = SelectionPreservingTypeToClickService(
            frame: CGRect(
                x: screen.frame.minX + 100,
                y: screen.frame.maxY - screen.frame.minY - 130,
                width: 120,
                height: 30
            ),
            firstScanReturned: firstScanReturned,
            refreshStarted: refreshStarted,
            performed: performed
        )
        let controller = TypeToClickController(service: service, clock: StepClock().clock)
        controller.start(in: 123)
        // A test that stops early never leaves its overlay for the next one.
        addTeardownBlock { @MainActor in controller.dismiss() }
        let panel = try XCTUnwrap(controller.inputPanel)
        await fulfillment(of: [firstScanReturned], timeout: hangGuard)
        try await Task.sleep(for: .milliseconds(50))

        for (keyCode, character) in [(1, "s"), (0, "a"), (9, "v"), (14, "e")] {
            panel.sendEvent(try keyEvent(
                panel: panel,
                keyCode: UInt16(keyCode),
                characters: character
            ))
        }
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 125, characters: ""))
        panel.sendEvent(try keyEvent(
            panel: panel,
            keyCode: 15,
            characters: "r",
            modifiers: .command
        ))
        await fulfillment(of: [refreshStarted], timeout: hangGuard)
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 36, characters: "\r"))
        service.releaseRefresh()

        await fulfillment(of: [performed], timeout: hangGuard)
        XCTAssertEqual(service.performedLabel, "Save Beta")
        controller.dismiss()
    }

    @MainActor
    func testContinuousModeRetriesUntilOpenedMenuCommandsHaveVisibleBadges() async throws {
        _ = NSApplication.shared
        let menuOpened = expectation(description: "menu bar action performed")
        let visibleCommandsReturned = expectation(description: "late menu geometry rescanned")
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let service = DelayedOpenMenuTypeToClickService(
            frame: CGRect(
                x: screen.frame.minX + 100,
                y: screen.frame.maxY - screen.frame.minY - 130,
                width: 160,
                height: 30
            ),
            menuOpened: menuOpened,
            visibleCommandsReturned: visibleCommandsReturned
        )
        let controller = TypeToClickController(service: service, clock: StepClock().clock)
        controller.start(in: 123)
        // A test that stops early never leaves its overlay for the next one.
        addTeardownBlock { @MainActor in controller.dismiss() }
        let panel = try XCTUnwrap(controller.inputPanel)

        for (keyCode, character) in [(3, "f"), (34, "i"), (37, "l"), (14, "e")] {
            panel.sendEvent(try keyEvent(
                panel: panel,
                keyCode: UInt16(keyCode),
                characters: character
            ))
        }
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 36, characters: "\r"))

        await fulfillment(of: [menuOpened, visibleCommandsReturned], timeout: hangGuard)
        let badgeAppeared = await eventually {
            NSApp.windows
                .compactMap { $0.contentView as? TypeToClickOverlayView }
                .flatMap(\.badges)
                .contains {
                    $0.label == "New Window" && $0.placement == .inside
                }
        }
        XCTAssertTrue(badgeAppeared)
        XCTAssertGreaterThanOrEqual(service.targetCalls, 6)
        XCTAssertTrue(controller.isActive)
        controller.dismiss()
    }

    @MainActor
    func testSingleActionModeDismissesAfterSuccessWithoutRescanning() async throws {
        _ = NSApplication.shared
        let performed = expectation(description: "one action performed")
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let service = SingleActionTypeToClickService(
            frame: CGRect(
                x: screen.frame.minX + 100,
                y: screen.frame.maxY - screen.frame.minY - 130,
                width: 120,
                height: 30
            ),
            performed: performed
        )
        let controller = TypeToClickController(service: service, clock: StepClock().clock)
        controller.configureContinuation(.singleAction)
        controller.start(in: 123)
        // A test that stops early never leaves its overlay for the next one.
        addTeardownBlock { @MainActor in controller.dismiss() }
        let panel = try XCTUnwrap(controller.inputPanel)

        for (keyCode, character) in [(3, "f"), (34, "i"), (37, "l"), (14, "e")] {
            panel.sendEvent(try keyEvent(
                panel: panel,
                keyCode: UInt16(keyCode),
                characters: character
            ))
        }
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 36, characters: "\r"))

        await fulfillment(of: [performed], timeout: hangGuard)
        let dismissed = await eventually { !controller.isActive }
        XCTAssertTrue(dismissed)
        XCTAssertEqual(service.targetCalls, 1)
    }

    @MainActor
    func testTypingAndReturnDuringPulseAreBufferedForTheRescannedStep() async throws {
        _ = NSApplication.shared
        let firstPerformed = expectation(description: "first action performed")
        let secondPerformed = expectation(description: "second action performed")
        let rescanned = expectation(description: "targets rescanned after action")
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let service = ContinuingTypeToClickService(
            frame: CGRect(
                x: screen.frame.minX + 100,
                y: screen.frame.maxY - screen.frame.minY - 130,
                width: 120,
                height: 30
            ),
            firstPerformed: firstPerformed,
            secondPerformed: secondPerformed,
            rescanned: rescanned
        )
        let controller = TypeToClickController(service: service, clock: StepClock().clock)
        controller.start(in: 123)
        // A test that stops early never leaves its overlay for the next one.
        addTeardownBlock { @MainActor in controller.dismiss() }
        let panel = try XCTUnwrap(controller.inputPanel)

        for (keyCode, character) in [(3, "f"), (34, "i"), (37, "l"), (14, "e")] {
            panel.sendEvent(try keyEvent(
                panel: panel,
                keyCode: UInt16(keyCode),
                characters: character
            ))
        }
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 36, characters: "\r"))

        await fulfillment(of: [firstPerformed], timeout: hangGuard)
        // Type the next step while the first target is still pulsing. These
        // keys must be buffered rather than leaked to the controlled app.
        for (keyCode, character) in [(31, "o"), (35, "p"), (14, "e"), (45, "n")] {
            panel.sendEvent(try keyEvent(
                panel: panel,
                keyCode: UInt16(keyCode),
                characters: character
            ))
        }
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 36, characters: "\r"))

        await fulfillment(of: [rescanned, secondPerformed], timeout: hangGuard)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(service.performedLabels, ["File", "Open"])
        controller.dismiss()
    }

    @MainActor
    func testPanelCapturesQueryKeyBeforeFirstResponderDispatch() throws {
        _ = NSApplication.shared
        let panel = TypeToClickPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var received = ""
        panel.keyHandler = { event in
            received = event.charactersIgnoringModifiers ?? ""
            return true
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 1
        ))

        panel.sendEvent(event)

        XCTAssertEqual(received, "s")
    }

    @MainActor
    private func eventually(
        timeout: TimeInterval = hangGuard,
        condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if condition() { return true }
        XCTFail("the wait timed out after \(timeout)s")
        return false
    }

    @MainActor
    private func keyEvent(
        panel: TypeToClickPanel,
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let windowNumber = panel.windowNumber
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
        return try XCTUnwrap(event)
    }
}

private final class UntrustedTypeToClickService: TypeToClickServicing, @unchecked Sendable {
    private(set) var targetCalls = 0
    func isAccessibilityTrusted(prompt: Bool) -> Bool { false }
    func targets(in pid: pid_t) -> TypeToClickScanResult {
        targetCalls += 1
        return TypeToClickScanResult(targets: [], wasTruncated: false)
    }
    func perform(_ action: TypeToClickAction, on target: TypeToClickTarget) -> Bool { false }
}

private final class BufferedTypeToClickService: TypeToClickServicing, @unchecked Sendable {
    private let frame: CGRect
    private let performed: XCTestExpectation
    private let lock = NSLock()
    private var storedAction: TypeToClickAction?

    init(frame: CGRect, performed: XCTestExpectation) {
        self.frame = frame
        self.performed = performed
    }

    var performedAction: TypeToClickAction? {
        lock.withLock { storedAction }
    }

    func isAccessibilityTrusted(prompt: Bool) -> Bool { true }

    func targets(in pid: pid_t) -> TypeToClickScanResult {
        Thread.sleep(forTimeInterval: 0.12)
        let target = TypeToClickTarget(
            element: AXUIElementCreateSystemWide(),
            frame: frame,
            label: "Save",
            searchText: "Save button",
            role: kAXButtonRole as String,
            actionNames: [kAXPressAction as String],
            kind: .element
        )
        return TypeToClickScanResult(targets: [target], wasTruncated: false)
    }

    func perform(_ action: TypeToClickAction, on target: TypeToClickTarget) -> Bool {
        lock.withLock { storedAction = action }
        performed.fulfill()
        return true
    }
}

private final class SelectionPreservingTypeToClickService: TypeToClickServicing, @unchecked Sendable {
    private let frame: CGRect
    private let firstScanReturned: XCTestExpectation
    private let refreshStarted: XCTestExpectation
    private let performed: XCTestExpectation
    private let refreshGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let alphaElement = AXUIElementCreateApplication(111)
    private let betaElement = AXUIElementCreateApplication(222)
    private var scans = 0
    private var label: String?

    init(
        frame: CGRect,
        firstScanReturned: XCTestExpectation,
        refreshStarted: XCTestExpectation,
        performed: XCTestExpectation
    ) {
        self.frame = frame
        self.firstScanReturned = firstScanReturned
        self.refreshStarted = refreshStarted
        self.performed = performed
    }

    var performedLabel: String? { lock.withLock { label } }

    func releaseRefresh() { refreshGate.signal() }

    func isAccessibilityTrusted(prompt: Bool) -> Bool { true }

    func targets(in pid: pid_t) -> TypeToClickScanResult {
        let scan = lock.withLock {
            scans += 1
            return scans
        }
        if scan == 1 {
            firstScanReturned.fulfill()
        } else if scan == 2 {
            // Exactly one refresh is gated: the one this test drives. A
            // third scan must neither fulfil a one-shot expectation twice,
            // which aborts the whole run, nor wait on a gate that is
            // signalled only once, which would hang instead.
            refreshStarted.fulfill()
            refreshGate.wait()
        }
        return TypeToClickScanResult(targets: [
            target(element: alphaElement, label: "Save Able", xOffset: 0),
            target(element: betaElement, label: "Save Beta", xOffset: 160),
        ], wasTruncated: false)
    }

    func perform(_ action: TypeToClickAction, on target: TypeToClickTarget) -> Bool {
        lock.withLock { label = target.label }
        performed.fulfill()
        return true
    }

    private func target(
        element: AXUIElement,
        label: String,
        xOffset: CGFloat
    ) -> TypeToClickTarget {
        TypeToClickTarget(
            element: element,
            frame: frame.offsetBy(dx: xOffset, dy: 0),
            label: label,
            searchText: "\(label) button",
            role: kAXButtonRole as String,
            actionNames: [kAXPressAction as String],
            kind: .element
        )
    }
}

private final class DelayedOpenMenuTypeToClickService: TypeToClickServicing, @unchecked Sendable {
    private let frame: CGRect
    private let menuOpened: XCTestExpectation
    private let visibleCommandsReturned: XCTestExpectation
    private let lock = NSLock()
    private let fileElement = AXUIElementCreateApplication(310)
    private let newWindowElement = AXUIElementCreateApplication(311)
    private var scans = 0

    init(
        frame: CGRect,
        menuOpened: XCTestExpectation,
        visibleCommandsReturned: XCTestExpectation
    ) {
        self.frame = frame
        self.menuOpened = menuOpened
        self.visibleCommandsReturned = visibleCommandsReturned
    }

    var targetCalls: Int { lock.withLock { scans } }

    func isAccessibilityTrusted(prompt: Bool) -> Bool { true }

    func targets(in pid: pid_t) -> TypeToClickScanResult {
        let scan = lock.withLock {
            scans += 1
            return scans
        }
        var targets = [TypeToClickTarget(
            element: fileElement,
            frame: frame,
            label: "File",
            searchText: "File menu bar top row",
            role: kAXMenuBarItemRole as String,
            actionNames: [kAXPressAction as String],
            kind: .menuBarItem
        )]
        if scan >= 2 {
            targets.append(TypeToClickTarget(
                element: newWindowElement,
                frame: scan >= 6 ? frame.offsetBy(dx: 0, dy: 36) : nil,
                label: "File › New Window",
                searchText: "File New Window menu command",
                role: kAXMenuItemRole as String,
                actionNames: [kAXPressAction as String],
                kind: .menuItem
            ))
        }
        if scan == 6 { visibleCommandsReturned.fulfill() }
        return TypeToClickScanResult(targets: targets, wasTruncated: false)
    }

    func perform(_ action: TypeToClickAction, on target: TypeToClickTarget) -> Bool {
        menuOpened.fulfill()
        return true
    }
}

private final class SingleActionTypeToClickService: TypeToClickServicing, @unchecked Sendable {
    private let frame: CGRect
    private let performed: XCTestExpectation
    private let lock = NSLock()
    private var scans = 0

    init(frame: CGRect, performed: XCTestExpectation) {
        self.frame = frame
        self.performed = performed
    }

    var targetCalls: Int { lock.withLock { scans } }

    func isAccessibilityTrusted(prompt: Bool) -> Bool { true }

    func targets(in pid: pid_t) -> TypeToClickScanResult {
        lock.withLock { scans += 1 }
        return TypeToClickScanResult(targets: [
            TypeToClickTarget(
                element: AXUIElementCreateSystemWide(),
                frame: frame,
                label: "File",
                searchText: "File menu",
                role: kAXMenuItemRole as String,
                actionNames: [kAXPressAction as String],
                kind: .menuItem
            ),
        ], wasTruncated: false)
    }

    func perform(_ action: TypeToClickAction, on target: TypeToClickTarget) -> Bool {
        performed.fulfill()
        return true
    }
}

private final class ContinuingTypeToClickService: TypeToClickServicing, @unchecked Sendable {
    private let frame: CGRect
    private let firstPerformed: XCTestExpectation
    private let secondPerformed: XCTestExpectation
    private let rescanned: XCTestExpectation
    private let lock = NSLock()
    private var scans = 0
    private var labels: [String] = []

    init(
        frame: CGRect,
        firstPerformed: XCTestExpectation,
        secondPerformed: XCTestExpectation,
        rescanned: XCTestExpectation
    ) {
        self.frame = frame
        self.firstPerformed = firstPerformed
        self.secondPerformed = secondPerformed
        self.rescanned = rescanned
    }

    var performedLabels: [String] { lock.withLock { labels } }

    func isAccessibilityTrusted(prompt: Bool) -> Bool { true }

    func targets(in pid: pid_t) -> TypeToClickScanResult {
        let shouldFulfillRescan = lock.withLock {
            scans += 1
            return scans == 2
        }
        if shouldFulfillRescan { rescanned.fulfill() }
        let label = shouldFulfillRescan ? "Open" : "File"
        return TypeToClickScanResult(targets: [
            TypeToClickTarget(
                element: AXUIElementCreateSystemWide(),
                frame: frame,
                label: label,
                searchText: "\(label) menu command",
                role: kAXMenuItemRole as String,
                actionNames: [kAXPressAction as String],
                kind: .menuItem
            ),
        ], wasTruncated: false)
    }

    func perform(_ action: TypeToClickAction, on target: TypeToClickTarget) -> Bool {
        let actionNumber = lock.withLock {
            labels.append(target.label)
            return labels.count
        }
        if actionNumber == 1 {
            firstPerformed.fulfill()
        } else if actionNumber == 2 {
            secondPerformed.fulfill()
        }
        return true
    }
}
