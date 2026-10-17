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

    // MARK: - real toolbox outcomes

    @Test func everyUnsuccessfulToolboxOutcomeDrawsOutsideTheFoldedGroup() async throws {
        let timedOut = FakeMemory()
        await timedOut.setSearchResult(.failure(RecallError.timedOut))
        let unreadable = FakeMemory()
        await unreadable.setOpenTasksResult(.success(RecalledTaskList(
            schemaVersion: 1, readable: false, reason: "neither task backend answered", count: 0, tasks: []
        )))
        let (skills, root) = try TemporarySkills.make()
        defer { try? FileManager.default.removeItem(at: root) }

        let outcomes: [ChatToolOutcome] = [
            try #require(await ChatToolbox(enabled: [.memory], memory: timedOut)
                .run("recall_memory", arguments: #"{"query":"deck"}"#)),
            try #require(await ChatToolbox(enabled: [.tasks], memory: unreadable)
                .run("recall_open_tasks", arguments: "{}")),
            try #require(await ChatToolbox(enabled: [.skills], skills: skills)
                .run("read_skill", arguments: #"{"name":"no-such-skill"}"#)),
            ChatToolbox.outOfTime("recall_memory"),
        ]
        for outcome in outcomes {
            #expect(outcome.status != .succeeded)
            #expect(outcome.record.activityLine.state == .failed, "\(outcome.record.summary)")
        }
    }

    @Test func aTimedOutSearchBesideTwoHitsIsNotHiddenInTheGroup() async throws {
        let timedOut = FakeMemory()
        await timedOut.setSearchResult(.failure(RecallError.timedOut))
        let vault = FakeVault(outcome: .success(VaultSearchOutcome(text: "x", resultCount: 2, sources: [])))
        let lines = [
            try #require(await ChatToolbox(enabled: [.memory], memory: timedOut)
                .run("recall_memory", arguments: #"{"query":"deck"}"#)).record.activityLine,
            try #require(await ChatToolbox(enabled: [.vault], vault: vault)
                .run("search_vault", arguments: #"{"query":"acme"}"#)).record.activityLine,
            try #require(await ChatToolbox(enabled: [.vault], vault: vault)
                .run("search_vault", arguments: #"{"query":"acme two"}"#)).record.activityLine,
        ]
        let summary = ToolActivitySummary.summarize(lines)
        #expect(summary.exposed.map(\.text) == ["Memory search timed out"])
        #expect(summary.headline == "Used vault")
    }

    @Test func aSuccessfulOutcomeStaysFolded() async throws {
        let vault = FakeVault(outcome: .success(VaultSearchOutcome(text: "x", resultCount: 2, sources: [])))
        let outcome = try #require(await ChatToolbox(enabled: [.vault], vault: vault)
            .run("search_vault", arguments: #"{"query":"acme"}"#))
        #expect(outcome.record.activityLine.state == .done)
    }
}
