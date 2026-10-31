import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

/// The closest testable proxy for hotkey to panel visible: a dismissal, the
/// show-path refresh, and the layout of the launcher on the persistent
/// hosting view the app keeps alive. Drawing is left out of the timed part:
/// offscreen `cacheDisplay` rasterises on the CPU at about 130 ms a frame,
/// which the real panel never does, so it would measure the harness. Fake
/// pasteboard, no history, nothing on screen. Wall-clock, so opt-in on a
/// quiet machine:
/// `QUICK_LAUNCH_PERF=1 swift test --filter ShowPathPerformanceTests`.
@Suite("Show path performance", .mainActorRenderLane,
    .enabled(if: ProcessInfo.processInfo.environment["QUICK_LAUNCH_PERF"] == "1")
)
@MainActor
struct ShowPathPerformanceTests {
    @Test func reopenLayoutStaysWithinOneFrameBudget() throws {
        let clock = ContinuousClock()
        var settings = QuickSettings()
        settings.appearance = .dark
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            applicationCatalog: ApplicationCatalogService(),
            pasteboard: FakePasteboard()
        )
        let host = NSHostingView(rootView: OverlayView(viewModel: vm).frame(width: vm.currentPanelWidth))
        host.appearance = NSAppearance(named: .darkAqua)
        Self.layOut(host)
        try Self.draw(host)

        var reopens: [Duration] = []
        for round in 0..<40 {
            vm.input = round.isMultiple(of: 2) ? "s" : "fin"
            Self.layOut(host)
            let start = clock.now
            vm.reset(.layers)
            vm.clearTransientDisplay()
            vm.refreshOpenChatFromStore()
            Self.layOut(host)
            reopens.append(start.duration(to: clock.now))
        }
        reopens.sort()
        let median = reopens[reopens.count / 2]
        let p90 = reopens[reopens.count * 9 / 10]
        print("PERF show-path reopen-to-layout median=\(median) p90=\(p90) n=\(reopens.count)")
        #expect(median < .milliseconds(16), "a reopen should lay out inside one 60 Hz frame")
    }

    private static func layOut(_ host: NSHostingView<some View>) {
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 1), height: max(size.height, 200)))
        host.layoutSubtreeIfNeeded()
    }

    private static func draw(_ host: NSHostingView<some View>) throws {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw CocoaError(.featureUnsupported)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
    }
}
