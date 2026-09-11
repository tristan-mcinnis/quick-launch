// QuickAIResizeTests: Phase B1 (docs/ai-chat-plan-20260911.md, 4.2): the
// Quick AI surface can be dragged larger and remembers its size. The size
// math (minimum, the display's maximum, the remembered size, root search
// untouched, reset), its persistence, the frame placement that hangs a
// sized surface from the launcher's top edge, and the panel's resizability
// per surface.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Quick AI resize", .serialized)
@MainActor
struct QuickAIResizeTests {

    private static let large = CGSize(width: 1100, height: 760)
    /// A 1440 × 900 display less a 25 pt menu bar.
    private static let laptop = CGRect(x: 0, y: 0, width: 1440, height: 875)

    private func make(configure: (inout QuickSettings) -> Void = { _ in }) -> QuickViewModel {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        configure(&settings)
        return QuickViewModel(settings: settings, service: MockQuickService())
    }

    // MARK: - Size math

    @Test func quickAIOpensAtTheStandardSize() {
        let vm = make()
        vm.openQuickAI()
        #expect(QuickAISize.standard.cgSize == CGSize(width: 750, height: 475))
        #expect(vm.quickAISize == QuickAISize.standard.cgSize)
        #expect(vm.currentPanelWidth == House.Layout.panelWidth)
        #expect(vm.estimatedWindowHeight == House.Layout.quickAIHeight)
    }

    @Test func aRememberedSizeIsTheQuickAISurfaceAndRecentChatsSize() {
        let vm = make { $0.quickAISize = QuickAISize(Self.large) }
        vm.currentConversation = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: InferenceProvider.deepSeekDefaultModel,
            messages: [QuickMessage(role: .user, content: "hi"), QuickMessage(role: .assistant, content: "Hello.")]
        )
        vm.openQuickAI()
        #expect(vm.currentPanelWidth == 1100)
        #expect(vm.estimatedWindowHeight == 760)
        vm.openRecentChats()
        #expect(vm.isRecentChatsPresented)
        #expect(vm.currentPanelWidth == 1100, "Recent Chats is the same window")
        #expect(vm.estimatedWindowHeight == 760)
    }

    @Test func rootSearchIgnoresTheRememberedSize() {
        let standard = make()
        let sized = make { $0.quickAISize = QuickAISize(Self.large) }
        #expect(!sized.isQuickAIPresented)
        #expect(sized.currentPanelWidth == PanelSizing.panelWidth)
        #expect(sized.estimatedWindowHeight == standard.estimatedWindowHeight)
        // Back from Quick AI, root search is measured again.
        sized.openQuickAI()
        #expect(sized.estimatedWindowHeight == 760)
        sized.closeQuickAI()
        #expect(sized.currentPanelWidth == PanelSizing.panelWidth)
        #expect(sized.estimatedWindowHeight == standard.estimatedWindowHeight)
    }

    @Test func aFinishedDragIsRememberedOnlyOnTheQuickAISurface() {
        let vm = make()
        #expect(!vm.rememberQuickAISize(Self.large), "root search is never user-sized")
        #expect(vm.settings.quickAISize == .standard)

        vm.openQuickAI()
        #expect(vm.rememberQuickAISize(Self.large))
        #expect(vm.settings.quickAISize == QuickAISize(Self.large))
        #expect(vm.currentPanelWidth == 1100)
        #expect(vm.estimatedWindowHeight == 760)
        #expect(!vm.rememberQuickAISize(Self.large), "the same size stores nothing")
    }

    @Test func aSizeUnderTheMinimumIsHeldAtTheMinimum() {
        let vm = make()
        vm.openQuickAI()
        #expect(!vm.rememberQuickAISize(CGSize(width: 600, height: 300)), "all of it is the minimum")
        #expect(vm.settings.quickAISize == .standard)
        #expect(vm.rememberQuickAISize(CGSize(width: 900, height: 400)))
        #expect(vm.settings.quickAISize == QuickAISize(width: 900, height: 475))

        let bad = QuickAISize(width: .nan, height: -.infinity).atLeastStandard
        #expect(bad == .standard, "a value that is not a number falls back to the standard")
    }

    @Test func theDisplayCapsTheSizeAtItsVisibleFrameLessTheMargin() {
        let limits = PanelSizing.userResizeLimits(isQuickAIPresented: true, visibleFrame: Self.laptop)
        #expect(limits?.minimum == CGSize(width: 750, height: 475))
        #expect(limits?.maximum == CGSize(width: 1416, height: 851))
        #expect(limits?.clamp(CGSize(width: 3000, height: 2000)) == CGSize(width: 1416, height: 851))
        #expect(limits?.clamp(CGSize(width: 100, height: 100)) == CGSize(width: 750, height: 475))
        #expect(limits?.clamp(Self.large) == Self.large)

        // A display too small for the minimum keeps the minimum: the limits
        // never cross.
        let tiny = PanelSizing.userResizeLimits(
            isQuickAIPresented: true,
            visibleFrame: CGRect(x: 0, y: 0, width: 700, height: 400)
        )
        #expect(tiny?.maximum == CGSize(width: 750, height: 475))
    }

    /// A size stored on a larger display is held to this one before the
    /// resize pass compares it with the window, and it lands on exactly the
    /// frame the display caps it to. So the pass sees no difference and
    /// never re-applies (and re-hangs) the frame on each observation tick.
    @Test func aStoredSizeFromALargerDisplayIsHeldToTheFrameThisDisplayGives() {
        let top = ScreenPlacement.anchoredTop(visibleFrame: Self.laptop, inputHeight: 58)
        let stored = CGSize(width: 2400, height: 1400)
        let placed = PanelSizing.quickAIPlacedSize(stored, visibleFrame: Self.laptop)
        #expect(placed == CGSize(width: 1416, height: 851))
        let hung = ScreenPlacement.frameHanging(
            from: top, height: stored.height, width: stored.width, centreX: 720,
            within: Self.laptop, risingToFit: true
        )
        #expect(hung.size == placed, "the target is the frame already on screen: nothing is re-applied")

        // Through the view model, as the AppDelegate reads it.
        let vm = make { $0.quickAISize = QuickAISize(stored) }
        vm.openQuickAI()
        let target = PanelSizing.quickAIPlacedSize(
            CGSize(width: vm.currentPanelWidth, height: vm.estimatedWindowHeight),
            visibleFrame: Self.laptop
        )
        #expect(target == hung.size)
        #expect(vm.settings.quickAISize == QuickAISize(stored), "the stored size waits for the larger display")

        // A size that fits passes untouched, and the minimum holds.
        #expect(PanelSizing.quickAIPlacedSize(Self.large, visibleFrame: Self.laptop) == Self.large)
        #expect(PanelSizing.quickAIPlacedSize(CGSize(width: 10, height: 10), visibleFrame: Self.laptop)
            == CGSize(width: 750, height: 475))
    }

    @Test func rootSearchHasNoResizeLimits() {
        #expect(PanelSizing.userResizeLimits(isQuickAIPresented: false, visibleFrame: Self.laptop) == nil)
    }

    // MARK: - Reset

    @Test func resetIsOfferedInCommandKOnlyOnAResizedSurface() {
        let vm = make()
        vm.openQuickAI()
        #expect(vm.quickAISurfaceActions.isEmpty, "nothing to reset at 750 × 475")

        vm.rememberQuickAISize(Self.large)
        #expect(vm.quickAISurfaceActions == [.resetSize])
        #expect(QuickAISurfaceAction.resetSize.title == "Reset Quick AI Size")
        #expect(QuickAISurfaceAction.resetSize.detail == "Back to 750 × 475")

        vm.handleCommandK()
        #expect(vm.isActionPalettePresented)
        let before = vm.actionPaletteEntryCount
        #expect(vm.paletteSurfaceActions == [.resetSize])
        vm.actionQuery = "reset size"
        #expect(vm.paletteSurfaceActions == [.resetSize], "the palette search finds it")
        vm.actionQuery = "zzzz"
        #expect(vm.paletteSurfaceActions.isEmpty)
        vm.actionQuery = ""
        #expect(vm.actionPaletteEntryCount == before)

        vm.performQuickAISurfaceAction(.resetSize)
        #expect(!vm.isActionPalettePresented, "running it closes the palette")
        #expect(vm.settings.quickAISize == .standard)
        #expect(vm.currentPanelWidth == 750)
        #expect(vm.estimatedWindowHeight == 475)
        #expect(vm.quickAISurfaceActions.isEmpty)

        // Root search never offers it, whatever the size.
        vm.rememberQuickAISize(Self.large)
        vm.closeQuickAI()
        #expect(vm.quickAISurfaceActions.isEmpty)
    }

    // MARK: - Persistence

    @Test func theSizeSurvivesARelaunch() {
        let defaults = UserDefaults(suiteName: "com.quicklaunch.tests.\(UUID().uuidString)")!
        var settings = QuickSettings()
        #expect(settings.quickAISize == .standard)
        settings.quickAISize = QuickAISize(Self.large)
        settings.save(to: defaults)

        let loaded = QuickSettings.load(from: defaults)
        #expect(loaded.quickAISize == QuickAISize(Self.large))
        #expect(loaded.configurationVersion == 24, "a new key needs no migration")

        let vm = make { $0 = loaded }
        vm.openQuickAI()
        #expect(vm.currentPanelWidth == 1100)
        #expect(vm.estimatedWindowHeight == 760)
    }

    @Test func aBlobWithoutASizeOrWithABadOneDecodesToTheStandard() throws {
        // Written before the surface was resizable.
        struct Legacy: Encodable {
            var configurationVersion = 24
            var autoCopy = false
        }
        let legacy = try JSONDecoder().decode(QuickSettings.self, from: JSONEncoder().encode(Legacy()))
        #expect(legacy.quickAISize == .standard)

        // Hand-edited: too small, and not a size at all. Neither costs the
        // other settings.
        let small = Data(#"{"configurationVersion":24,"autoCopy":false,"quickAISize":{"width":300,"height":200}}"#.utf8)
        let decodedSmall = try JSONDecoder().decode(QuickSettings.self, from: small)
        #expect(decodedSmall.quickAISize == .standard)
        #expect(decodedSmall.autoCopy == false)

        let wide = Data(#"{"configurationVersion":24,"quickAISize":{"width":1200,"height":100}}"#.utf8)
        #expect(try JSONDecoder().decode(QuickSettings.self, from: wide).quickAISize
            == QuickAISize(width: 1200, height: 475))

        let malformed = Data(#"{"configurationVersion":24,"autoCopy":false,"quickAISize":"big"}"#.utf8)
        let decodedMalformed = try JSONDecoder().decode(QuickSettings.self, from: malformed)
        #expect(decodedMalformed.quickAISize == .standard)
        #expect(decodedMalformed.autoCopy == false, "a bad size never resets the rest")
    }

    // MARK: - Frame placement

    @Test func aSizedSurfaceHangsFromTheAnchorAndRisesOnlyWhenItMustFit() {
        let top = ScreenPlacement.anchoredTop(visibleFrame: Self.laptop, inputHeight: 58)
        #expect(top == 467)

        // The standard surface fits under the anchor: the top stays put.
        let standard = ScreenPlacement.frameHanging(
            from: top, height: 440, width: 750, centreX: 720, within: Self.laptop, risingToFit: true
        )
        #expect(standard.maxY == 467)
        #expect(standard.height == 440)

        // Taller than the room under the anchor (455): the top rises just
        // enough, the bottom sits on the margin, and nothing is cut.
        let tall = ScreenPlacement.frameHanging(
            from: top, height: 760, width: 1100, centreX: 720, within: Self.laptop, risingToFit: true
        )
        #expect(tall.minY == 12)
        #expect(tall.height == 760)
        #expect(tall.maxY == 772)
        #expect(tall.width == 1100)
        #expect(tall.midX == 720)

        // Taller than the whole display: it fills it, margin to margin.
        let huge = ScreenPlacement.frameHanging(
            from: top, height: 2000, width: 3000, centreX: 720, within: Self.laptop, risingToFit: true
        )
        #expect(huge.minY == 12)
        #expect(huge.maxY == 863)
        #expect(huge.width == 1416)
        #expect(huge.minX == 12)

        // Root search never rises: its field stays on the anchor.
        let root = ScreenPlacement.frameHanging(
            from: top, height: 760, width: 750, centreX: 720, within: Self.laptop
        )
        #expect(root.maxY == 467)
        #expect(root.height == 455)
    }

    // MARK: - A live drag stays on the display

    /// The standard surface hung on the laptop. Inside the 12 pt margin the
    /// usable area is x 12...1428, y 12...863.
    private static let hung = CGRect(x: 345, y: 12, width: 750, height: 475)

    @Test func theEdgesADragMovesAreReadFromWhereThePointerStarts() {
        let frame = Self.hung
        #expect(ScreenPlacement.DragEdges(pointer: CGPoint(x: frame.midX, y: frame.minY + 2), frame: frame).vertical == .bottom)
        #expect(ScreenPlacement.DragEdges(pointer: CGPoint(x: frame.midX, y: frame.maxY - 2), frame: frame).vertical == .top)
        #expect(ScreenPlacement.DragEdges(pointer: CGPoint(x: frame.minX + 2, y: frame.midY), frame: frame).horizontal == .left)
        #expect(ScreenPlacement.DragEdges(pointer: CGPoint(x: frame.maxX - 2, y: frame.midY), frame: frame).horizontal == .right)
        #expect(ScreenPlacement.DragEdges(pointer: CGPoint(x: frame.maxX, y: frame.minY), frame: frame)
            == ScreenPlacement.DragEdges(horizontal: .right, vertical: .bottom), "a corner moves both")
    }

    @Test func aBottomEdgeDragStopsAboveTheDock() {
        // The panel hangs at mid-screen: its top stays at 467 while the
        // bottom edge comes down. The Dock sits under the visible frame.
        let frame = CGRect(x: 345, y: 200, width: 750, height: 475)
        let edges = ScreenPlacement.DragEdges(horizontal: .right, vertical: .bottom)
        let room = ScreenPlacement.dragRoom(from: frame, moving: edges, within: Self.laptop)
        #expect(room.height == frame.maxY - 12)
        let limits = PanelSizing.userResizeLimits(isQuickAIPresented: true, visibleFrame: Self.laptop)
        let size = limits?.clamp(CGSize(width: 750, height: 851), room: room)
        #expect(size?.height == 663)
        #expect(frame.maxY - (size?.height ?? 0) == 12, "the bottom edge stops on the margin")
    }

    @Test func aTopEdgeDragStopsUnderTheMenuBar() {
        let frame = CGRect(x: 345, y: 27, width: 750, height: 475)
        let edges = ScreenPlacement.DragEdges(horizontal: .left, vertical: .top)
        let room = ScreenPlacement.dragRoom(from: frame, moving: edges, within: Self.laptop)
        let limits = PanelSizing.userResizeLimits(isQuickAIPresented: true, visibleFrame: Self.laptop)
        let size = limits?.clamp(CGSize(width: 750, height: 2000), room: room)
        #expect(size?.height == 836)
        #expect(frame.minY + (size?.height ?? 0) == 863, "the top edge stops 12 pt under the menu bar")
    }

    @Test func sideEdgeDragsStopAtTheScreenSides() {
        let frame = CGRect(x: 345, y: 27, width: 750, height: 475)
        let limits = PanelSizing.userResizeLimits(isQuickAIPresented: true, visibleFrame: Self.laptop)

        let left = ScreenPlacement.dragRoom(
            from: frame, moving: .init(horizontal: .left, vertical: .bottom), within: Self.laptop
        )
        let leftSize = limits?.clamp(CGSize(width: 1400, height: 475), room: left)
        #expect(leftSize?.width == 1083)
        #expect(frame.maxX - (leftSize?.width ?? 0) == 12, "the left edge stops on the margin")

        let right = ScreenPlacement.dragRoom(
            from: frame, moving: .init(horizontal: .right, vertical: .bottom), within: Self.laptop
        )
        let rightSize = limits?.clamp(CGSize(width: 1400, height: 475), room: right)
        #expect(rightSize?.width == 1083)
        #expect(frame.minX + (rightSize?.width ?? 0) == 1428, "the right edge stops on the margin")

        // A drag inside the room passes untouched.
        #expect(limits?.clamp(CGSize(width: 900, height: 480), room: right) == CGSize(width: 900, height: 480))
    }

    @Test func aFrameAlreadyPastTheMarginCanShrinkButNotGrow() {
        // Moved by its background so its bottom sits under the Dock.
        let frame = CGRect(x: 345, y: -40, width: 800, height: 500)
        let room = ScreenPlacement.dragRoom(
            from: frame, moving: .init(horizontal: .right, vertical: .bottom), within: Self.laptop
        )
        #expect(room.height == 500, "never less than the frame itself")
        let limits = PanelSizing.userResizeLimits(isQuickAIPresented: true, visibleFrame: Self.laptop)
        #expect(limits?.clamp(CGSize(width: 800, height: 700), room: room).height == 500)
        #expect(limits?.clamp(CGSize(width: 800, height: 480), room: room).height == 480)
        // The end of the drag fits the frame back inside the display.
        let fitted = ScreenPlacement.clamped(frame: frame, within: Self.laptop)
        #expect(fitted.minY == 12)
        #expect(fitted.size == frame.size)
    }

    // MARK: - Root search keeps its place

    /// A drag of the left edge alone moves the frame's centre. Leaving the
    /// resized surface (Escape to root search) and Reset Quick AI Size both
    /// centre on the launcher's anchor again, so the search field never
    /// moves sideways.
    @Test func leavingOrResettingAOneEdgeDragCentresOnTheAnchor() {
        let top = ScreenPlacement.anchoredTop(visibleFrame: Self.laptop, inputHeight: 58)
        let anchor = ScreenPlacement.PanelAnchor(top: top, centreX: 720, visibleFrame: Self.laptop)
        let vm = make()
        vm.openQuickAI()
        let opened = anchor.frame(
            width: vm.currentPanelWidth, height: vm.estimatedWindowHeight,
            current: .zero, keepsCurrentCentre: vm.keepsUserSizedFrame, risingToFit: true
        )
        #expect(opened.midX == 720)

        // Left edge only, 750 to 1050: the right edge stays put.
        let dragged = CGRect(x: opened.maxX - 1050, y: opened.minY, width: 1050, height: opened.height)
        #expect(dragged.midX == 570)
        vm.rememberQuickAISize(dragged.size)
        #expect(vm.keepsUserSizedFrame, "Quick AI at the dragged size stays where the drag left it")
        let kept = anchor.frame(
            width: vm.currentPanelWidth, height: vm.estimatedWindowHeight,
            current: dragged, keepsCurrentCentre: vm.keepsUserSizedFrame, risingToFit: true
        )
        #expect(kept.midX == dragged.midX)

        // Escape to root search.
        vm.closeQuickAI()
        #expect(!vm.keepsUserSizedFrame)
        let root = anchor.frame(
            width: vm.currentPanelWidth, height: vm.estimatedWindowHeight,
            current: dragged, keepsCurrentCentre: vm.keepsUserSizedFrame, risingToFit: false
        )
        #expect(root.midX == 720)
        #expect(root.maxY == top)

        // Reset Quick AI Size from the dragged frame.
        vm.openQuickAI()
        vm.performQuickAISurfaceAction(.resetSize)
        #expect(!vm.keepsUserSizedFrame)
        let reset = anchor.frame(
            width: vm.currentPanelWidth, height: vm.estimatedWindowHeight,
            current: dragged, keepsCurrentCentre: vm.keepsUserSizedFrame, risingToFit: true
        )
        #expect(reset.midX == 720)
        #expect(reset.size == CGSize(width: 750, height: 475))
    }

    // MARK: - The panel

    @Test func thePanelIsResizableOnlyWhileQuickAIIsUp() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 58),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let quickAI = PanelSizing.userResizeLimits(isQuickAIPresented: true, visibleFrame: Self.laptop)
        panel.applyUserResizeLimits(quickAI)
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.minSize == CGSize(width: 750, height: 475))
        #expect(panel.maxSize == CGSize(width: 1416, height: 851))

        panel.applyUserResizeLimits(PanelSizing.userResizeLimits(isQuickAIPresented: false, visibleFrame: Self.laptop))
        #expect(!panel.styleMask.contains(.resizable), "root search is not user-sized")
        #expect(panel.styleMask.contains(.fullSizeContentView))
        #expect(panel.minSize == .zero)
        #expect(panel.maxSize == KeyablePanel.unlimitedSize)
    }
}
