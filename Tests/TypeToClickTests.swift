import AppKit
import ApplicationServices
import XCTest
@testable import QuickLaunch

final class TypeToClickTests: XCTestCase {

    func testHintsEmpty() {
        XCTAssertEqual(HintGenerator.hints(count: 0, alphabet: "abc"), [])
        XCTAssertEqual(HintGenerator.hints(count: 3, alphabet: ""), [])
    }

    func testSingleLetterHintsWhenFewEnough() {
        XCTAssertEqual(HintGenerator.hints(count: 3, alphabet: "abc"), ["a", "b", "c"])
        XCTAssertEqual(HintGenerator.hints(count: 2, alphabet: "abc"), ["a", "b"])
    }

    func testSingleCharacterAlphabetCannotHangOrCreateDuplicateHints() {
        XCTAssertEqual(HintGenerator.hints(count: 1, alphabet: "a"), ["a"])
        XCTAssertEqual(HintGenerator.hints(count: 2, alphabet: "a"), [])
        XCTAssertEqual(HintGenerator.hints(count: 2, alphabet: "aaa"), [])
    }

    func testAllHintsShareLengthForLargerCounts() {
        // 8 targets over a 3-char alphabet: 3 < 8 <= 9, so 2-char hints throughout.
        let hints = HintGenerator.hints(count: 8, alphabet: "abc")
        XCTAssertEqual(hints.count, 8)
        XCTAssertTrue(hints.allSatisfy { $0.count == 2 })
    }

    func testHintsAreUniqueAndNonPrefix() {
        let hints = HintGenerator.hints(count: 40, alphabet: "sadfjklewcmpgh")
        XCTAssertEqual(Set(hints).count, 40)
        for hint in hints {
            // No hint may be a strict prefix of another (unambiguous typing).
            let prefixes = hints.filter { $0.hasPrefix(hint) }
            XCTAssertEqual(prefixes, [hint], "\(hint) collides with \(prefixes)")
        }
    }

    func testCoverageForLargeCount() {
        let hints = HintGenerator.hints(count: 200, alphabet: "sadfjklewcmpgh")
        XCTAssertEqual(hints.count, 200)
        XCTAssertTrue(hints.allSatisfy { !$0.isEmpty })
    }

    func testVisibleMenuBarItemsReceiveHintsWithoutChargingClosedCommands() {
        XCTAssertEqual(
            HintGenerator.hints(
                forSpatialTargets: [true, true, false, true, false],
                alphabet: "abc"
            ),
            ["a", "b", nil, "c", nil]
        )
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

    func testOnlyTopLevelMenuBarItemsExposeSpatialFrames() {
        let position = CGPoint(x: 72, y: 0)
        let size = CGSize(width: 44, height: 24)
        let expected = CGRect(origin: position, size: size)

        XCTAssertEqual(
            TypeToClickMenuPolicy.topLevelFrame(
                role: kAXMenuBarItemRole as String,
                position: position,
                size: size,
                hidden: false
            ),
            expected
        )
        XCTAssertNil(TypeToClickMenuPolicy.topLevelFrame(
            role: kAXMenuItemRole as String,
            position: position,
            size: size,
            hidden: false
        ))
        XCTAssertNil(TypeToClickMenuPolicy.topLevelFrame(
            role: kAXMenuBarItemRole as String,
            position: position,
            size: size,
            hidden: true
        ))
        XCTAssertNil(TypeToClickMenuPolicy.topLevelFrame(
            role: kAXMenuBarItemRole as String,
            position: nil,
            size: size,
            hidden: false
        ))
    }

    func testHintKeysAllowLingeringHotkeyModifiersButRejectCommandChords() {
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
        let controller = TypeToClickController(service: service)

        controller.start(in: 123)
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0 is TypeToClickPanel && $0.isVisible
        } as? TypeToClickPanel)
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 36, characters: "\r"))

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(service.targetCalls, 0)
        controller.dismiss()
        XCTAssertFalse(controller.isActive)
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
        let controller = TypeToClickController(service: service)
        controller.start(in: 123)
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0 is TypeToClickPanel && $0.isVisible
        } as? TypeToClickPanel)

        for (keyCode, character) in [(1, "s"), (0, "a"), (9, "v"), (14, "e")] {
            panel.sendEvent(try keyEvent(
                panel: panel,
                keyCode: UInt16(keyCode),
                characters: character
            ))
        }
        panel.sendEvent(try keyEvent(panel: panel, keyCode: 36, characters: "\r"))

        await fulfillment(of: [performed], timeout: 2)
        XCTAssertEqual(service.performedAction, .activate)
        controller.dismiss()
    }

    @MainActor
    func testPanelCapturesHintKeyBeforeFirstResponderDispatch() throws {
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
    func targets(in pid: pid_t, alphabet: String) -> TypeToClickScanResult {
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

    func targets(in pid: pid_t, alphabet: String) -> TypeToClickScanResult {
        Thread.sleep(forTimeInterval: 0.12)
        let target = TypeToClickTarget(
            element: AXUIElementCreateSystemWide(),
            hint: "sa",
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
