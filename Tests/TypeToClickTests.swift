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

    func testHintKeysAllowLingeringHotkeyModifiersButRejectCommandChords() {
        XCTAssertEqual(
            TypeToClickKeyPolicy.hintCharacter(
                charactersIgnoringModifiers: "S",
                modifiers: [.control, .option, .shift]
            ),
            "s"
        )
        XCTAssertNil(TypeToClickKeyPolicy.hintCharacter(
            charactersIgnoringModifiers: "q",
            modifiers: [.command]
        ))
        XCTAssertNil(TypeToClickKeyPolicy.hintCharacter(
            charactersIgnoringModifiers: "!",
            modifiers: []
        ))
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
    func testUntrustedPermissionMessageStaysOpenUntilExplicitDismiss() {
        _ = NSApplication.shared
        let controller = TypeToClickController(service: UntrustedTypeToClickService())

        controller.start(in: 123)

        XCTAssertTrue(controller.isActive)
        controller.dismiss()
        XCTAssertFalse(controller.isActive)
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
}

private final class UntrustedTypeToClickService: TypeToClickServicing, @unchecked Sendable {
    func isAccessibilityTrusted(prompt: Bool) -> Bool { false }
    func targets(in pid: pid_t, alphabet: String) -> TypeToClickScanResult {
        TypeToClickScanResult(targets: [], wasTruncated: false)
    }
    func press(_ target: TypeToClickTarget) -> Bool { false }
}
