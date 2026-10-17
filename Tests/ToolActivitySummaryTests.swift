import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Tool activity summary")
struct ToolActivitySummaryTests {
    private static func line(_ name: String, _ state: ToolActivitySummary.State = .done) -> ToolActivitySummary.Line {
        ToolActivitySummary.Line(text: "Used \(name)", symbol: "globe", name: name, state: state)
    }

    @Test func noLinesDrawNothing() {
        let summary = ToolActivitySummary.summarize([])
        #expect(summary.folded.isEmpty)
        #expect(summary.exposed.isEmpty)
        #expect(summary.headline == nil)
    }

    @Test func oneLineStaysAPlainLine() {
        let summary = ToolActivitySummary.summarize([Self.line("memory")])
        #expect(!summary.isGroup)
        #expect(summary.folded.map(\.name) == ["memory"])
    }

    @Test func manyLinesFoldIntoOneHeadlineNamingEachToolOnce() {
        let two = ToolActivitySummary.summarize([Self.line("memory"), Self.line("vault"), Self.line("memory")])
        #expect(two.headline == "Used memory and vault")
        #expect(two.folded.count == 3)
        let three = ToolActivitySummary.summarize(["web", "memory", "vault"].map { Self.line($0) })
        #expect(three.headline == "Used web, memory and vault")
    }

    @Test func moreThanThreeNamesEndWithAndMore() {
        let summary = ToolActivitySummary.summarize(["web", "memory", "vault", "skills", "today"].map { Self.line($0) })
        #expect(summary.headline == "Used web, memory, vault and more")
    }

    @Test func theHeadlineNeverPassesEightyCharacters() {
        let long = ["a", "b"].map { Self.line(String(repeating: $0, count: 60)) }
        let headline = ToolActivitySummary.summarize(long).headline ?? ""
        #expect(headline.count == ToolActivitySummary.headlineLimit)
        #expect(headline.hasSuffix("…"))
    }

    @Test func aFailureIsDrawnOutsideTheGroupNeverInsideIt() {
        let summary = ToolActivitySummary.summarize([
            Self.line("memory"), Self.line("today", .failed), Self.line("vault"),
        ])
        #expect(summary.headline == "Used memory and vault")
        #expect(summary.folded.map(\.name) == ["memory", "vault"])
        #expect(summary.exposed.map(\.name) == ["today"])
    }

    @Test func aPendingApprovalIsDrawnOutsideTheGroupNeverInsideIt() {
        let summary = ToolActivitySummary.summarize([
            Self.line("memory"), Self.line("vault"), Self.line("web", .awaitingApproval),
        ])
        #expect(summary.exposed.map(\.state) == [.awaitingApproval])
        #expect(!summary.folded.contains { $0.state != .done })
    }

    @Test func aLoneSuccessBesideAFailureIsNotGrouped() {
        let summary = ToolActivitySummary.summarize([Self.line("memory"), Self.line("today", .failed)])
        #expect(!summary.isGroup)
        #expect(summary.exposed.count == 1)
    }

    @Test func aFailedRecordBecomesAFailureLine() {
        let record = ChatToolRecord(kind: .memory, summary: "Memory search failed", failed: true)
        #expect(record.activityLine.state == .failed)
        #expect(record.activityLine.symbol == "exclamationmark.triangle")
        #expect(ChatToolRecord(kind: .memory, summary: "Searched memory: 4 hits").activityLine.state == .done)
    }

    @Test func aRecordSavedBeforeFailureWasKeptStillOpens() throws {
        let old = #"{"kind":"memory","summary":"Searched memory: 4 hits","sources":[]}"#
        let record = try JSONDecoder().decode(ChatToolRecord.self, from: Data(old.utf8))
        #expect(!record.isFailure)
        let failed = try JSONDecoder().decode(
            ChatToolRecord.self,
            from: JSONEncoder().encode(ChatToolRecord(kind: .web, summary: "x", failed: true))
        )
        #expect(failed.isFailure)
    }

    @Test func reduceMotionRemovesTheExpandAndTheStagger() {
        #expect(ToolActivityMotion.expandAnimation(reduceMotion: true) == nil)
        #expect(ToolActivityMotion.rowAnimation(index: 3, reduceMotion: true) == nil)
        #expect(ToolActivityMotion.expandAnimation(reduceMotion: false) != nil)
        #expect(ToolActivityMotion.rowAnimation(index: 3, reduceMotion: false) != nil)
    }

    @Test func aSourceDropsADayItsFileNameAlreadyCarries() {
        #expect(ChatSource(title: "episodic/2026-09-06.md", day: "2026-09-06").shownDay == nil)
        #expect(ChatSource(title: "Acme Launch status", day: "2026-08-24").shownDay == "2026-08-24")
        #expect(ChatSource(title: "Acme Launch status").shownDay == nil)
    }
}
