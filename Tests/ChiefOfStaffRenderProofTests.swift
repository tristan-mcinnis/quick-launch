// ChiefOfStaffRenderProofTests — render proofs of the pinned Chief of Staff
// conversation in the AI Chat window, dark and light, at the standard size,
// NARROW (0.75 × the window's minimum width), and wide; plus the focused card
// with its keys, a card in Edit, and the rail with the pinned row. PNGs land
// in /tmp/quick-launch-render-proof/cos-*.png for a reviewer to look at.
//
// The standalone ChiefOfStaff.app shipped a thread window that clipped when
// the window was narrow. The narrow check here asks the root view what width
// it takes when offered less than the window's minimum: a view that forced a
// minimum would answer wider than the offer, and overflow.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Chief of Staff render proof", .serialized)
@MainActor
struct ChiefOfStaffRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    static let normal = CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
    static let narrow = CGSize(width: (House.Layout.chatMinWidth * 0.75).rounded(), height: House.Layout.chatHeight)
    static let wide = CGSize(width: 1_400, height: 900)

    private func makeWindow(appearance: AppearancePreference) async throws -> (AIChatWindowModel, ChiefOfStaffModel) {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.autoCopy = false
        settings.historyEnabled = true
        let service = MockQuickService()
        let chat = QuickViewModel(settings: settings, service: service)
        let suite = "ChiefOfStaffRenderProofTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        window.window = FakeAIChatWindow()
        let chiefOfStaff = ChiefOfStaffModel(paths: try CosFixture.home(), runner: RecordingCosRunner(), clock: { cosNow })
        await chiefOfStaff.reload(force: true)
        chat.chiefOfStaff = chiefOfStaff
        chat.chiefOfStaffOpener = { window.openChiefOfStaff(proposalID: $0) }
        window.openChiefOfStaff()
        await service.setResponses([StreamDelta(
            text: "Two cards want you. The **budget** one is the client's: answer it before tomorrow.",
            finishReason: "stop"
        )])
        chat.input = "What should I do first?"
        await chat.submit()
        chat.input = "Draft the quote note too."
        return (window, chiefOfStaff)
    }

    private func key(_ window: AIChatWindowModel, _ key: VirtualKey?, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = []) {
        _ = window.handleChiefOfStaffKey(key: key, characters: characters, modifiers: modifiers)
    }

    @Test func rendersThePinnedConversationSet() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let preference: AppearancePreference = appearance == .darkAqua ? .dark : .light

            // The chat holds the Chief of Staff weakly, as the app's does: the
            // proof keeps each one alive, as the app delegate does.
            let (list, listCos) = try await makeWindow(appearance: preference)
            #expect(list.isChiefOfStaffOpen)
            try Self.save(try Self.render(list, size: Self.normal, appearance: appearance), name: "cos-normal-\(suffix).png")
            try Self.save(try Self.render(list, size: Self.narrow, appearance: appearance), name: "cos-narrow-\(suffix).png")
            // Every section open, at the wide size.
            listCos.expanded = [.waiting, .later, .fyi]
            listCos.isHealthDetailShown = true
            try Self.save(try Self.render(list, size: Self.wide, appearance: appearance), name: "cos-wide-\(suffix).png")
            // Tall enough that every section, the projects strip included, shows.
            try Self.save(try Self.render(list, size: CGSize(width: Self.normal.width, height: 3_400), appearance: appearance), name: "cos-tall-\(suffix).png")

            // ↑ onto the DECIDE card, ⌘L: its keys and the Later menu.
            let (focused, cos) = try await makeWindow(appearance: preference)
            focused.chat.input = ""
            key(focused, .upArrow)
            key(focused, .downArrow)
            #expect(cos.focusedCardID == "cc33dd44")
            key(focused, nil, "l", [.command])
            #expect(cos.laterMenu != nil)
            try Self.save(try Self.render(focused, size: Self.normal, appearance: appearance), name: "cos-focused-\(suffix).png")
            try Self.save(try Self.render(focused, size: Self.narrow, appearance: appearance), name: "cos-focused-narrow-\(suffix).png")
            key(focused, .escape)

            // ⌘E: the DECIDE card's four actions as fields.
            key(focused, nil, "e", [.command])
            #expect(cos.isEditingFocusedCard)
            try Self.save(try Self.render(focused, size: Self.wide, appearance: appearance), name: "cos-edit-\(suffix).png")
            key(focused, .escape)

            // ↓ past the morning brief onto a TODAY row, then ⇧⌘↩ once:
            // its keys and the confirm.
            key(focused, .downArrow)
            key(focused, .downArrow)
            key(focused, .return, nil, [.command, .shift])
            #expect(cos.bulkArmed?.count == 3)
            try Self.save(try Self.render(focused, size: Self.normal, appearance: appearance), name: "cos-today-\(suffix).png")

            // ⌥⌘2: the Board, a card focused; then filtered with its tasks.
            let (board, boardCos) = try await makeWindow(appearance: preference)
            board.chat.input = ""
            key(board, nil, "2", [.command, .option])
            key(board, .upArrow)
            key(board, .rightArrow)
            try Self.save(try Self.render(board, size: Self.wide, appearance: appearance), name: "cos-board-\(suffix).png")
            try Self.save(try Self.render(board, size: Self.narrow, appearance: appearance), name: "cos-board-narrow-\(suffix).png")
            boardCos.setProjectFilter("sample-project")
            await boardCos.perform(.loadTasks(project: "sample-project"))
            boardCos.toggleTasks()
            try Self.save(try Self.render(board, size: Self.wide, appearance: appearance), name: "cos-board-filtered-\(suffix).png")

            // ⌘N: the New task sheet with a project half typed.
            let (sheet, sheetCos) = try await makeWindow(appearance: preference)
            key(sheet, nil, "n", [.command])
            sheetCos.newTask?.title = "Book the readout room"
            sheetCos.newTask?.due = "fri"
            try Self.save(try Self.render(sheet, size: Self.normal, appearance: appearance), name: "cos-new-task-\(suffix).png")

            // The rail: the pinned row first, with its count and no number.
            let (rail, railCos) = try await makeWindow(appearance: preference)
            rail.showRail()
            try Self.save(try Self.render(rail, size: Self.normal, appearance: appearance), name: "cos-rail-\(suffix).png")
            // Contract v1 pages: Activity, Artifacts (a row focused), Charter.
            let (pages, pagesCos) = try await makeWindow(appearance: preference)
            key(pages, nil, "3", [.command, .option])
            await pagesCos.perform(.loadActivity(day: nil))
            try Self.save(try Self.render(pages, size: Self.normal, appearance: appearance), name: "cos-activity-\(suffix).png")
            try Self.save(try Self.render(pages, size: Self.narrow, appearance: appearance), name: "cos-activity-narrow-\(suffix).png")
            key(pages, nil, "4", [.command, .option])
            await pagesCos.perform(.loadArtifacts)
            pagesCos.focusCard(pagesCos.artifacts.first?.id)
            pages.focusCards(pagesCos.artifacts.first?.id)
            try Self.save(try Self.render(pages, size: Self.normal, appearance: appearance), name: "cos-artifacts-\(suffix).png")
            try Self.save(try Self.render(pages, size: Self.narrow, appearance: appearance), name: "cos-artifacts-narrow-\(suffix).png")
            key(pages, nil, "5", [.command, .option])
            await pagesCos.perform(.loadCharter)
            try Self.save(try Self.render(pages, size: Self.normal, appearance: appearance), name: "cos-charter-\(suffix).png")
            pagesCos.openAddRule()
            pagesCos.addRule?.project = "sample-project"
            pagesCos.setAddRuleScope(.project)
            pagesCos.addRule?.text = "Newsletters, unless a client sent them"
            try Self.save(try Self.render(pages, size: Self.narrow, appearance: appearance), name: "cos-charter-narrow-\(suffix).png")

            // After a Do it: the Always offer; and ⌘- on a card: Less, why.
            let (offer, offerCos) = try await makeWindow(appearance: preference)
            offerCos.focusCard("ee55ff66")
            offerCos.lessFocused()
            offerCos.lessPrompt?.why = "Rota questions are Alex's"
            try Self.save(try Self.render(offer, size: Self.normal, appearance: appearance), name: "cos-less-\(suffix).png")
            offerCos.lessPrompt = nil
            // The proof's runner says OK with nothing printed: the run counts.
            await offerCos.perform(.doIt(id: "ee55ff66"))
            #expect(offerCos.rungOffer != nil)
            try Self.save(try Self.render(offer, size: Self.normal, appearance: appearance), name: "cos-always-\(suffix).png")
            try Self.save(try Self.render(offer, size: Self.narrow, appearance: appearance), name: "cos-always-narrow-\(suffix).png")
            // Memory design: a run a crash cut off, one running now, and two
            // learnings that disagree.
            let (states, statesCos) = try await makeWindow(appearance: preference)
            var items = try CosFixture.items()
            var cut = Proposal(
                id: "cut01", project: "sample-project", eventKind: "email", message: "Budget approved.",
                headline: "Log the budget approval", tier: "decide", why: "The last run stopped halfway.",
                actions: [ProposalAction(type: "status_note", fields: ["note": "Budget approved."])]
            )
            cut.outcomeUnknownSince = cosNow
            var busy = Proposal(
                id: "run01", project: "ops-desk", message: "m", headline: "Add the rota task", tier: "today",
                actions: [ProposalAction(type: "task_add", fields: ["title": "Rota"])]
            )
            busy.runningSince = cosNow
            var conflict = Proposal(id: "lc01", eventKind: "learnings", message: "m", headline: "Two of your rules for Sample Project disagree", tier: "today")
            conflict.conflict = Proposal.Conflict(
                scope: "project:sample-project", keys: ["a", "b"],
                texts: ["Charlie's date changes are always DECIDE", "Date changes are FYI unless a client asks"]
            )
            items += [.proposal(turnID: "x1", cut), .proposal(turnID: "x2", busy), .proposal(turnID: "x3", conflict)]
            statesCos.override(items: items, status: statesCos.status)
            statesCos.focusCard("lc01")
            states.focusCards("lc01")
            try Self.save(try Self.render(states, size: CGSize(width: Self.normal.width, height: 2_400), appearance: appearance), name: "cos-states-\(suffix).png")
            try Self.save(try Self.render(states, size: CGSize(width: Self.narrow.width, height: 2_400), appearance: appearance), name: "cos-states-narrow-\(suffix).png")
            withExtendedLifetime([listCos, boardCos, sheetCos, railCos, pagesCos, offerCos, statesCos]) {}
        }
    }

    /// Offered less than the window's minimum width, the root view takes
    /// exactly the offer, in the List and on the Board: nothing forces a
    /// width, so nothing overflows.
    @Test func theRootReflowsAtNarrowWidths() async throws {
        let (window, cos) = try await makeWindow(appearance: .dark)
        key(window, .upArrow, nil, [.option])
        #expect(cos.focusedCardID != nil)
        for mode in [ChiefOfStaffModel.ViewMode.list, .board] {
            cos.viewMode = mode
            for width in [Self.narrow.width, House.Layout.chatMinWidth / 2] {
                let controller = NSHostingController(rootView: AIChatWindowView(model: window))
                let fitted = controller.sizeThatFits(in: CGSize(width: width, height: Self.normal.height))
                #expect(fitted.width <= width + 0.5, "\(mode): the root asked for \(fitted.width) of \(width)")
            }
        }
    }

    /// The pinned conversation over the real `cos` thread and the real
    /// `cos status` and `cos projects`, offscreen and read only: nothing is
    /// sent, decided, or appended. Opt in with QUICK_LAUNCH_COS_LIVE_PROOF=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUICK_LAUNCH_COS_LIVE_PROOF"] == "1"))
    func rendersTheRealThread() async throws {
        var settings = QuickSettings()
        settings.appearance = .dark
        let chat = QuickViewModel(settings: settings, service: MockQuickService())
        let suite = "ChiefOfStaffLiveProof.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        window.window = FakeAIChatWindow()
        let chiefOfStaff = ChiefOfStaffModel(paths: CosPaths.resolve(environment: [:]))
        await chiefOfStaff.reload(force: true)
        chat.chiefOfStaff = chiefOfStaff
        chat.chiefOfStaffOpener = { window.openChiefOfStaff(proposalID: $0) }
        window.openChiefOfStaff()
        #expect(window.isChiefOfStaffOpen)
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            chat.settings.appearance = appearance == .darkAqua ? .dark : .light
            try Self.save(try Self.render(window, size: Self.normal, appearance: appearance), name: "cos-live-\(suffix).png")
        }
        chiefOfStaff.viewMode = .board
        try Self.save(try Self.render(window, size: Self.wide, appearance: .darkAqua), name: "cos-live-board-dark.png")
        chiefOfStaff.viewMode = .activity
        await chiefOfStaff.perform(.loadActivity(day: nil))
        try Self.save(try Self.render(window, size: Self.normal, appearance: .darkAqua), name: "cos-live-activity-dark.png")
        chiefOfStaff.viewMode = .charter
        await chiefOfStaff.perform(.loadCharter)
        try Self.save(try Self.render(window, size: CGSize(width: Self.normal.width, height: 1_600), appearance: .aqua), name: "cos-live-charter-light.png")
        chiefOfStaff.viewMode = .artifacts
        await chiefOfStaff.perform(.loadArtifacts)
        try Self.save(try Self.render(window, size: Self.normal, appearance: .darkAqua), name: "cos-live-artifacts-dark.png")
        print("cos live proof: decide \(chiefOfStaff.decide.map(\.id)) today \(chiefOfStaff.today.map(\.id)) health \(chiefOfStaff.health?.id ?? "none") projects \(chiefOfStaff.projects.count)")
    }

    // MARK: - Rendering

    private static func render(_ model: AIChatWindowModel, size: CGSize, appearance: NSAppearance.Name) throws -> NSImage {
        let root = AIChatWindowView(model: model)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RenderError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func save(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw RenderError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    private enum RenderError: Error { case noBitmap }
}
