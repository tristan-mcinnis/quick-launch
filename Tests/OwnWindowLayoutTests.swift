import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Quick Launch laying out its own AI Chat window.
///
/// The external path can never reach that window: its target resolver skips
/// this process on purpose, and Accessibility is the wrong actuator for an
/// app's own window. These cover the routing (which window a command lands
/// on), the coordinate conversion the two paths share, and the real AppKit
/// setter against a real window.
@Suite("Own window layout", .serialized)
@MainActor
struct OwnWindowLayoutTests {
    private let target = SelectionTarget(processIdentifier: 42, applicationName: "Pages")

    // MARK: - Routing

    @Test func theChatsOwnPaletteAlwaysLaysOutTheChatWindow() {
        let own = FakeOwnWindow()
        let windows = FakeWindowManager()
        let vm = QuickViewModel(windowManager: windows)
        let host = Self.makeChatHost(vm)
        vm.ownWindowLayout = own
        vm.rememberSelectionTarget(target)
        // Not in front: the chat's own palette does not care.
        own.isFrontmost = false
        #expect(vm.isAIChatWindow)

        vm.performSystemCommand(vm.systemCommands.first { $0.itemID == "window.firstThird" }!)

        #expect(own.appliedLayout == .firstThird)
        #expect(windows.appliedLayout == nil)
        withExtendedLifetime(host) {}
    }

    /// `prepareForExternalAction` on the chat's view model hides the chat
    /// window for a screen capture. Calling it here would order out the very
    /// window being laid out.
    @Test func theChatWindowIsNeverHiddenToLayItOut() {
        let own = FakeOwnWindow()
        let vm = QuickViewModel(windowManager: FakeWindowManager())
        let host = Self.makeChatHost(vm)
        vm.ownWindowLayout = own
        var hidden = false
        vm.prepareForExternalAction = { hidden = true }

        vm.performSystemCommand(vm.systemCommands.first { $0.itemID == "window.leftHalf" }!)

        #expect(own.appliedLayout == .leftHalf)
        #expect(!hidden)
        withExtendedLifetime(host) {}
    }

    @Test func theLauncherLaysOutTheChatWindowWhenItIsInFront() {
        let own = FakeOwnWindow()
        let windows = FakeWindowManager()
        let vm = QuickViewModel(windowManager: windows)
        vm.ownWindowLayout = own
        vm.rememberSelectionTarget(target)
        own.isFrontmost = true
        var hidden = false
        vm.prepareForExternalAction = { hidden = true }

        vm.performSystemCommand(vm.systemCommands.first { $0.itemID == "window.firstThird" }!)

        #expect(own.appliedLayout == .firstThird)
        #expect(windows.appliedLayout == nil)
        // The launcher panel still gets out of the way, as it does for an
        // external window.
        #expect(hidden)
    }

    @Test func theLauncherLaysOutTheAppBehindWhenTheChatIsNotInFront() {
        let own = FakeOwnWindow()
        let windows = FakeWindowManager()
        let vm = QuickViewModel(windowManager: windows)
        vm.ownWindowLayout = own
        vm.rememberSelectionTarget(target)
        own.isFrontmost = false

        vm.performSystemCommand(vm.systemCommands.first { $0.itemID == "window.firstThird" }!)

        #expect(windows.appliedLayout == .firstThird)
        #expect(windows.appliedTarget == target)
        #expect(own.appliedLayout == nil)
    }

    /// With no chat window built yet there is nothing to lay out, and the
    /// external path must still work exactly as before.
    @Test func noChatWindowMeansTheExternalPathIsUnchanged() {
        let windows = FakeWindowManager()
        let vm = QuickViewModel(windowManager: windows)
        vm.ownWindowLayout = nil
        vm.rememberSelectionTarget(target)

        vm.performSystemCommand(vm.systemCommands.first { $0.itemID == "window.centerThird" }!)

        #expect(windows.appliedLayout == .centerThird)
    }

    @Test func movesRouteToTheOwnWindowToo() {
        let own = FakeOwnWindow()
        let vm = QuickViewModel(windowManager: FakeWindowManager())
        let host = Self.makeChatHost(vm)
        vm.ownWindowLayout = own

        vm.performSystemCommand(vm.systemCommands.first { $0.itemID == "window.center" }!)

        #expect(own.appliedMove == .center)
        withExtendedLifetime(host) {}
    }

    /// A refused command reports against the window that refused it, and
    /// never silently falls through to resize something else.
    @Test func aRefusedOwnWindowCommandSaysSoAndStopsThere() {
        let own = FakeOwnWindow()
        own.result = false
        let windows = FakeWindowManager()
        let vm = QuickViewModel(windowManager: windows)
        let host = Self.makeChatHost(vm)
        vm.ownWindowLayout = own
        vm.rememberSelectionTarget(target)

        vm.performSystemCommand(vm.systemCommands.first { $0.itemID == "window.leftHalf" }!)

        #expect(vm.errorMessage?.contains("AI Chat") == true)
        #expect(windows.appliedLayout == nil)
        withExtendedLifetime(host) {}
    }

    // MARK: - Shared coordinate space

    @Test func theTopLeftConversionRoundTrips() {
        let appKit = CGRect(x: 120, y: 340, width: 800, height: 600)
        let ax = AXSpace.axFrame(ofAppKit: appKit)
        #expect(AXSpace.appKitFrame(ofAX: ax) == appKit)
        #expect(ax.width == appKit.width)
        #expect(ax.height == appKit.height)
        #expect(ax.minX == appKit.minX)
    }

    // MARK: - The real setter

    @Test func aThirdIsAThirdOfTheDisplayItIsOn() throws {
        let screen = try #require(NSScreen.screens.first)
        let window = Self.makeWindow(on: screen)
        defer { window.close() }
        let layout = OwnWindowLayout { window }

        #expect(layout.apply(.firstThird))

        let visible = screen.visibleFrame
        #expect(abs(window.frame.minX - visible.minX) <= 2)
        #expect(abs(window.frame.height - visible.height) <= 2)
        #expect(abs(window.frame.width - (visible.width / 3).rounded()) <= 2)
    }

    /// The same cycle the external path has: Left Half repeated steps to two
    /// thirds and then a third, because the geometry is shared.
    @Test func repeatingLeftHalfCyclesToTwoThirdsThenAThird() throws {
        let screen = try #require(NSScreen.screens.first)
        let window = Self.makeWindow(on: screen)
        defer { window.close() }
        let layout = OwnWindowLayout { window }

        #expect(layout.apply(.leftHalf))
        let half = window.frame.width
        #expect(layout.apply(.leftHalf))
        let twoThirds = window.frame.width
        #expect(layout.apply(.leftHalf))
        let third = window.frame.width

        let visible = screen.visibleFrame
        #expect(abs(half - (visible.width / 2).rounded()) <= 2)
        #expect(abs(twoThirds - (visible.width * 2 / 3).rounded()) <= 2)
        #expect(abs(third - (visible.width / 3).rounded()) <= 2)
        #expect(twoThirds > half)
        #expect(third < half)
    }

    @Test func restoreNeedsSomethingToRestore() throws {
        let screen = try #require(NSScreen.screens.first)
        let window = Self.makeWindow(on: screen)
        defer { window.close() }
        let layout = OwnWindowLayout { window }

        #expect(!layout.move(.restore))

        let before = window.frame
        #expect(layout.apply(.rightHalf))
        #expect(layout.move(.restore))
        #expect(abs(window.frame.width - before.width) <= 2)
        #expect(abs(window.frame.height - before.height) <= 2)
    }

    @Test func aWindowThatWasNeverBuiltRefusesEverything() {
        let layout = OwnWindowLayout { nil }
        #expect(!layout.isFrontmost)
        #expect(!layout.apply(.leftHalf))
        #expect(!layout.move(.center))
        #expect(layout.windowName == "the Quick Launch window")
    }

    /// Makes `vm` the AI Chat window's view model, the way the app does:
    /// `isAIChatWindow` is derived from the host, which is held weakly, so
    /// the returned model must outlive the assertions.
    private static func makeChatHost(_ vm: QuickViewModel) -> AIChatWindowModel {
        let suite = "OwnWindowLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AIChatWindowModel(chat: vm, defaults: defaults)
    }

    private static func makeWindow(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: 900, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Chat"
        window.isReleasedWhenClosed = false
        // Small on purpose: these cover the layout arithmetic, not the chat
        // window's own minimum, which would clamp a third on a narrow display.
        window.contentMinSize = NSSize(width: 200, height: 150)
        return window
    }
}

@MainActor
private final class FakeOwnWindow: OwnWindowLaying {
    var isFrontmost = false
    var windowName = "AI Chat"
    var result = true
    var appliedLayout: WindowLayout?
    var appliedMove: WindowMove?

    func apply(_ layout: WindowLayout) -> Bool {
        appliedLayout = layout
        return result
    }

    func move(_ move: WindowMove) -> Bool {
        appliedMove = move
        return result
    }
}

@MainActor
private final class FakeWindowManager: WindowManaging {
    var isAccessibilityTrusted = true
    var appliedLayout: WindowLayout?
    var appliedMove: WindowMove?
    var appliedTarget: SelectionTarget?

    func apply(_ layout: WindowLayout, to target: SelectionTarget) -> Bool {
        appliedLayout = layout
        appliedTarget = target
        return true
    }

    func move(_ move: WindowMove, target: SelectionTarget) -> Bool {
        appliedMove = move
        appliedTarget = target
        return true
    }
}
